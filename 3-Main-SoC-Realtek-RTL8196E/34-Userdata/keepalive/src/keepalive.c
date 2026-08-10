// SPDX-License-Identifier: MIT
/*
 * keepalive — minimal process supervisor for the Lidl Silvercrest Gateway.
 *
 * Runs one child command, waits on it, and restarts it with a capped
 * exponential backoff when it exits on its own. On SIGTERM/SIGINT it forwards
 * the signal to the child, waits for it, and exits without restarting — so the
 * init stop path (e.g. "S70otbr stop") terminates the supervised service
 * cleanly instead of fighting an auto-restart.
 *
 * Written in C on purpose: the supervisor must outlive long-running services
 * without itself executing the busybox ash interpreter, whose long-lived loops
 * were then taking intermittent SIGSEGV/SIGILL here (issue #109 — the S70otbr
 * monitor sub-shell; the same fault class that retired the s40button shell
 * loop in v3.3.1). A C parent blocked in waitpid() never runs ash.
 *
 * That fault class no longer exists: it was root-caused to our own
 * local_flush_tlb_all() sweeping from a hardcoded TLB index instead of the
 * Wired boundary (0 on this core, so slots 0-7 were never invalidated) and
 * fixed. Do not cite it as a reason to avoid ash in new code. C is still the
 * right shape for a supervisor for its own reasons — a parent that blocks in
 * waitpid() forks nothing per cycle and has no shell of its own to reap.
 *
 * Usage: keepalive [-n NAME] CMD [ARG...]
 *   -n NAME   tag for syslog messages (default: basename of CMD)
 *
 * J. Nilo, May 2026
 */

#include <errno.h>
#include <getopt.h>
#include <libgen.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

#define BACKOFF_BASE_SEC	1
#define BACKOFF_MAX_SEC		60
#define STABLE_SEC		10	/* child must run this long to reset backoff */

static volatile sig_atomic_t stop_requested;
static volatile sig_atomic_t child_pid;

static void on_term(int sig)
{
	stop_requested = 1;
	if (child_pid > 0)
		kill(child_pid, sig);
}

int main(int argc, char **argv)
{
	const char *name = NULL;
	unsigned int backoff = BACKOFF_BASE_SEC;
	struct sigaction sa;
	sigset_t block, orig;
	int opt;

	/* "+": stop option parsing at the first non-option so the supervised
	 * command keeps its own flags (otbr-agent has -d, -I, ...). */
	while ((opt = getopt(argc, argv, "+n:")) != -1) {
		switch (opt) {
		case 'n':
			name = optarg;
			break;
		default:
			fprintf(stderr, "usage: keepalive [-n NAME] CMD [ARG...]\n");
			return 2;
		}
	}
	if (optind >= argc) {
		fprintf(stderr, "usage: keepalive [-n NAME] CMD [ARG...]\n");
		return 2;
	}
	if (!name)
		name = basename(argv[optind]);

	openlog("keepalive", LOG_PID, LOG_DAEMON);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_term;	/* no SA_RESTART: waitpid()/sleep() must be interruptible */
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	sigemptyset(&block);
	sigaddset(&block, SIGTERM);
	sigaddset(&block, SIGINT);

	syslog(LOG_INFO, "supervising '%s'", name);

	while (!stop_requested) {
		time_t t0 = time(NULL);
		pid_t pid;
		int status, w;

		/* Block term signals across fork + child_pid publication so a
		 * signal arriving in that window is not lost: we either forward
		 * it explicitly below, or it is delivered (and forwarded) the
		 * moment we unblock, before waitpid() sleeps. */
		sigprocmask(SIG_BLOCK, &block, &orig);
		pid = fork();
		if (pid < 0) {
			sigprocmask(SIG_SETMASK, &orig, NULL);
			syslog(LOG_ERR, "%s: fork failed: %m", name);
			sleep(backoff);
			continue;
		}
		if (pid == 0) {
			/* child: restore default dispositions + mask, then exec */
			signal(SIGTERM, SIG_DFL);
			signal(SIGINT, SIG_DFL);
			sigprocmask(SIG_SETMASK, &orig, NULL);
			execvp(argv[optind], &argv[optind]);
			fprintf(stderr, "keepalive: exec %s: %s\n",
				argv[optind], strerror(errno));
			_exit(127);
		}

		child_pid = pid;
		if (stop_requested)
			kill(pid, SIGTERM);
		sigprocmask(SIG_SETMASK, &orig, NULL);

		do {
			w = waitpid(pid, &status, 0);
		} while (w < 0 && errno == EINTR);
		child_pid = 0;

		if (stop_requested) {
			syslog(LOG_INFO, "%s: stop requested, exiting", name);
			break;
		}

		if (WIFEXITED(status))
			syslog(LOG_WARNING, "%s: exited (code %d), restarting",
			       name, WEXITSTATUS(status));
		else if (WIFSIGNALED(status))
			syslog(LOG_WARNING, "%s: died (signal %d), restarting",
			       name, WTERMSIG(status));

		if (time(NULL) - t0 >= STABLE_SEC) {
			backoff = BACKOFF_BASE_SEC;	/* ran long enough: healthy */
		} else {
			sleep(backoff);			/* interruptible by SIGTERM */
			backoff *= 2;
			if (backoff > BACKOFF_MAX_SEC)
				backoff = BACKOFF_MAX_SEC;
		}
	}

	closelog();
	return 0;
}
