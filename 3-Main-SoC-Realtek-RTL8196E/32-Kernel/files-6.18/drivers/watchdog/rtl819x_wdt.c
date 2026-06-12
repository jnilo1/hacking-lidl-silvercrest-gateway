// SPDX-License-Identifier: GPL-2.0-only
/*
 * Watchdog driver for the Realtek RTL8196E SoC
 *
 * The SoC exposes a single 32-bit Watchdog Timer Control Register
 * (WDTCNR) at sysc + 0x311C. Field layout (verified against the
 * RTL8196E-CG datasheet, Track ID JATR-3375-16 Rev. 1.0, table 27):
 *
 *   [31:24] WDTE         0xA5 = stop, anything else = run
 *   [23]    WDTCLR       Write 1 to clear the up-counter (kick)
 *   [22:21] OVSEL[1:0]   Lower overflow-select bits
 *   [20]    WDIND        Set on a watchdog-triggered reset (W1C)
 *   [19]    NRFRstType   POR-strap; not relevant at runtime
 *   [18:17] OVSEL[3:2]   Higher overflow-select bits
 *   [16:0]  reserved
 *
 * OVSEL[3:0] is a 4-bit selector that picks the overflow tick count:
 *
 *   0000:2^15  0001:2^16  0010:2^17  0011:2^18  (SDK V3.4.7.3 default)
 *   0100:2^19  0101:2^20  0110:2^21  0111:2^22
 *   1000:2^23  1001:2^24  (max bucket)
 *
 * The watchdog tick is derived from CDBR (sysc + 0x3118), which is
 * shared with Timer0/Timer1: tick = system_clock / DivFactor. As of
 * v3.5.0 (WDT-005 closed), `timer-rtl819x` is fed a 25 kHz `slowclk`
 * fixed-clock so DivFactor=8000 (matching the SDK BSP). At 25 kHz
 * the OVSEL=1001 bucket overflows in ~671 s, giving a userspace
 * BusyBox `watchdog -t 30 /dev/watchdog` ~22× margin against the
 * largest reachable timeout.
 *
 * The driver also registers a system restart handler so a kernel
 * `reboot` flows through the notifier chain (firing before the
 * arch-level `_machine_restart`) and resets via WDTCNR=0 — the same
 * sequence arch_reset uses, retained as a fallback for the case
 * where this driver is unloaded or has not yet probed.
 *
 * Copyright (C) 2026 Jacques Nilo
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/hrtimer.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/notifier.h>
#include <linux/of.h>
#include <linux/of_reserved_mem.h>
#include <linux/panic_notifier.h>
#include <linux/platform_device.h>
#include <linux/timekeeping.h>
#include <linux/timer.h>
#include <linux/watchdog.h>

#include <asm/irq_regs.h>
#include <asm/mach-realtek/realtek_mem.h>
#include <asm/ptrace.h>

#define DRIVER_NAME		"rtl819x-wdt"
#define DRV_VERSION		"1.5"

/*
 * WDTCNR bit layout (sysc + 0x311C) — verified against the
 * RTL8196E-CG datasheet (Track ID JATR-3375-16 Rev. 1.0, table 27).
 *
 *   [31:24] WDTE         Watchdog Enable. 0xA5 stops the timer; any
 *                        other byte enables it. Default 0xA5.
 *   [23]    WDTCLR       Watchdog Clear. Write 1 to clear (refresh)
 *                        the up-counter. Hardware auto-clears the bit.
 *   [22:21] OVSEL[1:0]   Lower Overflow Select bits.
 *   [20]    WDIND        Watchdog Event Indicator. Set by hardware on
 *                        a watchdog-triggered reset; W1C.
 *   [19]    NRFRstType   NOR Flash reset command type (POR-strap,
 *                        not relevant to runtime arming).
 *   [18:17] OVSEL[3:2]   Higher Overflow Select bits.
 *   [16:0]  reserved
 *
 * OVSEL[3:0] determines the overflow tick count:
 *   0000: 2^15  0001: 2^16  0010: 2^17  0011: 2^18  (SDK default)
 *   0100: 2^19  0101: 2^20  0110: 2^21  0111: 2^22
 *   1000: 2^23  1001: 2^24  (max bucket)
 *
 * The watchdog tick is derived from CDBR (sysc + 0x3118), shared with
 * Timer0/Timer1: tick = system_clock / DivFactor. As of v3.5.0, the
 * `timer-rtl819x` driver runs from a 25 kHz `slowclk` DT node so
 * DivFactor=8000 and OVSEL=1001 overflows in ~671 s — see the
 * "WDT-005 closure" section of AUDIT.md and the slowclk node in
 * arch/mips/boot/dts/realtek/rtl819x.dtsi.
 */
#define WDTE_SHIFT		24
#define WDTE_MASK		(0xFFU << WDTE_SHIFT)
#define WDTE_STOP		(0xA5U << WDTE_SHIFT)
#define WDTCLR			BIT(23)
#define WDIND			BIT(20)

/*
 * Compose the OVSEL field from a 4-bit selector value.
 *   Lower 2 bits → [22:21], upper 2 bits → [18:17].
 */
