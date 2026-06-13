// SPDX-License-Identifier: MIT
/*
 * linkwatch — re-trigger DHCP on link-up for the Lidl Silvercrest Gateway.
 *
 * busybox udhcpc has no carrier awareness: it is started once at boot and,
 * once bound, never re-DISCOVERs on its own. If the gateway is moved to a
 * different LAN/subnet (cable unplugged → replugged elsewhere) it keeps its
 * stale lease until T1/T2 expiry — minutes to hours of being unreachable
 * (issue #132, reported on the G4 beta but board-agnostic — reproduced on the
 * Lidl bench).
 *
 * linkwatch polls /sys/class/net/<iface>/carrier and, on every 0->1
 * transition, pokes the running udhcpc: SIGUSR2 (release the current lease)
 * then SIGUSR1 (trigger a fresh DISCOVER). udhcpc then re-acquires on whatever
 * network is now present. This is the exact fix mechanism validated by hand on
 * the bench for #132.
 *
 * DHCP mode only: S10network launches it from the DHCP branch alone (the
 * static-IP branch never does), so there is nothing to gate here — if a
 * static /userdata/etc/eth0.conf exists, linkwatch is simply never started.
 *
 * Written in C, like keepalive / s40button: a long-lived busybox-ash poll
 * loop takes intermittent SIGSEGV/SIGILL on this platform (issue #109). A C
 * daemon blocked in nanosleep() never runs ash, so it cannot hit that fault.
 *
 * Usage: linkwatch [-i IFACE] [-p UDHCPC_PIDFILE] [-t POLL_SEC]
 *   -i IFACE    interface to watch          (default: eth0)
 *   -p PIDFILE  udhcpc pidfile to signal    (default: /var/run/udhcpc0.pid)
 *   -t POLL_SEC carrier poll period seconds (default: 2)
 *
 * J. Nilo, June 2026
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define DEF_IFACE	"eth0"
#define DEF_PIDFILE	"/var/run/udhcpc0.pid"
#define DEF_POLL_SEC	2
#define POKE_GAP_NS	200000000L	/* 200 ms between SIGUSR2 and SIGUSR1 */

static volatile sig_atomic_t stop_requested;

static void on_term(int sig)
{
	(void)sig;
	stop_requested = 1;
}

/* Read /sys/.../carrier. Returns 0 or 1, or -1 when the value is unavailable
 * (interface administratively down → kernel returns EINVAL on read, or the
 * attribute does not exist yet). Callers treat -1 as "unknown, hold state". */
static int read_carrier(const char *path)
{
	char buf[4];
	ssize_t n;
	int fd;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	return buf[0] == '1' ? 1 : 0;
}

/* Read a pid from a pidfile. Returns the pid, or -1 if absent/unparsable. */
static pid_t read_pid(const char *pidfile)
{
	FILE *f;
	long pid = -1;

	f = fopen(pidfile, "r");
	if (!f)
		return -1;
	if (fscanf(f, "%ld", &pid) != 1)
		pid = -1;
	fclose(f);
	if (pid <= 1)
		return -1;
	return (pid_t)pid;
}

/* Poke udhcpc to drop its lease and re-DISCOVER: SIGUSR2 (release) then a short
 * gap then SIGUSR1 (renew → DISCOVER when unbound). The pidfile is re-read on
 * every poke so a restarted udhcpc is still reached. */
static void poke_udhcpc(const char *pidfile)
{
	struct timespec gap = { 0, POKE_GAP_NS };
	pid_t pid = read_pid(pidfile);

	if (pid < 0) {
		syslog(LOG_WARNING, "link up but no udhcpc pid in %s, not poking",
		       pidfile);
		return;
	}
	if (kill(pid, SIGUSR2) < 0) {
		syslog(LOG_WARNING, "SIGUSR2 to udhcpc pid %ld failed: %m",
		       (long)pid);
		return;
	}
	nanosleep(&gap, NULL);
	if (kill(pid, SIGUSR1) < 0) {
		syslog(LOG_WARNING, "SIGUSR1 to udhcpc pid %ld failed: %m",
		       (long)pid);
		return;
	}
	syslog(LOG_INFO, "link up: poked udhcpc pid %ld (release + discover)",
	       (long)pid);
}

int main(int argc, char **argv)
{
	const char *iface = DEF_IFACE;
	const char *pidfile = DEF_PIDFILE;
	unsigned int poll_sec = DEF_POLL_SEC;
	char carrier_path[128];
	struct sigaction sa;
	int prev, opt;

	while ((opt = getopt(argc, argv, "i:p:t:")) != -1) {
		switch (opt) {
		case 'i':
			iface = optarg;
			break;
		case 'p':
			pidfile = optarg;
			break;
		case 't':
			poll_sec = (unsigned int)strtoul(optarg, NULL, 10);
			if (poll_sec == 0)
				poll_sec = DEF_POLL_SEC;
			break;
		default:
			fprintf(stderr,
				"usage: linkwatch [-i IFACE] [-p PIDFILE] [-t POLL_SEC]\n");
			return 2;
		}
	}

	snprintf(carrier_path, sizeof(carrier_path),
		 "/sys/class/net/%s/carrier", iface);

	openlog("linkwatch", LOG_PID, LOG_DAEMON);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_term;	/* no SA_RESTART: sleep() must be interruptible */
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	/* Seed the previous state with the current carrier so we only fire on a
	 * genuine down→up transition, never once at startup (the boot-time
	 * udhcpc already handles the initial acquisition). */
	prev = read_carrier(carrier_path);
	syslog(LOG_INFO, "watching %s (carrier=%d), pidfile %s, poll %us",
	       iface, prev, pidfile, poll_sec);

	while (!stop_requested) {
		int cur;

		sleep(poll_sec);
		if (stop_requested)
			break;

		cur = read_carrier(carrier_path);
		if (cur < 0)
			continue;		/* unknown: hold last known state */

		if (prev <= 0 && cur == 1)	/* down/unknown → up */
			poke_udhcpc(pidfile);

		prev = cur;
	}

	syslog(LOG_INFO, "stopping");
	closelog();
	return 0;
}
