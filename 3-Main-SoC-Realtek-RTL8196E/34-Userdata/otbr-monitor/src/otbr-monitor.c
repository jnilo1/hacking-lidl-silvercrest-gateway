/*
 * otbr-monitor — OTBR housekeeping daemon for the Lidl Silvercrest Gateway.
 *
 * Runs the post-start radio tuning, the status LED, persistent dataset sync,
 * and the one-shot SRP recovery cycle. Supervised by `keepalive` (started from
 * S70otbr), so a crash is restarted instead of silently stopping LED/sync/SRP.
 *
 * This is the C rewrite of the former busybox-ash script of the same name.
 * The ash version was the last long-lived shell loop in the system and the
 * only process still exposed to the RLX4181/Lexra intermittent
 * SIGSEGV/SIGILL/SIGBUS fault that hits long-lived ash loops (issue #109 — the
 * same class that retired the s40button and inline-monitor shell loops). A
 * long-lived C process blocked in poll/sleep never runs ash, so it cannot hit
 * that fault. No ash is spawned here: the REST API is read over a plain TCP
 * socket (not `wget`), the dataset is copied in-process (not `cp`), and the
 * only children forked are short-lived `ot-ctl` invocations (C++, not ash).
 *
 * Behaviour parity with the shell version (skeleton/usr/sbin/otbr-monitor):
 *   - Radio tuning (log level + TX power) re-applies on every fresh otbr-agent
 *     bring-up, because the OT stack resets TX power to the platform default
 *     on each stack init — so a keepalive restart of otbr-agent is re-tuned.
 *   - SRP recovery fires once per BOOT, gated by a tmpfs flag, so a restart of
 *     this monitor does not repeat the 30 s SRP downtime.
 *   - Status LED tracks the Thread role and matches the LAN LED brightness.
 *   - Dataset written to flash only when the active dataset actually changes.
 *
 * Build: build_otbr-monitor.sh in this tree (Lexra MIPS / musl, static).
 *
 * J. Nilo, July 2026
 */

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>

#define REST_HOST	"127.0.0.1"
#define REST_PORT	8081
#define LED_PATH	"/sys/class/leds/status/brightness"
#define LED_MODE_PATH	"/sys/class/net/eth0/led_mode"
#define RAM_DIR		"/tmp/thread"
#define FLASH_DIR	"/userdata/thread"
#define SRP_DONE_FLAG	"/tmp/otbr-srp-recovery.done"	/* tmpfs: once per boot */
#define OT_CTL		"/userdata/usr/bin/ot-ctl"

#define TX_REQUEST	"4"	/* rounds to +3 dBm calibrated (see range REPORT.md) */
#define TX_TARGET_DBM	3
#define TUNE_TRIES	10

#define POLL_UP_SEC	30	/* poll cadence once Thread is up */
#define POLL_DOWN_SEC	5	/* poll cadence while Thread is down */
#define SRP_WAIT_SEC	120	/* wait after Thread-up before the SRP cycle */
#define SRP_CYCLE_SEC	30	/* SRP disable→enable downtime */

#define DATASET_MAX	8192
#define STATE_MAX	256
#define CAPTURE_MAX	8192

static volatile sig_atomic_t stop_requested;

static void on_term(int sig)
{
	(void)sig;
	stop_requested = 1;
}

/* Sleep up to `sec` seconds, returning early if a stop was requested. */
static void nap(unsigned sec)
{
	struct timespec ts = { .tv_sec = sec, .tv_nsec = 0 };

	while (!stop_requested && nanosleep(&ts, &ts) == -1 && errno == EINTR)
		; /* resume the remaining interval unless stop was requested */
}

/* ---- small file helpers ---------------------------------------------- */

static void led_set(int value)
{
	FILE *f = fopen(LED_PATH, "w");

	if (!f)
		return;
	fprintf(f, "%d\n", value);
	fclose(f);
}