#define WDT_OVSEL(sel) \
	((((u32)(sel) & 0x3U) << 21) | ((((u32)(sel) >> 2) & 0x3U) << 17))

#define WDT_OVSEL_MAX		WDT_OVSEL(0x9)	/* 2^24 ≈ 671 s @ 25 kHz CDBR */

/*
 * Arm pattern (run with max bucket). Stop pattern: same OVSEL bits with
 * WDTE=0xA5 so a subsequent re-enable does not have to reconfigure the
 * selector.
 */
#define WDT_ENABLE_PATTERN	WDT_OVSEL_MAX
#define WDT_DISABLE_PATTERN	(WDTE_STOP | WDT_OVSEL_MAX)

/*
 * Default and bounds for `struct watchdog_device::timeout`. The chip
 * is always armed with OVSEL=1001 (~671 s overflow at slowclk=25 kHz);
 * `timeout` is the soft contract with userspace / the framework, not
 * a hardware register. The framework pings at timeout/2 when
 * WDOG_HW_RUNNING is set, so default=60 s lines up with the BusyBox
 * S25watchdog `-t 30 /dev/watchdog` cadence.
 */
#define WDT_TIMEOUT_SECS_DEFAULT	60U
#define WDT_TIMEOUT_SECS_MIN		1U
#define WDT_TIMEOUT_SECS_MAX		671U

/*
 * Sysc range we dump at probe for diagnostics. The block at sysc+0x3100
 * holds the timer + watchdog registers (datasheet section 8.2.1).
 */
#define WDT_BRINGUP_DUMP_FIRST	0x3100
#define WDT_BRINGUP_DUMP_LAST	0x3120

/*
 * Panic record — a compact post-mortem left in DRAM that survives the
 * watchdog reset, so a gateway that auto-recovers from a soft-lockup hang
 * (WDT-008) can tell the operator *why* on the next boot, instead of losing
 * the soft-lockup report to the volatile ramfs /var/log.
 *
 * Storage reuses the reserved-memory `no-map` page already carved out for
 * boothold (the `boothold` DT node — `boothold@1ffe000` on the Lidl board;
 * see 34-Userdata/boothold/src/boothold.c). The page is bound to the
 * watchdog node through a `memory-region = <&boothold>;` phandle and
 * resolved at probe via of_reserved_mem_lookup(), so a board that
 * relocates the reservation (different DRAM size, e.g. the 64 MiB Sengled
 * G4) moves the record with it — and a DTS without the property or the
 * reservation cleanly disables the post-mortem feature instead of
 * scribbling over unreserved RAM. boothold uses the TOP of the page,
 * growing DOWN from page_top: HOLD magic (page_top-4), TFTP-IP magic
 * (page_top-8) and packed IPv4 (page_top-12) — the v3.7.0
 * download-mode-IP handoff. This record uses the BASE of the page,
 * growing UP (ends at base+0x144), leaving a ~3.8 KB gap so the two never
 * collide even if boothold gains more fields. The page is no-map, so the
 * kernel never treats it as general RAM — the record is not clobbered
 * between the panic write and the next-boot read. A panic reboot does not
 * set HOLD, so the bootloader boots straight through without touching the
 * page; and boothold proves empirically that this page survives the same
 * WDTCNR=0 reset the panic notifier triggers.
 *
 * Record layout within the mapped window (little-endian u32 + raw bytes):
 *   +0x00  u32   magic     "PANC", written LAST so a half-written record
 *                          is never mistaken for valid on the next boot.
 *   +0x04  u32   version
 *   +0x08  u32   uptime_sec  seconds since boot at panic (boottime clock,
 *                            not jiffies/HZ — jiffies starts at INITIAL_JIFFIES
 *                            ~= -300*HZ to flush wrap bugs, so it is not 0 at
 *                            boot; ktime_get_boottime_seconds() matches
 *                            /proc/uptime and is safe to read in atomic context)
 *   +0x0C  u32   fn_addr     running timer callback addr, or 0 (resolved to
 *                            a symbol at next-boot read via %pS — never in
 *                            the atomic panic path)
 *   +0x10  char  reason[]    panic message string (the notifier `data` arg)
 *   +0xF0  u32   epc         program counter of the interrupted (stuck) context,
 *                            or 0 if the panic was not taken from IRQ context.
 *                            For a soft-lockup the panic is raised by the
 *                            watchdog hrtimer firing off the local timer IRQ,
 *                            still nested in that IRQ when the notifier runs, so
 *                            get_irq_regs()->cp0_epc IS the stuck PC. This names
 *                            the #99 culprit that fn_addr cannot: the storm sits
 *                            *between* timer callbacks, where running_timer is
 *                            already cleared to NULL. Resolved via %pS at next
 *                            boot, like fn_addr — never in the atomic path.
 *   +0xF4  u32   ra          return address ($31) of the interrupted context,
 *                            or 0. The epc often lands on a tiny leaf helper
 *                            (issue #99's stuck PC is arch_local_irq_enable+0x14,
 *                            whose caller handle_softirqs is the frame that
 *                            actually names the storm), so ra is the more
 *                            informative of the pair. Resolved via %pS too.
 *   +0xF8  u32   softirq     local_softirq_pending() at panic. epc/ra only say
 *                            "stuck in the softirq dispatcher"; this bitmask
 *                            says *which* softirq is storming (TIMER vs NET_RX
 *                            vs RCU ...). Read mid-storm it shows the bits the
 *                            stuck handler keeps re-raising — i.e. the
 *                            perpetuators. Decoded to names at next-boot read.
 *   +0x100 u32   n_tfns      number of timer-wheel candidate fns that follow
 *   +0x104 u32[] tfns        .function of timers queued in the wheel near
 *                            expiry (timer_collect_pending_fns()). When the
 *                            softirq mask says TIMER, the self-rearming #99
 *                            culprit is among these; the one recurring across
 *                            captures is it. Resolved via %pS at next boot.
 *   +0x120 u32   n_hfns      number of hrtimer candidate fns that follow
 *   +0x124 u32[] hfns        .function of active hrtimers
 *                            (hrtimer_collect_pending_fns()), for an
 *                            HRTIMER_SOFTIRQ storm. watchdog_timer_fn / the
 *                            tick handler appear as expected noise.
 *   +0x13C u32   overdue     jiffies the earliest queued wheel timer is past
 *                            its expiry at panic (timer_wheel_stats()).
 *                            Large (thousands) => the wheel has fallen behind
 *                            and never catches up — a processing death
 *                            spiral; ~0 => the storming vector is re-raised
 *                            over a wheel that is keeping up. The
 *                            discriminator #99 captures were missing.
 *                            0xFFFFFFFF = sentinel "walk did not complete".
 *   +0x140 u32   npend       total timers queued in the wheel at panic.
 *
 * The candidate lists are cold-path only (read in the panic notifier), so
 * normal operation pays nothing — unlike the storm-2/3 hot-path rings that
 * risked perturbing the very timing they measured.
 *
 * Record version history:
 *   v1 (firmware v3.7.0)  magic..reason
 *   v2 (firmware v3.8.0)  + epc@+0xF0, ra@+0xF4, softirq@+0xF8,
 *                           timer/hrtimer candidate lists@+0x100/+0x120
 *   v3 (firmware v3.8.3)  + delayed_work entries in tfns resolved to their
 *                           work->func (kernel-time-timer.c.patch), wheel
 *                           overdue@+0x13C, pending count@+0x140
 */
