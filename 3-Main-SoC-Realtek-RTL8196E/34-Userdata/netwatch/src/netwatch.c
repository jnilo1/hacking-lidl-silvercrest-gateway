// SPDX-License-Identifier: MIT
/*
 * netwatch — recover, and record, a gateway that goes silent on a live link.
 *
 * The hardware watchdog only protects against a stopped CPU: /sbin/watchdog
 * feeds it from userspace, so a kernel hang stops the kicks and the chip
 * resets the board within the ~60 s timeout. What it cannot see is a board
 * whose userspace is perfectly alive but whose network path is dead — the
 * kicks keep coming, the chip stays quiet, and the gateway is simply gone
 * from the LAN until a human power-cycles it. On a remote installation that
 * is an outage measured in days, and the power cycle destroys every trace:
 * the watchdog reset-reason latch is overwritten and the reserved DRAM page
 * holding any panic record is wiped, so the cause is unrecoverable.
 *
 * netwatch closes that hole from the only place that still works in that
 * state — the box itself. It probes a set of targets with ICMP echo and,
 * when *every* target has been unreachable continuously for a long window
 * while the link carrier is still up, it writes a snapshot of what it sees
 * into /userdata (JFFS2: survives the reboot, the power cycle, everything)
 * and then reboots through the normal path.
 *
 * Two design points are load-bearing:
 *
 * - Carrier must be UP to act. Carrier down means the cable is out or the
 *   peer switch is off — a physical fault a reboot cannot fix, and one a
 *   human may have caused on purpose. Carrier up with nothing reachable is
 *   the signature we want: the link is electrically fine and the stack is
 *   not answering.
 *
 * - The reboot goes through /sbin/reboot, never reboot(2). BusyBox init runs
 *   the ::shutdown entry (rcK), which reaches S10network stop and its
 *   `ip link set eth0 down`; that calls the driver's ndo_stop, which clears
 *   TXCMD|RXCMD in CPUICR and deasserts TRXRDY — the CPU-port DMA engine is
 *   stopped. Be precise about the scope: that is one of the three steps the
 *   bootloader performs before its own resets (it also hard-resets the switch
 *   core, which is what aborts an ALREADY-ARMED transfer, and holds the PHY
 *   interfaces off). The driver does not do those two, and machine_restart
 *   adds nothing — there is no .shutdown hook on the platform driver. So this
 *   is not a full quiesce; it is strictly more than reboot(2) would leave,
 *   which is a board reset with the DMA engine still armed. A watchdog
 *   timeout on a hung CPU leaves exactly that.
 *
 * Written in C, like the other long-lived daemons here, but on its own merits:
 * the work is a raw ICMP socket, klogctl() and a structured snapshot writer,
 * none of which is a shell operation. A script would have to fork ping and
 * dmesg every cycle, forever, on a single 400 MHz core.
 *
 * Usage: netwatch [-i IFACE] [-t TARGET]... [-w FAIL_MIN] [-p POLL_SEC]
 *                 [-m MAX_REBOOTS] [-W WINDOW_H] [-d DIR] [-n] [-v]
 *   -i IFACE    interface whose carrier gates action   (default: eth0)
 *   -t TARGET   probe target IPv4, repeatable, max 8   (default: default route)
 *   -w FAIL_MIN continuous unreachable minutes to act  (default: 15)
 *   -p POLL_SEC probe period in seconds                (default: 30)
 *   -m MAX      max reboots inside the window          (default: 3)
 *   -W HOURS    sliding window for that cap            (default: 24)
 *   -d DIR      state + incident directory             (default: /userdata/netwatch)
 *   -n          dry run: decide and record, never reboot
 *   -v          verbose: log every probe round
 *
 * J. Nilo, July 2026
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/klog.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define VERSION		"1.0"

#define DEF_IFACE	"eth0"
#define DEF_FAIL_MIN	15
#define DEF_POLL_SEC	30
#define DEF_MAX_REBOOT	3
#define DEF_WINDOW_H	24
#define DEF_DIR		"/userdata/netwatch"

#define MAX_TARGETS	8
#define PROBE_WAIT_MS	1500		/* per-round wait for any echo reply */
#define KLOG_TAIL	8192		/* bytes of kernel ring kept in a snapshot */
#define LOG_MAX_BYTES	49152		/* rotate incidents.log past this size */

struct icmp_echo {
	uint8_t  type;
	uint8_t  code;
	uint16_t cksum;
	uint16_t id;
	uint16_t seq;
};

static volatile sig_atomic_t stop_requested;