/* On-brightness for the status LED, matched to the LAN LED mode. */
static int led_on_brightness(void)
{
	char buf[32] = { 0 };
	FILE *f = fopen(LED_MODE_PATH, "r");

	if (f) {
		if (!fgets(buf, sizeof(buf), f))
			buf[0] = '\0';
		fclose(f);
	}
	if (strncmp(buf, "off", 3) == 0)
		return 0;
	if (strncmp(buf, "dim", 3) == 0)
		return 60;
	return 255;
}

static int file_exists(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0;
}

static void touch(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd >= 0)
		close(fd);
}

/* ---- REST over a plain TCP socket (no wget) --------------------------- */

/*
 * GET `path` from the local REST API and copy the response body into `buf`
 * (NUL-terminated). Returns the body length, or -1 if the API is unreachable
 * (agent not up yet) or the request failed — the caller treats -1/0 the same
 * way the shell treated wget's empty output: "not reachable".
 */
static int http_get(const char *path, char *buf, size_t buflen)
{
	struct sockaddr_in sa;
	struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };
	char req[256];
	char raw[DATASET_MAX + 512];
	char *body;
	int fd, n, total = 0;

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons(REST_PORT);
	sa.sin_addr.s_addr = inet_addr(REST_HOST);

	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;	/* ECONNREFUSED while otbr-agent is still starting */
	}

	n = snprintf(req, sizeof(req),
		     "GET %s HTTP/1.0\r\nHost: " REST_HOST "\r\n"
		     "Connection: close\r\n\r\n", path);
	if (write(fd, req, (size_t)n) != n) {
		close(fd);
		return -1;
	}

	while (total < (int)sizeof(raw) - 1) {
		n = read(fd, raw + total, sizeof(raw) - 1 - (size_t)total);
		if (n <= 0)
			break;
		total += n;
	}
	close(fd);
	raw[total] = '\0';

	/* Body starts after the CRLFCRLF header terminator. */
	body = strstr(raw, "\r\n\r\n");
	if (!body)
		return -1;
	body += 4;

	{
		size_t len = strlen(body);

		if (len >= buflen)
			len = buflen - 1;
		memcpy(buf, body, len);
		buf[len] = '\0';
		return (int)len;
	}
}

/* ---- ot-ctl (short-lived C++ children, never ash) -------------------- */

/* Run ot-ctl with the given trailing args, discarding output. */
static void ot_ctl(char *const extra[])
{
	pid_t pid = fork();

	if (pid == 0) {
		int devnull = open("/dev/null", O_WRONLY);

		if (devnull >= 0) {
			dup2(devnull, STDOUT_FILENO);
			dup2(devnull, STDERR_FILENO);
			if (devnull > STDERR_FILENO)
				close(devnull);
		}
		execv(OT_CTL, extra);
		_exit(127);
	}
	if (pid > 0) {
		int status, w;

		do {
			w = waitpid(pid, &status, 0);
			if (w < 0 && errno == EINTR && stop_requested)
				kill(pid, SIGTERM);
		} while (w < 0 && errno == EINTR);
	}
}

/* Run ot-ctl, capturing stdout into `buf` (NUL-terminated). Returns length. */
static int ot_ctl_capture(char *const argv[], char *buf, size_t buflen)
{
	int pipefd[2];
	pid_t pid;
	int total = 0, n, status, w;

	if (pipe(pipefd) < 0)
		return -1;

	pid = fork();
	if (pid < 0) {
		close(pipefd[0]);
		close(pipefd[1]);
		return -1;
	}
	if (pid == 0) {
		int devnull = open("/dev/null", O_WRONLY);

		dup2(pipefd[1], STDOUT_FILENO);
		if (devnull >= 0)
			dup2(devnull, STDERR_FILENO);
		close(pipefd[0]);
		close(pipefd[1]);
		execv(OT_CTL, argv);
		_exit(127);
	}

	close(pipefd[1]);
	while (total < (int)buflen - 1) {
		n = read(pipefd[0], buf + total, buflen - 1 - (size_t)total);
		if (n <= 0)
			break;
		total += n;
	}
	close(pipefd[0]);
	buf[total] = '\0';

	do {
		w = waitpid(pid, &status, 0);
	} while (w < 0 && errno == EINTR);

	return total;
}