#define WDT_REC_SIZE		0x200U
#define WDT_REC_MAGIC		0x50414E43U	/* "PANC" */
#define WDT_REC_VERSION		3U
#define WDT_REC_VERSION_V2	2U	/* still decoded: one-boot leftover after upgrade */
#define WDT_REC_OFF_MAGIC	0x00
#define WDT_REC_OFF_VERSION	0x04
#define WDT_REC_OFF_UPTIME	0x08
#define WDT_REC_OFF_FNADDR	0x0C
#define WDT_REC_OFF_REASON	0x10
#define WDT_REC_REASON_MAX	0xE0		/* 0x10+0xE0=0xF0, clear of epc@0xF0 */
#define WDT_REC_OFF_EPC		0xF0		/* u32 stuck PC */
#define WDT_REC_OFF_RA		0xF4		/* u32 stuck $31 */
#define WDT_REC_OFF_SOFTIRQ	0xF8		/* u32 softirq mask */
#define WDT_REC_NR_FNS		6		/* candidates kept per list */
#define WDT_REC_OFF_NTFN	0x100		/* u32 timer-wheel candidate count */
#define WDT_REC_OFF_TFNS	0x104		/* WDT_REC_NR_FNS u32 (..0x11B) */
#define WDT_REC_OFF_NHFN	0x120		/* u32 hrtimer candidate count */
#define WDT_REC_OFF_HFNS	0x124		/* WDT_REC_NR_FNS u32 (..0x13B) */
#define WDT_REC_OFF_LAG		0x13C		/* u32 wheel overdue (jiffies) */
#define WDT_REC_OFF_NPEND	0x140		/* u32 total queued wheel timers (..0x143, clear of boothold@0xFF4) */
#define WDT_REC_STAT_UNSET	0xFFFFFFFFU	/* sentinel: stats walk did not complete */

static bool nowayout = WATCHDOG_NOWAYOUT;
module_param(nowayout, bool, 0444);
MODULE_PARM_DESC(nowayout,
		 "Watchdog cannot be stopped once started (default="
		 __MODULE_STRING(WATCHDOG_NOWAYOUT) ")");

struct rtl819x_wdt {
	struct watchdog_device	wdd;
	void __iomem		*base;
	void __iomem		*rec;	/* panic record page, or NULL */
	struct notifier_block	panic_nb;
};

static inline struct rtl819x_wdt *to_rtl819x_wdt(struct watchdog_device *wdd)
{
	return container_of(wdd, struct rtl819x_wdt, wdd);
}

static int rtl819x_wdt_start(struct watchdog_device *wdd)
{
	struct rtl819x_wdt *wdt = to_rtl819x_wdt(wdd);

	/*
	 * Arm with OVSEL=1001 and WDTCLR=1 in a single write. The kick bit
	 * is mandatory on transition from disabled (WDTE=0xA5) to enabled
	 * (WDTE=0x00) — otherwise the up-counter retains whatever value it
	 * held while disabled and may overflow within microseconds.
	 */
	writel(WDT_ENABLE_PATTERN | WDTCLR, wdt->base);
	return 0;
}

