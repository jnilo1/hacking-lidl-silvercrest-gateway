/*
 * s40button — front-panel button daemon for the Lidl Silvercrest Gateway.
 *
 * Polls the reset button GPIO every 100 ms; on a confirmed 5 s long-press,
 * invokes /usr/sbin/recover_efr32 -q to reset the EFR32 radio without
 * rebooting the SoC.  Replaces the v3.2.x/v3.3.0 busybox shell loop, which
 * had an intermittent SIGSEGV after some hours of idle polling (via
 * `devmem` + ash).  That crash was later root-caused — a TLB flush in our port
 * sweeping from a hardcoded index instead of the Wired boundary — and fixed,
 * so it says nothing about ash being unsafe here; this daemon is kept in C for
 * the GPIO cdev access below, not to dodge that fault.
 *
 * v2 (discussion #122): the GPIO is accessed through the kernel GPIO
 * character device (/dev/gpiochip0, uAPI v2 ioctls — no libgpiod), not by
 * mmap'ing /dev/mem.  The line is found by the name the board DTS gives it
 * ("reset-button" via gpio-line-names); on kernels without line names the
 * daemon falls back to line 9 (the Lidl wiring), and -p <line> forces an
 * explicit offset (bring-up aid for ports, e.g. the Sengled G4 whose
 * button pad B6 also needs the pad-mux that the kernel gpio-rtl819x
 * request() hook applies on claim — the very step the v1 /dev/mem poker
 * never did).  The kernel owns the line for the lifetime of the held
 * request fd, so the v1 "mux lost at runtime" re-check is gone.
 *
 * Behaviour parity with v1 otherwise:
 *   - 100 ms poll loop, button active LOW (pressed reads 0).
 *   - Edge detection: press detector stays disarmed at boot until a HIGH
 *     is observed.  Guards against a stuck-LOW pin / wrong mux at boot.
 *   - Debounce: require 3 consecutive LOW samples (300 ms) before
 *     treating it as a real press.
 *   - Subtle LED blink (every 500 ms, brightness alternates 30/255)
 *     during the hold for visual feedback; on release the LED is
 *     restored to the state it had immediately before the press
 *     (captured at press time, not at boot — issue #131).
 *   - 5 s sustained press fires recover_efr32; the LED briefly blinks
 *     off→on to confirm the trigger; we wait for release before re-arming.
 *   - Short presses (< 5 s) are ignored.
 *   - Every state transition is logged via syslog (LOG_USER).
 *
 * Build: build_s40button.sh in this tree (Lexra MIPS / musl, static).
 *
 * J. Nilo, April 2026 (v2: June 2026; v2.1: pre-press LED restore, #131)
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define GPIO_CHIP_PATH      "/dev/gpiochip0"
#define BUTTON_LINE_NAME    "reset-button"
#define BUTTON_LINE_FALLBACK 9          /* Lidl wiring: GPIO 9 (pad B1) */

#define POLL_INTERVAL_MS    100
#define LONG_PRESS_MS       5000
#define DEBOUNCE_SAMPLES    3

#define LED_PATH            "/sys/class/leds/status/brightness"
#define RECOVER_BIN         "/usr/sbin/recover_efr32"

static int g_line_fd = -1;

/*
 * Find the button line by DTS name; -1 if the chip carries no line names
 * (kernel predating the gpio-line-names property) or none matches.
 */
static int find_line_by_name(int chip_fd, const char *name)
{
    struct gpiochip_info ci;
    uint32_t i;

    memset(&ci, 0, sizeof(ci));
    if (ioctl(chip_fd, GPIO_GET_CHIPINFO_IOCTL, &ci) < 0)
        return -1;

    for (i = 0; i < ci.lines; i++) {
        struct gpio_v2_line_info li;

        memset(&li, 0, sizeof(li));
        li.offset = i;
        if (ioctl(chip_fd, GPIO_V2_GET_LINEINFO_IOCTL, &li) < 0)
            continue;
        if (strncmp(li.name, name, sizeof(li.name)) == 0)
            return (int)i;
    }
    return -1;
}

/*
 * Claim the line as input.  The gpio-rtl819x request() hook switches the
 * pad to GPIO mode (and applies the PIN_MUX_SEL_2 pad-mux for pads B2-B6)
 * as part of this claim.  Returns the line request fd.
 */
static int claim_line(int chip_fd, unsigned int offset)
{
    struct gpio_v2_line_request req;

    memset(&req, 0, sizeof(req));
    req.offsets[0] = offset;
    req.num_lines = 1;
    req.config.flags = GPIO_V2_LINE_FLAG_INPUT;
    snprintf(req.consumer, sizeof(req.consumer), "s40button");

    if (ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0)
        return -1;
    return req.fd;
}

static int button_pressed(void)
{
    struct gpio_v2_line_values lv;
    static int read_err_logged;

    memset(&lv, 0, sizeof(lv));
    lv.mask = 1;
    if (ioctl(g_line_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &lv) < 0) {
        if (!read_err_logged) {
            syslog(LOG_ERR, "line read failed: %s", strerror(errno));
            read_err_logged = 1;
        }
        return 0;       /* treat as released; daemon stays alive */
    }
    /* Active LOW: pressed = bit reads 0. */
    return (lv.bits & 1) == 0;
}