/* Parse the first "<n> dBm" line of `ot-ctl txpower` output; INT_MIN if none. */
static int parse_txpower(const char *buf)
{
	const char *p = buf;

	while (p && *p) {
		int v;

		if (sscanf(p, " %d dBm", &v) == 1)
			return v;
		p = strchr(p, '\n');
		if (p)
			p++;
	}
	return -2147483647 - 1;	/* INT_MIN, no <limits.h> needed */
}

/*
 * Re-apply log level and TX power after a fresh otbr-agent bring-up. The OT
 * stack drops txpower during early init, so retry-and-verify with a ceiling.
 */
static void otbr_tune(void)
{
	char *const loglvl[] = { "ot-ctl", "log", "level", "2", NULL };
	char *const setpwr[] = { "ot-ctl", "txpower", TX_REQUEST, NULL };
	char *const getpwr[] = { "ot-ctl", "txpower", NULL };
	char out[256];
	int i;

	ot_ctl(loglvl);
	for (i = 0; i < TUNE_TRIES && !stop_requested; i++) {
		ot_ctl(setpwr);
		ot_ctl_capture(getpwr, out, sizeof(out));
		if (parse_txpower(out) == TX_TARGET_DBM)
			return;
		nap(1);
	}
}

/* Count child-table data rows: lines of the form "|<spaces><digit>". */
static int count_children(void)
{
	char *const argv[] = { "ot-ctl", "child", "table", NULL };
	char buf[CAPTURE_MAX];
	const char *p = buf;
	int count = 0;

	ot_ctl_capture(argv, buf, sizeof(buf));
	while (p && *p) {
		if (*p == '|') {
			const char *q = p + 1;

			while (*q == ' ' || *q == '\t')
				q++;
			if (isdigit((unsigned char)*q))
				count++;
		}
		p = strchr(p, '\n');
		if (p)
			p++;
	}
	return count;
}

/* Count SRP services (lines containing the matter service tag). */
static int count_srp_services(void)
{
	char *const argv[] = { "ot-ctl", "srp", "server", "service", NULL };
	char buf[CAPTURE_MAX];
	const char *p = buf;
	int count = 0;

	ot_ctl_capture(argv, buf, sizeof(buf));
	while ((p = strstr(p, "_matter._tcp")) != NULL) {
		count++;
		p += 12;
	}
	return count;
}

/* ---- dataset sync (in-process copy, no cp/ash) ----------------------- */

static int copy_file(const char *src, const char *dst)
{
	char buf[4096];
	int in, out, n, ret = 0;

	in = open(src, O_RDONLY);
	if (in < 0)
		return -1;
	out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out < 0) {
		close(in);
		return -1;
	}
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		if (write(out, buf, (size_t)n) != n) {
			ret = -1;
			break;
		}
	}
	if (n < 0)
		ret = -1;
	close(in);
	close(out);
	return ret;
}

/* Copy every regular file from RAM_DIR into FLASH_DIR (shell: cp of the dir). */
static void sync_dataset(void)
{
	DIR *d = opendir(RAM_DIR);
	struct dirent *de;

	if (!d)
		return;
	while ((de = readdir(d)) != NULL) {
		char src[512], dst[512];
		struct stat st;

		if (de->d_name[0] == '.')
			continue;
		snprintf(src, sizeof(src), "%s/%s", RAM_DIR, de->d_name);
		if (stat(src, &st) != 0 || !S_ISREG(st.st_mode))
			continue;
		snprintf(dst, sizeof(dst), "%s/%s", FLASH_DIR, de->d_name);
		copy_file(src, dst);
	}
	closedir(d);
}