static int rtl819x_wdt_stop(struct watchdog_device *wdd)
{
	struct rtl819x_wdt *wdt = to_rtl819x_wdt(wdd);

	/*
	 * WDTE=0xA5 halts the up-counter. The OVSEL bits are written along
	 * with the stop pattern so a later `.start` does not have to
	 * re-compose them — see WDT_DISABLE_PATTERN.
	 */
	writel(WDT_DISABLE_PATTERN, wdt->base);
	return 0;
}

static int rtl819x_wdt_ping(struct watchdog_device *wdd)
{
	struct rtl819x_wdt *wdt = to_rtl819x_wdt(wdd);
	u32 val;

	/*
	 * RMW with WDTCLR=1 — the up-counter resets on the rising edge of
	 * bit 23. Hardware auto-clears the bit so subsequent reads return
	 * the OVSEL pattern unchanged.
	 */
	val = readl(wdt->base);
	writel(val | WDTCLR, wdt->base);
	return 0;
}

static int rtl819x_wdt_set_timeout(struct watchdog_device *wdd,
				   unsigned int timeout)
{
	/*
	 * No OVSEL recalculation: the chip is always armed at the maximum
	 * bucket (~671 s overflow at slowclk=25 kHz), and `timeout` is the
	 * soft contract that drives userspace / framework ping cadence.
	 * Framework already clamps to [min_timeout, max_timeout].
	 */
	wdd->timeout = timeout;
	return 0;
}

static unsigned int rtl819x_wdt_get_timeleft(struct watchdog_device *wdd)
{
	/*
	 * The hardware does not expose a readable countdown. The
	 * configured timeout is a conservative upper bound on time-until-
	 * reset for any caller that just kicked the chip.
	 */
	return wdd->timeout;
}

static int rtl819x_wdt_restart(struct watchdog_device *wdd,
			       unsigned long action, void *data)
{
	struct rtl819x_wdt *wdt = to_rtl819x_wdt(wdd);

	/*
	 * Same sequence as arch_reset: write 0 to WDTCNR. That sets
	 * WDTE=0x00 (not 0xA5, so the chip starts counting), OVSEL=0
	 * (smallest bucket = 2^15 ticks ≈ 1.31 s at 25 kHz CDBR) and
	 * leaves WDTCLR=0 so we do not kick the freshly-armed counter.
	 * Overflow fires within the bucket window and resets the SoC.
	 *
	 * The mdelay(50) is a small guard so that callers (and any
	 * printk drain on the serial console) get to settle before the
	 * reset lands. It is not load-bearing — the reset will happen
	 * regardless once we return.
	 */
	writel(0, wdt->base);
	mdelay(50);
	return 0;
}

/*
 * Panic notifier — close the soft-lockup blind spot (WDT-008).
 *
 * On RTL8196E (UP, PREEMPT_NONE, single CPU) the watchdog-framework
 * hrtimer that keeps WDOG_HW_RUNNING devices kicked fires from softirq
 * context, which drains on every syscall return. A userspace busy-loop
 * that re-enters the kernel via a fast syscall (e.g. otbr-agent spinning
 * in `waitpid()` returning -ECHILD) therefore lets the
 * softirq drain — and the auto-kicker — keep running indefinitely. The
 * soft-lockup detector reports the hang at 22 s, but the chip never
 * fires because the framework keeps petting it. Observed: 600+ seconds
 * of soft-lockup spam, recovery only via manual power cycle.
 *
 * Wiring the soft-lockup -> panic path (CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y
 * in our defconfig) makes `panic()` run as soon as the detector confirms
 * the hang. panic() calls `local_irq_disable()` very early, which halts
 * the auto-kicker hrtimer on this CPU (the only CPU on UP). We then
 * register on `panic_notifier_list` and write `0` to WDTCNR — same
 * sequence as the `.restart` op: WDTE=0x00 re-enables the chip, OVSEL=0
 * arms the smallest bucket (~1.31 s at slowclk=25 kHz), WDTCLR=0 leaves
 * the counter free-running. Reset fires within the bucket window.
 *
 * Net result: a hang that previously needed a power cycle now reboots
 * autonomously in ~23 s (22 s detection + ~1.31 s chip overflow), which
 * is the entire point of shipping the hardware watchdog in v3.5.0.
 *
 * Priority is pinned to INT_MAX (see probe) so we run at the head of
 * the panic notifier chain. If a higher-priority crash-dump notifier
 * ever wedged on a console flush or a cross-call, our chip-arming
 * write would never land and recovery would fall back to the slower
 * CONFIG_PANIC_TIMEOUT path WDT-008 was meant to bypass. NOTIFY_DONE
 * lets subsequent notifiers continue to run within the ~1.31 s grace
 * window before the chip overflows — crashlog dumpers still get a
 * turn. See WDT-009 in AUDIT.md.
 *
 * Atomic notifier: callback runs in atomic context, must not sleep. The
 * chip-arming write and the panic-record writes below are all plain MMIO /
 * memcpy_toio into uncached mappings — no sleeping, no allocation. The
 * culprit function pointer is stored raw and only resolved to a symbol on
 * the next boot, so no kallsyms lookup happens in this atomic path.
 */