static const char *opt_iface   = DEF_IFACE;
static const char *opt_dir     = DEF_DIR;
static int   opt_fail_min      = DEF_FAIL_MIN;
static int   opt_poll_sec      = DEF_POLL_SEC;
static int   opt_max_reboot    = DEF_MAX_REBOOT;
static int   opt_window_h      = DEF_WINDOW_H;
static int   opt_dry_run;
static int   opt_verbose;

static char  targets[MAX_TARGETS][INET_ADDRSTRLEN];
static int   ntargets;

static void on_term(int sig)
{
	(void)sig;
	stop_requested = 1;
}

/* ---------------------------------------------------------------- helpers */

/* Read a whole small file into buf. Returns length, or -1. NUL-terminates. */
static ssize_t slurp(const char *path, char *buf, size_t len)
{
	ssize_t n;
	int fd = open(path, O_RDONLY);

	if (fd < 0)
		return -1;
	n = read(fd, buf, len - 1);
	close(fd);
	if (n < 0)
		return -1;
	buf[n] = '\0';
	return n;
}

/* /sys/class/net/<iface>/carrier: 1 up, 0 down, -1 unknown (iface down). */
static int read_carrier(void)
{
	char path[128], buf[8];

	snprintf(path, sizeof(path), "/sys/class/net/%s/carrier", opt_iface);
	if (slurp(path, buf, sizeof(buf)) <= 0)
		return -1;
	return buf[0] == '1' ? 1 : 0;
}

/* Seconds since boot, from /proc/uptime. Monotonic across NTP steps. */
static long read_uptime(void)
{
	char buf[64];
	double up = 0;

	if (slurp("/proc/uptime", buf, sizeof(buf)) <= 0)
		return -1;
	up = strtod(buf, NULL);
	return (long)up;
}

/*
 * Default-route gateway for opt_iface, as dotted quad, from /proc/net/route.
 * Re-read on demand rather than cached: a DHCP box can legitimately change
 * gateway, and a probe list pinned at boot would then be wrong forever.
 */
static int read_default_gw(char *out, size_t outlen)
{
	char line[256], iface[32];
	unsigned long dest, gw, flags;
	FILE *f = fopen("/proc/net/route", "r");
	int found = 0;

	if (!f)
		return -1;
	if (!fgets(line, sizeof(line), f)) {		/* header */
		fclose(f);
		return -1;
	}
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "%31s %lx %lx %lx", iface, &dest, &gw, &flags) != 4)
			continue;
		if (dest != 0 || gw == 0)
			continue;
		if (strcmp(iface, opt_iface) != 0)
			continue;
		{
			struct in_addr a;
			a.s_addr = (in_addr_t)gw;	/* already network order */
			if (inet_ntop(AF_INET, &a, out, outlen)) {
				found = 1;
				break;
			}
		}
	}
	fclose(f);
	return found ? 0 : -1;
}

/* ------------------------------------------------------------------ probe */

static uint16_t checksum16(const void *data, size_t len)
{
	const uint8_t *p = data;
	uint32_t sum = 0;

	while (len > 1) {
		sum += (uint32_t)((p[0] << 8) | p[1]);
		p += 2;
		len -= 2;
	}
	if (len)
		sum += (uint32_t)(p[0] << 8);
	while (sum >> 16)
		sum = (sum & 0xffff) + (sum >> 16);
	return htons((uint16_t)~sum);
}

/*
 * Send one echo request to every target, then wait up to PROBE_WAIT_MS for
 * ANY matching reply. Returns 1 if at least one target answered, 0 if none
 * did, -1 on a socket error the caller should treat as "unknown".
 *
 * "Any target" is deliberate: requiring all of them would turn one rebooting
 * router into a false positive, which on a box we cannot physically reach is
 * the expensive direction to be wrong in.
 */