/* ---- state helpers --------------------------------------------------- */

/* Thread role that lights the LED: child / router / leader. */
static int thread_is_up(const char *state)
{
	return strstr(state, "child") || strstr(state, "router") ||
	       strstr(state, "leader");
}

int main(void)
{
	struct sigaction sa;
	char state[STATE_MAX];
	char dataset[DATASET_MAX];
	char last_dataset[DATASET_MAX];
	int last_led = -1;
	int was_reachable = 0;
	int tuned = 0;
	int srp_done;
	time_t thread_up_since = 0;

	openlog("otbr-monitor", LOG_PID, LOG_USER);
	syslog(LOG_NOTICE, "started (C v1.0): REST %s:%d, poll %d/%ds",
	       REST_HOST, REST_PORT, POLL_DOWN_SEC, POLL_UP_SEC);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_term;	/* no SA_RESTART: sleeps must be interruptible */
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	srp_done = file_exists(SRP_DONE_FLAG);

	nap(5);	/* let otbr-agent start before the first poll */

	/* Seed last_dataset so the first poll does not trigger a redundant write. */
	if (http_get("/node/dataset/active", last_dataset, sizeof(last_dataset)) <= 0)
		last_dataset[0] = '\0';

	while (!stop_requested) {
		int reachable, led;

		reachable = http_get("/node/state", state, sizeof(state)) > 0
			    && state[0] != '\0';
		if (!reachable)
			state[0] = '\0';

		/* Fresh bring-up (incl. after a keepalive restart): re-tune. */
		if (reachable && !was_reachable)
			tuned = 0;
		was_reachable = reachable;
		if (reachable && !tuned) {
			otbr_tune();
			tuned = 1;
		}

		/* LED: on when Thread state is child, router, or leader. */
		led = reachable && thread_is_up(state) ? 1 : 0;
		if (led != last_led) {
			led_set(led ? led_on_brightness() : 0);
			last_led = led;
		}

		/* Dataset sync — only write to flash when it actually changes. */
		if (http_get("/node/dataset/active", dataset, sizeof(dataset)) > 0 &&
		    dataset[0] != '\0' && strcmp(dataset, last_dataset) != 0) {
			sync_dataset();
			memcpy(last_dataset, dataset, sizeof(last_dataset));
		}

		/*
		 * SRP recovery cycle — fire once per boot. The disable/enable
		 * cycle bumps the SRP UDP port so attached children re-register
		 * within seconds rather than waiting up to ~1 h for a lease
		 * refresh. Gated by a tmpfs flag so a monitor restart does not
		 * repeat it.
		 */
		if (!srp_done && led) {
			time_t now = time(NULL);

			if (thread_up_since == 0)
				thread_up_since = now;
			if (now - thread_up_since >= SRP_WAIT_SEC) {
				int n_children = count_children();

				if (n_children > 0) {
					char *const dis[] = { "ot-ctl", "srp",
						"server", "disable", NULL };
					char *const ena[] = { "ot-ctl", "srp",
						"server", "enable", NULL };

					syslog(LOG_NOTICE,
					       "%d child(ren) attached at T+%ds, "
					       "running SRP recovery cycle "
					       "(current services=%d)",
					       n_children, SRP_WAIT_SEC,
					       count_srp_services());
					ot_ctl(dis);
					nap(SRP_CYCLE_SEC);
					if (!stop_requested)
						ot_ctl(ena);
					syslog(LOG_NOTICE,
					       "SRP recovery cycle done");
				}
				srp_done = 1;
				touch(SRP_DONE_FLAG);
			}
		}

		if (stop_requested)
			break;

		/* Poll fast until Thread is up, then slow. */
		nap(led ? POLL_UP_SEC : POLL_DOWN_SEC);
	}

	led_set(0);
	syslog(LOG_NOTICE, "stop requested, exiting");
	closelog();
	return 0;
}