static int rtl819x_wdt_panic_notify(struct notifier_block *nb,
				    unsigned long action, void *data)
{
	struct rtl819x_wdt *wdt = container_of(nb, struct rtl819x_wdt, panic_nb);

	/*
	 * Leave a post-mortem in the reserved DRAM page before arming the
	 * reset. Two complementary culprit pointers:
	 *
	 *   fn_addr  timer_get_running_fn() — the timer callback executing on
	 *            this (sole, UP) CPU, or NULL if the panic landed between
	 *            callbacks.
	 *   epc/ra   get_irq_regs()->{cp0_epc,regs[31]} — the PC and return
	 *            address of the context the panic interrupted. A soft-lockup
	 *            panic is raised by the watchdog hrtimer off the local timer
	 *            IRQ, and we are still nested in that IRQ here, so these
	 *            resolve the stuck location even when the storm sits between
	 *            callbacks (fn_addr == NULL — the #99 case). ra names the
	 *            real frame when epc lands on a leaf helper. NULL irq_regs
	 *            (e.g. a process-context sysrq panic) stores 0.
	 *   softirq  local_softirq_pending() — which softirq vector is storming
	 *            when epc/ra only say "stuck in handle_softirqs". Always
	 *            valid (per-CPU read, not regs-dependent).
	 *   tfns/hfns timer_collect_pending_fns()/hrtimer_collect_pending_fns() —
	 *            candidate callback addresses queued near expiry. When the
	 *            softirq mask points at TIMER/HRTIMER, the self-rearming
	 *            culprit is among these.
	 *
	 * Ordering is deliberate and safety-first:
	 *   1. Write the *core* record — only non-walking reads (uptime, reason,
	 *      fn, epc, ra, softirq), candidate counts zeroed — then magic last
	 *      (with a barrier) so the next boot never reads a torn record.
	 *   2. Arm the reset: clear the counter while the watchdog is halted,
	 *      then enable (OVSEL=0 → ~1.31 s grace). Two writes, deliberately
	 *      — see the race note at the arm site below.
	 *   3. ONLY THEN do the best-effort timer/hrtimer wheel walks, within the
	 *      grace window, writing each list's count *after* its entries.
	 * A diagnostic wheel walk must never be able to delay recovery or lose the
	 * core post-mortem: if a walk ever stalls on a corrupt list, the chip
	 * still resets at ~1.31 s and the core record (incl. epc/ra/softirq) is
	 * already committed. The candidate lists are a bonus, not a dependency.
	 */
	if (wdt->rec) {
		void *fn = timer_get_running_fn();
		struct pt_regs *regs = get_irq_regs();
		const char *reason = data ? (const char *)data : "";
		size_t n = strnlen(reason, WDT_REC_REASON_MAX - 1);

		writel(WDT_REC_VERSION, wdt->rec + WDT_REC_OFF_VERSION);
		writel((u32)ktime_get_boottime_seconds(), wdt->rec + WDT_REC_OFF_UPTIME);
		writel((u32)(uintptr_t)fn, wdt->rec + WDT_REC_OFF_FNADDR);
		writel(regs ? (u32)regs->cp0_epc : 0, wdt->rec + WDT_REC_OFF_EPC);
		writel(regs ? (u32)regs->regs[31] : 0, wdt->rec + WDT_REC_OFF_RA);
		writel((u32)local_softirq_pending(), wdt->rec + WDT_REC_OFF_SOFTIRQ);
		writel(0, wdt->rec + WDT_REC_OFF_NTFN);	/* until the walks below fill them */
		writel(0, wdt->rec + WDT_REC_OFF_NHFN);
		writel(WDT_REC_STAT_UNSET, wdt->rec + WDT_REC_OFF_LAG);
		writel(0, wdt->rec + WDT_REC_OFF_NPEND);
		memset_io(wdt->rec + WDT_REC_OFF_REASON, 0, WDT_REC_REASON_MAX);
		memcpy_toio(wdt->rec + WDT_REC_OFF_REASON, reason, n);
		wmb();
		writel(WDT_REC_MAGIC, wdt->rec + WDT_REC_OFF_MAGIC);
		wmb();
	}

	/*
	 * Arm the ~1.31 s reset (OVSEL=0 = 2^15 ticks @ 25 kHz) before any
	 * best-effort wheel walk — in TWO steps, and that matters:
	 *
	 * When the userspace kicker has the watchdog running (OVSEL=9), the
	 * up-counter at panic time holds up to kick-interval x 25k ticks,
	 * far above the 2^15 OVSEL=0 threshold. A single arm write — bare 0
	 * (v1.3) or 0|WDTCLR — lets the enable see that stale counter
	 * before the kick takes effect, and the chip resets INSTANTLY: the
	 * bench breadcrumbs showed not even one instruction after the write
	 * executing, which is how v1.3 silently lost every candidate list
	 * (timers=[none]). Clearing the counter while the watchdog is still
	 * halted (WDTE=0xA5 + WDTCLR), then enabling, removes the race: the
	 * counter provably starts from 0.
	 */
	writel(WDT_DISABLE_PATTERN | WDTCLR, wdt->base);
	writel(0, wdt->base);

	if (wdt->rec) {
		void *fns[WDT_REC_NR_FNS];
		unsigned long overdue;
		unsigned int npend;
		int i, nt, nh;

		nt = timer_collect_pending_fns(fns, WDT_REC_NR_FNS);
		for (i = 0; i < nt; i++)
			writel((u32)(uintptr_t)fns[i],
			       wdt->rec + WDT_REC_OFF_TFNS + i * 4);
		wmb();
		writel((u32)nt, wdt->rec + WDT_REC_OFF_NTFN);	/* count last: torn read sees 0 */

		nh = hrtimer_collect_pending_fns(fns, WDT_REC_NR_FNS);
		for (i = 0; i < nh; i++)
			writel((u32)(uintptr_t)fns[i],
			       wdt->rec + WDT_REC_OFF_HFNS + i * 4);
		wmb();
		writel((u32)nh, wdt->rec + WDT_REC_OFF_NHFN);

		/* Wheel backlog last: candidates are the irreplaceable part. */
		timer_wheel_stats(&overdue, &npend);
		writel((u32)npend, wdt->rec + WDT_REC_OFF_NPEND);
		wmb();
		writel((u32)overdue, wdt->rec + WDT_REC_OFF_LAG); /* clears the sentinel */
	}

	return NOTIFY_DONE;
}