static int led_get(void)
{
    int v = -1;
    FILE *f = fopen(LED_PATH, "r");
    if (!f)
        return -1;
    if (fscanf(f, "%d", &v) != 1)
        v = -1;
    fclose(f);
    return v;
}

static void led_set(int value)
{
    FILE *f = fopen(LED_PATH, "w");
    if (!f)
        return;
    fprintf(f, "%d\n", value);
    fclose(f);
}

static void msleep(unsigned ms)
{
    struct timespec ts = {
        .tv_sec = ms / 1000,
        .tv_nsec = (long)(ms % 1000) * 1000000L,
    };
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR)
        ; /* resume on signal */
}

static void run_recover_efr32(void)
{
    pid_t pid = fork();
    if (pid == 0) {
        execl(RECOVER_BIN, "recover_efr32", "-q", (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
            syslog(LOG_WARNING, "recover_efr32 exited with status %d",
                   WEXITSTATUS(status));
        }
    } else {
        syslog(LOG_ERR, "fork() failed: %s", strerror(errno));
    }
}

int main(int argc, char **argv)
{
    int forced_line = -1;
    int chip_fd, line, opt;

    while ((opt = getopt(argc, argv, "p:")) != -1) {
        switch (opt) {
        case 'p':
            forced_line = atoi(optarg);
            if (forced_line < 0 || forced_line > 31) {
                fprintf(stderr, "s40button: -p %s out of range (0-31)\n",
                        optarg);
                return 1;
            }
            break;
        default:
            fprintf(stderr, "usage: s40button [-p <line 0-31>]\n");
            return 1;
        }
    }

    chip_fd = open(GPIO_CHIP_PATH, O_RDWR | O_CLOEXEC);
    if (chip_fd < 0) {
        fprintf(stderr, "s40button: open %s: %s\n", GPIO_CHIP_PATH,
                strerror(errno));
        return 1;
    }

    openlog("s40button", LOG_PID, LOG_USER);

    if (forced_line >= 0) {
        line = forced_line;
        syslog(LOG_NOTICE, "using line %d (forced via -p)", line);
    } else {
        line = find_line_by_name(chip_fd, BUTTON_LINE_NAME);
        if (line >= 0) {
            syslog(LOG_NOTICE, "found \"%s\" at line %d", BUTTON_LINE_NAME,
                   line);
        } else {
            line = BUTTON_LINE_FALLBACK;
            syslog(LOG_NOTICE,
                   "no \"%s\" line name on %s (pre-DT-names kernel?), "
                   "falling back to line %d",
                   BUTTON_LINE_NAME, GPIO_CHIP_PATH, line);
        }
    }

    g_line_fd = claim_line(chip_fd, (unsigned int)line);
    close(chip_fd);
    if (g_line_fd < 0) {
        syslog(LOG_ERR, "claiming line %d failed: %s", line,
               strerror(errno));
        fprintf(stderr, "s40button: claiming line %d: %s\n", line,
                strerror(errno));
        return 1;
    }

    syslog(LOG_NOTICE,
           "started: line %d claimed, %dms poll, %ds long-press → %s -q",
           line, POLL_INTERVAL_MS, LONG_PRESS_MS / 1000, RECOVER_BIN);

    int armed = 0;

    for (;;) {
        if (!button_pressed()) {
            if (!armed) {
                syslog(LOG_NOTICE,
                       "line %d idle (HIGH), press detector armed", line);
                armed = 1;
            }
            msleep(POLL_INTERVAL_MS);
            continue;
        }

        /* Line is LOW. */
        if (!armed) {
            msleep(POLL_INTERVAL_MS);
            continue;
        }

        /* Debounce. */
        int debounce = 1;
        while (debounce < DEBOUNCE_SAMPLES) {
            msleep(POLL_INTERVAL_MS);
            if (button_pressed()) {
                debounce++;
            } else {
                debounce = 0;
                break;
            }
        }
        if (debounce < DEBOUNCE_SAMPLES)
            continue;

        /* Confirmed press. */
        syslog(LOG_NOTICE,
               "press detected, watching for %ds long-press",
               LONG_PRESS_MS / 1000);
        /*
         * Capture the LED state at press time, not at boot: the status
         * LED can be changed at runtime by other code, and a press must
         * leave it exactly as it was found (issue #131). Re-read here,
         * before the first blink below.
         */
        int pre_press_led = led_get();
        int held_ms = DEBOUNCE_SAMPLES * POLL_INTERVAL_MS;
        int blink_state = 0;
        int fired = 0;

        while (button_pressed()) {
            if (held_ms % 500 == 0) {
                led_set(blink_state ? 255 : 30);
                blink_state = !blink_state;
            }
            if (held_ms >= LONG_PRESS_MS) {
                led_set(0);
                msleep(200);
                led_set(255);
                syslog(LOG_NOTICE,
                       "long-press detected, invoking recover_efr32");
                run_recover_efr32();
                fired = 1;
                /* Wait for release before re-arming. */
                while (button_pressed())
                    msleep(200);
                armed = 0;
                break;
            }
            msleep(POLL_INTERVAL_MS);
            held_ms += POLL_INTERVAL_MS;
        }

        if (!fired) {
            syslog(LOG_NOTICE,
                   "press released after %dms (short-press, ignored)",
                   held_ms);
        }

        if (pre_press_led >= 0)
            led_set(pre_press_led);
    }
    /* unreachable */
}