static int probe_targets(int sock, uint16_t id, uint16_t seq)
{
	struct icmp_echo req;
	struct timeval tv;
	fd_set rfds;
	char rbuf[512];
	long deadline_ms, waited_ms = 0;
	int i, answered = 0;

	memset(&req, 0, sizeof(req));
	req.type = 8;				/* echo request */
	req.code = 0;
	req.id   = htons(id);
	req.seq  = htons(seq);
	req.cksum = 0;
	req.cksum = checksum16(&req, sizeof(req));

	for (i = 0; i < ntargets; i++) {
		struct sockaddr_in dst;

		memset(&dst, 0, sizeof(dst));
		dst.sin_family = AF_INET;
		if (inet_pton(AF_INET, targets[i], &dst.sin_addr) != 1)
			continue;
		if (sendto(sock, &req, sizeof(req), 0,
			   (struct sockaddr *)&dst, sizeof(dst)) < 0) {
			/* ENETUNREACH/EHOSTUNREACH here is itself a symptom:
			 * the stack cannot even route. Count it as no answer. */
			if (opt_verbose)
				syslog(LOG_DEBUG, "sendto %s: %s",
				       targets[i], strerror(errno));
		}
	}

	deadline_ms = PROBE_WAIT_MS;
	while (waited_ms < deadline_ms && !answered) {
		long chunk = deadline_ms - waited_ms;

		FD_ZERO(&rfds);
		FD_SET(sock, &rfds);
		tv.tv_sec  = chunk / 1000;
		tv.tv_usec = (chunk % 1000) * 1000;

		i = select(sock + 1, &rfds, NULL, NULL, &tv);
		if (i < 0) {
			if (errno == EINTR)
				break;
			return -1;
		}
		if (i == 0)
			break;				/* timed out */

		{
			ssize_t n = recv(sock, rbuf, sizeof(rbuf), 0);
			size_t iphlen;
			struct icmp_echo rep;

			if (n < 0)
				break;
			if (n < 20)
				continue;
			iphlen = (size_t)(rbuf[0] & 0x0f) * 4;
			if ((size_t)n < iphlen + sizeof(rep))
				continue;
			memcpy(&rep, rbuf + iphlen, sizeof(rep));
			if (rep.type == 0 && ntohs(rep.id) == id)
				answered = 1;
		}
		waited_ms += 50;	/* coarse: the loop exits on first match */
	}
	return answered;
}

/* -------------------------------------------------------------- forensics */

static void append_file_section(FILE *out, const char *title, const char *path)
{
	char buf[2048];
	ssize_t n;

	fprintf(out, "--- %s (%s)\n", title, path);
	n = slurp(path, buf, sizeof(buf));
	if (n <= 0)
		fprintf(out, "(unreadable)\n");
	else
		fputs(buf, out);
	fputc('\n', out);
}

/* Rotate incidents.log once it grows past LOG_MAX_BYTES, so a pathological
 * repeat cannot fill a 12 MB JFFS2 partition. One generation is kept. */
static void rotate_if_large(const char *logpath)
{
	struct stat st;
	char old[280];		/* logpath is at most 256; room for the ".1" */

	if (stat(logpath, &st) != 0 || st.st_size < LOG_MAX_BYTES)
		return;
	snprintf(old, sizeof(old), "%s.1", logpath);
	rename(logpath, old);
}

/*
 * Record everything worth having before we reboot. This is the only artefact
 * that survives both the reboot and a later power cycle, so it is the whole
 * reason the daemon exists — the reboot is just the by-product.
 */
static void write_incident(const char *reason, int will_reboot)
{
	char logpath[256], path[128];
	time_t now = time(NULL);
	struct tm tm;
	FILE *out;
	char *kbuf;
	int klen;

	snprintf(logpath, sizeof(logpath), "%s/incidents.log", opt_dir);
	rotate_if_large(logpath);

	out = fopen(logpath, "a");
	if (!out) {
		syslog(LOG_ERR, "cannot write %s: %s", logpath, strerror(errno));
		return;
	}

	localtime_r(&now, &tm);
	fprintf(out, "===== netwatch v%s incident %04d-%02d-%02d %02d:%02d:%02d\n",
		VERSION, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
		tm.tm_hour, tm.tm_min, tm.tm_sec);
	fprintf(out, "reason      : %s\n", reason);
	fprintf(out, "action      : %s\n",
		will_reboot ? "reboot (clean path)" : "NONE (dry run or capped)");
	fprintf(out, "uptime_s    : %ld\n", read_uptime());
	fprintf(out, "carrier     : %d\n", read_carrier());
	fprintf(out, "targets     : ");
	{
		int i;
		for (i = 0; i < ntargets; i++)
			fprintf(out, "%s%s", targets[i], i + 1 < ntargets ? "," : "");
	}
	fputc('\n', out);
	fputc('\n', out);

	snprintf(path, sizeof(path), "/sys/class/net/%s/operstate", opt_iface);
	append_file_section(out, "operstate", path);
	append_file_section(out, "interface counters", "/proc/net/dev");
	append_file_section(out, "routes", "/proc/net/route");
	append_file_section(out, "arp", "/proc/net/arp");

	/* Tail of the kernel ring buffer: SYSLOG_ACTION_READ_ALL returns the
	 * LAST len bytes, which is exactly the window that matters — driver
	 * resets, TX timeouts, the watchdog's boot-time reset-reason line. */
	kbuf = malloc(KLOG_TAIL);
	if (kbuf) {
		klen = klogctl(3, kbuf, KLOG_TAIL - 1);
		if (klen > 0) {
			kbuf[klen] = '\0';
			fprintf(out, "--- kernel ring (last %d bytes)\n", klen);
			fputs(kbuf, out);
			fputc('\n', out);
		}
		free(kbuf);
	}

	fprintf(out, "===== end of incident\n\n");
	fflush(out);
	fsync(fileno(out));
	fclose(out);
	syslog(LOG_WARNING, "incident recorded in %s", logpath);
}