/*
 * Softirq vector names, indexed to match the kernel's softirq enum
 * (include/linux/interrupt.h: HI, TIMER, NET_TX, NET_RX, BLOCK, IRQ_POLL,
 * TASKLET, SCHED, HRTIMER, RCU). Kept local so the decode does not depend on
 * the non-exported kernel softirq_to_name[] (works built-in or as a module).
 * The ordering is a long-stable kernel ABI (RCU is documented to stay last).
 */
static const char * const rtl819x_wdt_softirq_names[] = {
	"HI", "TIMER", "NET_TX", "NET_RX", "BLOCK",
	"IRQ_POLL", "TASKLET", "SCHED", "HRTIMER", "RCU",
};

/* Render a softirq pending bitmask as "TIMER|HRTIMER" into buf. */
static void rtl819x_wdt_softirq_decode(u32 mask, char *buf, size_t len)
{
	size_t pos = 0;
	unsigned int i;

	buf[0] = '\0';
	for (i = 0; i < ARRAY_SIZE(rtl819x_wdt_softirq_names); i++) {
		if (!(mask & BIT(i)))
			continue;
		pos += scnprintf(buf + pos, len - pos, "%s%s",
				 pos ? "|" : "", rtl819x_wdt_softirq_names[i]);
	}
	if (!pos)
		scnprintf(buf, len, "none");
}

/*
 * Render a candidate function list (count at @off_n, WDT_REC_NR_FNS u32 at
 * @off_fns) as "fnA|fnB|..." via %pS into buf. Process context — kallsyms OK.
 */
static void rtl819x_wdt_fns_decode(struct rtl819x_wdt *wdt, u32 off_n,
				   u32 off_fns, char *buf, size_t len)
{
	size_t pos = 0;
	u32 i, n = readl(wdt->rec + off_n);

	buf[0] = '\0';
	if (n > WDT_REC_NR_FNS)
		n = WDT_REC_NR_FNS;
	for (i = 0; i < n; i++) {
		u32 a = readl(wdt->rec + off_fns + i * 4);

		pos += scnprintf(buf + pos, len - pos, "%s%pS",
				 pos ? "|" : "", (void *)(uintptr_t)a);
	}
	if (!pos)
		scnprintf(buf, len, "none");
}

/*
 * Decode and clear the panic record left by the notifier above. One-shot:
 * the magic is cleared after reporting so the line lands in dmesg exactly
 * once — on the boot following the panic. An init script (S26panicrec)
 * copies that line into /userdata for persistence across the volatile ramfs
 * log. Resolving epc/ra/fn_addr with %pS here (process context, same kernel
 * image as the panic) keeps the atomic notifier free of any kallsyms call.
 */
static void rtl819x_wdt_report_panic_record(struct rtl819x_wdt *wdt)
{
	struct device *dev = wdt->wdd.parent;
	char reason[WDT_REC_REASON_MAX];
	char sirq[64], tfns[256], hfns[256], wstat[48];
	u32 up, fna, epc, ra, sirqmask, ver;

	if (!wdt->rec)
		return;
	if (readl(wdt->rec + WDT_REC_OFF_MAGIC) != WDT_REC_MAGIC)
		return;

	ver = readl(wdt->rec + WDT_REC_OFF_VERSION);
	up  = readl(wdt->rec + WDT_REC_OFF_UPTIME);
	fna = readl(wdt->rec + WDT_REC_OFF_FNADDR);
	epc = readl(wdt->rec + WDT_REC_OFF_EPC);
	ra  = readl(wdt->rec + WDT_REC_OFF_RA);
	sirqmask = readl(wdt->rec + WDT_REC_OFF_SOFTIRQ);
	memcpy_fromio(reason, wdt->rec + WDT_REC_OFF_REASON, WDT_REC_REASON_MAX);
	reason[WDT_REC_REASON_MAX - 1] = '\0';

	if (ver == WDT_REC_VERSION || ver == WDT_REC_VERSION_V2) {
		rtl819x_wdt_softirq_decode(sirqmask, sirq, sizeof(sirq));
		rtl819x_wdt_fns_decode(wdt, WDT_REC_OFF_NTFN, WDT_REC_OFF_TFNS,
				       tfns, sizeof(tfns));
		rtl819x_wdt_fns_decode(wdt, WDT_REC_OFF_NHFN, WDT_REC_OFF_HFNS,
				       hfns, sizeof(hfns));
		wstat[0] = '\0';
		if (ver >= WDT_REC_VERSION) {
			u32 lag = readl(wdt->rec + WDT_REC_OFF_LAG);
			u32 npend = readl(wdt->rec + WDT_REC_OFF_NPEND);

			if (lag != WDT_REC_STAT_UNSET)
				scnprintf(wstat, sizeof(wstat),
					  " overdue=%uj pending=%u", lag, npend);
		}
		dev_info(dev,
			 "previous boot ended in panic: uptime=%us pc=%pS ra=%pS running=%pS softirq=0x%x[%s] timers=[%s] hrtimers=[%s]%s reason=\"%s\"\n",
			 up, (void *)(uintptr_t)epc, (void *)(uintptr_t)ra,
			 (void *)(uintptr_t)fna, sirqmask, sirq, tfns, hfns,
			 wstat, reason);
	} else {
		dev_info(dev, "previous boot ended in panic (unknown record v%u)\n",
			 ver);
	}

	writel(0, wdt->rec + WDT_REC_OFF_MAGIC);	/* one-shot */
}

static void rtl819x_wdt_panic_unregister(void *data)
{
	struct rtl819x_wdt *wdt = data;

	atomic_notifier_chain_unregister(&panic_notifier_list, &wdt->panic_nb);
}

static const struct watchdog_info rtl819x_wdt_info = {
	.options	= WDIOF_SETTIMEOUT | WDIOF_KEEPALIVEPING |
			  WDIOF_MAGICCLOSE,
	.identity	= DRIVER_NAME,
};

static const struct watchdog_ops rtl819x_wdt_ops = {
	.owner		= THIS_MODULE,
	.start		= rtl819x_wdt_start,
	.stop		= rtl819x_wdt_stop,
	.ping		= rtl819x_wdt_ping,
	.set_timeout	= rtl819x_wdt_set_timeout,
	.get_timeleft	= rtl819x_wdt_get_timeleft,
	.restart	= rtl819x_wdt_restart,
};

/*
 * Debug aid kept behind dev_dbg: dump sysc[0x3100..0x3120] at probe so
 * we can correlate cold-boot vs watchdog-fired vs software-reboot
 * register values across runs and refine the reset-cause decoder if
 * a future SoC rev populates WDIND reliably (see WDT-001). Not emitted
 * on a normal boot; enable with `dyndbg="file rtl819x_wdt.c +p"` on
 * the kernel cmdline or via /sys/kernel/debug/dynamic_debug/control.
 *
 * We deliberately use the global sr_r32() macro instead of the
 * regmap+syscon pattern: the syscon DT node only declares a
 * 0x1000-byte register window, so a regmap_read() of 0x3100 is
 * rejected with -EIO. sr_r32() goes through the same _sys_membase
 * ioremap that arch_reset uses, which on MIPS is a KSEG1 alias
 * (uncached window mapping the first 512 MiB of physical address
 * space directly) — reads at any offset within that window resolve
 * via fixed MMU translation regardless of the resource size.
 */
static void rtl819x_wdt_dump_bringup(struct rtl819x_wdt *wdt)
{
	struct device *dev = wdt->wdd.parent;
	unsigned int off;

	dev_dbg(dev, "bringup register dump (sysc+0x%x..0x%x):\n",
		WDT_BRINGUP_DUMP_FIRST, WDT_BRINGUP_DUMP_LAST);
	for (off = WDT_BRINGUP_DUMP_FIRST;
	     off <= WDT_BRINGUP_DUMP_LAST;
	     off += 4)
		dev_dbg(dev, "  +0x%04x: 0x%08x\n", off, sr_r32(off));
}