/* ------------------------------------------------------------- reboot cap */

/*
 * Reboot budget, persisted so it survives the reboot it is meant to bound.
 * Without it a daemon that misjudges connectivity would cycle the box
 * forever — the one failure mode that would be worse than the outage it is
 * trying to fix, on hardware nobody can reach.
 */
static int reboot_allowed(void)
{
	char path[256], line[64];
	time_t now = time(NULL), cutoff;
	time_t stamps[64];
	int n = 0, i, kept;
	FILE *f;

	cutoff = now - (time_t)opt_window_h * 3600;
	snprintf(path, sizeof(path), "%s/reboots", opt_dir);

	f = fopen(path, "r");
	if (f) {
		while (n < (int)(sizeof(stamps) / sizeof(stamps[0])) &&
		       fgets(line, sizeof(line), f)) {
			time_t t = (time_t)strtol(line, NULL, 10);
			if (t > cutoff)
				stamps[n++] = t;
		}
		fclose(f);
	}

	if (n >= opt_max_reboot) {
		syslog(LOG_ERR,
		       "reboot budget exhausted (%d in %dh) — refusing to reboot, "
		       "staying up so the box remains diagnosable",
		       n, opt_window_h);
		return 0;
	}

	f = fopen(path, "w");
	if (!f) {
		/* Cannot persist the budget → cannot bound the loop → do not
		 * reboot. Failing closed is the only safe direction here. */
		syslog(LOG_ERR, "cannot write %s: %s — refusing to reboot",
		       path, strerror(errno));
		return 0;
	}
	kept = 0;
	for (i = 0; i < n; i++)
		if (fprintf(f, "%ld\n", (long)stamps[i]) > 0)
			kept++;
	fprintf(f, "%ld\n", (long)now);
	fflush(f);
	fsync(fileno(f));
	fclose(f);
	syslog(LOG_WARNING, "reboot %d of %d allowed in the last %dh",
	       kept + 1, opt_max_reboot, opt_window_h);
	return 1;
}

/* Clean reboot: busybox init runs rcK, which brings eth0 down and so stops the
 * CPU-port DMA engine. Never reboot(2) — that skips even this. */
static void do_reboot(void)
{
	pid_t pid = fork();

	if (pid == 0) {
		execl("/sbin/reboot", "reboot", (char *)NULL);
		_exit(127);
	}
	if (pid < 0)
		syslog(LOG_ERR, "fork for reboot failed: %s", strerror(errno));
}

/* -------------------------------------------------------------------- run */

static void usage(void)
{
	fprintf(stderr,
		"netwatch v%s — reboot and record a gateway isolated on a live link\n"
		"Usage: netwatch [-i IFACE] [-t TARGET]... [-w FAIL_MIN] [-p POLL_SEC]\n"
		"                [-m MAX_REBOOTS] [-W WINDOW_H] [-d DIR] [-n] [-v]\n",
		VERSION);
}

int main(int argc, char **argv)
{
	int c, sock, bad_rounds = 0, acted = 0;
	long bad_since = -1, fail_secs;
	uint16_t id, seq = 0;

	while ((c = getopt(argc, argv, "i:t:w:p:m:W:d:nvh")) != -1) {
		switch (c) {
		case 'i': opt_iface = optarg; break;
		case 't':
			if (ntargets < MAX_TARGETS)
				snprintf(targets[ntargets++], INET_ADDRSTRLEN,
					 "%s", optarg);
			break;
		case 'w': opt_fail_min = atoi(optarg); break;
		case 'p': opt_poll_sec = atoi(optarg); break;
		case 'm': opt_max_reboot = atoi(optarg); break;
		case 'W': opt_window_h = atoi(optarg); break;
		case 'd': opt_dir = optarg; break;
		case 'n': opt_dry_run = 1; break;
		case 'v': opt_verbose = 1; break;
		default:  usage(); return 1;
		}
	}

	if (opt_poll_sec < 1)  opt_poll_sec = 1;
	if (opt_fail_min < 1)  opt_fail_min = 1;

	openlog("netwatch", LOG_PID, LOG_DAEMON);
	signal(SIGTERM, on_term);
	signal(SIGINT, on_term);
	signal(SIGCHLD, SIG_IGN);

	if (mkdir(opt_dir, 0755) != 0 && errno != EEXIST)
		syslog(LOG_ERR, "mkdir %s: %s", opt_dir, strerror(errno));

	sock = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
	if (sock < 0) {
		syslog(LOG_ERR, "raw ICMP socket: %s — netwatch cannot run",
		       strerror(errno));
		return 1;
	}

	id = (uint16_t)(getpid() & 0xffff);
	fail_secs = (long)opt_fail_min * 60;

	syslog(LOG_INFO,
	       "v%s started: iface=%s poll=%ds window=%dmin cap=%d/%dh dir=%s%s",
	       VERSION, opt_iface, opt_poll_sec, opt_fail_min,
	       opt_max_reboot, opt_window_h, opt_dir,
	       opt_dry_run ? " DRY-RUN" : "");

	while (!stop_requested) {
		int carrier, reach;
		long now_up = read_uptime();

		/* No explicit targets → track the default route each round. */
		if (ntargets == 0) {
			char gw[INET_ADDRSTRLEN];

			if (read_default_gw(gw, sizeof(gw)) == 0) {
				snprintf(targets[0], INET_ADDRSTRLEN, "%s", gw);
				ntargets = 1;
			}
		}

		carrier = read_carrier();
		if (carrier != 1) {
			/* Cable out or peer down: physical, not our business.
			 * Hold the streak at zero so a maintenance unplug can
			 * never accumulate into a reboot. */
			if (bad_since >= 0)
				syslog(LOG_INFO, "carrier down — streak cleared");
			bad_rounds = 0;
			bad_since = -1;
			acted = 0;
			goto nap;
		}

		if (ntargets == 0) {
			if (opt_verbose)
				syslog(LOG_INFO, "no target yet (no default route)");
			goto nap;
		}

		reach = probe_targets(sock, id, ++seq);
		if (reach < 0) {
			syslog(LOG_ERR, "probe error: %s", strerror(errno));
			goto nap;
		}

		if (reach) {
			if (bad_since >= 0)
				syslog(LOG_INFO,
				       "reachable again after %lds unreachable "
				       "(%d rounds)",
				       now_up >= 0 ? now_up - bad_since : -1,
				       bad_rounds);
			bad_rounds = 0;
			bad_since = -1;
			acted = 0;
			if (opt_verbose)
				syslog(LOG_DEBUG, "probe ok");
			goto nap;
		}

		bad_rounds++;
		if (bad_since < 0)
			bad_since = now_up;

		/* Elapsed wall time, not a round count: each round also carries
		 * the probe wait, so counting rounds silently stretched the
		 * advertised window (caught on the bench). */
		{
			long elapsed = (now_up >= 0 && bad_since >= 0)
					? now_up - bad_since : 0;

			if (opt_verbose || bad_rounds == 1)
				syslog(LOG_WARNING,
				       "no target reachable with carrier up "
				       "(%lds/%lds, %d rounds)",
				       elapsed, fail_secs, bad_rounds);

			if (elapsed < fail_secs || acted)
				goto nap;
		}

		{
			char reason[160];
			int will_reboot;

			snprintf(reason, sizeof(reason),
				 "no ICMP reply from any target for %ld s "
				 "(%d rounds) while %s carrier is up",
				 now_up >= 0 && bad_since >= 0 ? now_up - bad_since : -1,
				 bad_rounds, opt_iface);

			will_reboot = !opt_dry_run && reboot_allowed();
			write_incident(reason, will_reboot);

			if (will_reboot) {
				syslog(LOG_WARNING, "rebooting via /sbin/reboot");
				do_reboot();
				/* init takes it from here; stop probing. */
				break;
			}
			/* Dry run or budget exhausted: record once, then keep
			 * watching so recovery is still noticed and logged. */
			acted = 1;
		}
nap:
		{
			struct timespec ts;

			ts.tv_sec  = opt_poll_sec;
			ts.tv_nsec = 0;
			nanosleep(&ts, NULL);
		}
	}

	close(sock);
	syslog(LOG_INFO, "stopped");
	closelog();
	return 0;
}