static int rtl819x_wdt_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct reserved_mem *rmem = NULL;
	struct rtl819x_wdt *wdt;
	struct device_node *np;
	struct resource *res;
	u32 raw;
	int ret;

	wdt = devm_kzalloc(dev, sizeof(*wdt), GFP_KERNEL);
	if (!wdt)
		return -ENOMEM;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	wdt->base = devm_ioremap_resource(dev, res);
	if (IS_ERR(wdt->base))
		return PTR_ERR(wdt->base);

	wdt->wdd.info		= &rtl819x_wdt_info;
	wdt->wdd.ops		= &rtl819x_wdt_ops;
	wdt->wdd.parent		= dev;
	wdt->wdd.min_timeout	= WDT_TIMEOUT_SECS_MIN;
	wdt->wdd.max_timeout	= WDT_TIMEOUT_SECS_MAX;
	wdt->wdd.timeout	= WDT_TIMEOUT_SECS_DEFAULT;

	/* DT timeout-sec wins over the default if specified. */
	watchdog_init_timeout(&wdt->wdd, 0, dev);
	watchdog_set_nowayout(&wdt->wdd, nowayout);
	watchdog_set_restart_priority(&wdt->wdd, 192);

	/*
	 * Decode and report the previous reset cause from WDIND. The bit
	 * is set by the SoC on a watchdog-triggered reset and cleared
	 * (W1C) by writing 1 to it. Per empirical observation on
	 * RTL8196E rev. 0xb08, WDIND can read as 0 even after a
	 * watchdog-triggered reboot — we still log what we see and let
	 * future bringup data refine WDT-001 in AUDIT.md.
	 */
	raw = readl(wdt->base);
	dev_info(dev, "last reset: %s (WDTCNR=0x%08x)\n",
		 (raw & WDIND) ? "watchdog timeout" : "power-on / pin reset",
		 raw);
	if (raw & WDIND)
		writel(raw | WDIND, wdt->base);	/* W1C */

	/*
	 * Adoption: if WDTE is non-0xA5 the chip is enabled and counting,
	 * so flag WDOG_HW_RUNNING. The framework then keeps the chip
	 * kicked at timeout/2 cadence in two cases:
	 *   (a) during the boot window before userspace opens
	 *       /dev/watchdog and takes over feeding;
	 *   (b) after a userspace feeder closes /dev/watchdog without
	 *       writing the Magic-Close `V` byte — e.g. BusyBox
	 *       `watchdog -t 30 /dev/watchdog` killed by SIGKILL. With
	 *       `nowayout=0` the framework would otherwise let the chip
	 *       overflow; HW_RUNNING preserves the safety net until a
	 *       new feeder shows up.
	 * We re-read after the W1C above so the value reflects
	 * post-clear state.
	 */
	raw = readl(wdt->base);
	if ((raw & WDTE_MASK) != WDTE_STOP) {
		set_bit(WDOG_HW_RUNNING, &wdt->wdd.status);
		dev_info(dev, "adopting pre-armed watchdog (WDTCNR=0x%08x)\n",
			 raw);
	}

	/*
	 * Resolve the reserved DRAM page used for the panic record from the
	 * memory-region phandle (the board's `boothold` reservation), then
	 * map it (no-map, so not in the kernel linear map — ioremap is the
	 * right accessor; it is uncached on MIPS, which is what we need for
	 * a value that must reach DRAM before the reset). Report-and-clear
	 * any record left by the previous boot. A missing property, missing
	 * reservation or map failure only disables the post-mortem feature;
	 * the watchdog itself is unaffected.
	 */
	np = of_parse_phandle(dev->of_node, "memory-region", 0);
	if (np) {
		rmem = of_reserved_mem_lookup(np);
		of_node_put(np);
	}
	if (rmem && rmem->size >= WDT_REC_SIZE) {
		wdt->rec = devm_ioremap(dev, rmem->base, WDT_REC_SIZE);
		if (!wdt->rec)
			dev_warn(dev, "panic record region map failed; post-mortem disabled\n");
	} else {
		dev_warn(dev, "no usable memory-region reservation; post-mortem disabled\n");
	}
	rtl819x_wdt_report_panic_record(wdt);

	rtl819x_wdt_dump_bringup(wdt);

	ret = devm_watchdog_register_device(dev, &wdt->wdd);
	if (ret) {
		dev_err(dev, "watchdog_register_device failed: %d\n", ret);
		return ret;
	}

	/*
	 * Soft-lockup -> panic -> HW reset path (WDT-008). See the
	 * rtl819x_wdt_panic_notify() comment block for the full rationale.
	 * Priority pinned to INT_MAX so we run at the head of the panic
	 * notifier chain — see WDT-009 in AUDIT.md.
	 */
	wdt->panic_nb.notifier_call = rtl819x_wdt_panic_notify;
	wdt->panic_nb.priority	    = INT_MAX;
	ret = atomic_notifier_chain_register(&panic_notifier_list,
					     &wdt->panic_nb);
	if (ret) {
		dev_err(dev, "panic notifier register failed: %d\n", ret);
		return ret;
	}
	ret = devm_add_action_or_reset(dev, rtl819x_wdt_panic_unregister, wdt);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, wdt);

	dev_info(dev, "v" DRV_VERSION " (J. Nilo) - timeout:%us, nowayout:%d\n",
		 wdt->wdd.timeout, nowayout);

	return 0;
}

static const struct of_device_id rtl819x_wdt_of_match[] = {
	{ .compatible = "realtek,rtl8196e-wdt" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, rtl819x_wdt_of_match);

static struct platform_driver rtl819x_wdt_driver = {
	.probe	= rtl819x_wdt_probe,
	.driver	= {
		.name		= DRIVER_NAME,
		.of_match_table	= rtl819x_wdt_of_match,
	},
};

module_platform_driver(rtl819x_wdt_driver);


MODULE_AUTHOR("Jacques Nilo");
MODULE_DESCRIPTION("Hardware watchdog for Realtek RTL8196E SoC");
MODULE_VERSION(DRV_VERSION);
MODULE_LICENSE("GPL v2");
