// SPDX-License-Identifier: GPL-2.0-only
/*
 * Watchdog driver for the Realtek RTL8196E SoC
 *
 * The SoC exposes a single 32-bit Watchdog Timer Control Register
 * (WDTCNR) at sysc + 0x311C. The field layout, the OVSEL bucket
 * table and the CDBR tick derivation are documented once, at the
 * register #define block below.
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
#include <linux/kernel_stat.h>
#include <linux/kmsg_dump.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/netdevice.h>
#include <linux/notifier.h>
#include <linux/of.h>
#include <linux/of_reserved_mem.h>
#include <linux/panic_notifier.h>
#include <linux/platform_device.h>
#include <linux/preempt.h>
#include <linux/rtl8196e_eth_panic.h>
#include <linux/rtl819x_intc_stats.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/smp.h>
#include <linux/timekeeping.h>
#include <linux/timer.h>
#include <linux/watchdog.h>

#include <asm/addrspace.h>
#include <asm/irq_regs.h>
#include <asm/mach-realtek/realtek_mem.h>
#include <asm/mipsregs.h>
#include <asm/ptrace.h>

#define DRIVER_NAME		"rtl819x-wdt"
#define DRV_VERSION		"1.11"

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
 *   0000: 2^15  0001: 2^16  0010: 2^17  0011: 2^18  (2.6.30-BSP default)
 *   0100: 2^19  0101: 2^20  0110: 2^21  0111: 2^22
 *   1000: 2^23  1001: 2^24  (max bucket; 3.10-BSP default)
 *
 * The watchdog tick is derived from CDBR (sysc + 0x3118), shared with
 * Timer0/Timer1: tick = system_clock / DivFactor. As of v3.5.0, the
 * `timer-rtl819x` driver runs from a 25 kHz `slowclk` DT node so
 * DivFactor=8000 and OVSEL=1001 overflows in ~671 s — see the
 * audit notes (incl. the vendor-lineage section: the 3.10 SDK BSP
 * itself runs 1 MHz with a 16.8 s window) and the slowclk node in
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
 * Default and minimum for `struct watchdog_device::timeout`, plus the
 * fixed hardware window. The chip is always armed with OVSEL=1001
 * (2^24 ticks ≈ 671 s at slowclk=25 kHz); that window is what the
 * hardware really enforces, so it is reported to the core as
 * max_hw_heartbeat_ms rather than faked as a max_timeout. `timeout`
 * stays the soft contract with userspace / the framework, not a
 * hardware register. The framework pings at min(timeout, window)/2
 * when WDOG_HW_RUNNING is set — default=60 s lines up with the
 * BusyBox S25watchdog `-t 30 /dev/watchdog` cadence — and a soft
 * timeout larger than the window is honored by core-generated bridge
 * pings instead of being rejected.
 */
#define WDT_TIMEOUT_SECS_DEFAULT	60U
#define WDT_TIMEOUT_SECS_MIN		1U
#define WDT_HW_WINDOW_MS		671000U	/* OVSEL=1001 @ 25 kHz CDBR */

/*
 * Sysc range we dump at probe for diagnostics. The block at sysc+0x3100
 * holds the timer + watchdog registers (datasheet section 8.2.1).
 */
#define WDT_BRINGUP_DUMP_FIRST	0x3100
#define WDT_BRINGUP_DUMP_LAST	0x3120

/*
 * Panic record — a compact post-mortem left in DRAM that survives the
 * watchdog reset, so a gateway that auto-recovers from a soft-lockup hang
 * can tell the operator *why* on the next boot, instead of losing
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
 * growing UP (ends at base+0x1D3 as of v6), leaving a ~3.6 KB gap so the two
 * never collide even if boothold gains more fields. The page is no-map, so the
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
 *                            boot). Read via the NMI-safe fast accessor
 *                            ktime_get_boot_fast_ns(): the ordinary seqcount
 *                            accessors can spin forever if the panic
 *                            interrupted a timekeeping writer, and
 *                            this read sits ahead of the chip-arm writes.
 *                            Matches /proc/uptime to the second.
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
 *                            the culprit that fn_addr cannot: the storm sits
 *                            *between* timer callbacks, where running_timer is
 *                            already cleared to NULL. Resolved via %pS at next
 *                            boot, like fn_addr — never in the atomic path.
 *   +0xF4  u32   ra          return address ($31) of the interrupted context,
 *                            or 0. The epc often lands on a tiny leaf helper
 *                            (the observed stuck PC is arch_local_irq_enable+0x14,
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
 *                            softirq mask says TIMER, the self-rearming
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
 *                            discriminator earlier record versions were missing.
 *                            0xFFFFFFFF = sentinel "walk did not complete".
 *   +0x140 u32   npend       total timers queued in the wheel at panic.
 *   +0x144 u32[] sirqcnt     per-softirq cumulative run counts on this (sole)
 *                            CPU at panic (kstat_softirqs_cpu), indexed by the
 *                            softirq enum (HI..RCU, WDT_REC_NR_SIRQ entries).
 *                            Read against uptime they give the *average* TIMER
 *                            vs NET_RX softirq rate. The storm has
 *                            TIMER|NET_RX co-pending but the timer wheel is only
 *                            a victim (overdue saturated, pending normal =
 *                            frozen, not flooded), so the timer lists cannot say
 *                            which vector is actually being run/raised — this
 *                            does.
 *   +0x16C u32   hardirq     total hardirq count on this CPU at panic
 *                            (kstat_cpu_irqs_sum). /uptime = average IRQ rate;
 *                            an external (eth/NET_RX) IRQ storm inflates even a
 *                            multi-day average, an internal softirq re-raise
 *                            leaves it near the idle baseline. The eth RX line
 *                            is "Switch"/IP3 on this SoC (see irq-rtl819x).
 *   +0x170 u32   n_napi      number of NAPI poll fns that follow.
 *   +0x174 u32[] napifns     .poll of the napi instances on this CPU's
 *                            softnet_data.poll_list at panic — the NET_RX analog
 *                            of tfns: names the driver (the rtl8196e eth poll)
 *                            whose NAPI is perpetually scheduled when NET_RX is
 *                            the storm. softnet_data is a normal per-CPU export,
 *                            so unlike the timer collectors this needs no kernel
 *                            patch. Resolved via %pS at next boot.
 *   +0x190 u32   eth_flags   1 if the eth recovery snapshot below is valid (the
 *                            interface was up at panic), else 0. v5.
 *   +0x194 u32   eth_resync  rtl8196e rx_runout_resync at panic — poll-side
 *                            full resyncs performed. The decisive datum:
 *                            >0 means the poll detector fired and the storm
 *                            continued anyway (resync insufficient); ==0 means
 *                            it never fired (the detection gate is wrong).
 *   +0x198 u32   eth_kick    rx_runout_kick — periodic swcore-watchdog NAPI
 *                            kicks (the 1 s belt-and-suspenders path).
 *   +0x19C u32   eth_zero    rx_runout_zero — in-progress consecutive zero-work
 *                            polls under RUNOUT at panic. 1 or 2 (never the
 *                            resync threshold of 3) directly shows the
 *                            consecutive-zero gate being reset mid-storm.
 *   +0x1A0 u32   eth_seen    swcore_runout_seen — in-progress consecutive
 *                            periodic checks with RUNOUT asserted at panic.
 *   +0x1A4 u32   eth_iisr    live CPUIISR at panic — *which* eth interrupt
 *                            source is asserted (PKTHDR_DESC_RUNOUT vs RX_DONE
 *                            vs MBUF runout). Names the storming bit when
 *                            eth_resync==0. Raw hex; interpreted off-box.
 *   +0x1A8 u32   eth_iimr    live CPUIIMR at panic — which sources are unmasked
 *                            (iisr & iimr = what is actually firing).
 *   +0x1AC u32   eth_rxidx   rtl8196e RX ring cursor at panic — where the poll
 *                            sat relative to the switch RX pointer.
 *   +0x1B0 u32   eth_rxdesc  rx_pkthdr_ring[rx_idx] at panic — OWNED bit set
 *                            (SWCORE) proves the switch still owns the slot the
 *                            poll is parked on = the §6 RX desync. (v6)
 *   +0x1B4 u32   eth_txprod  TX producer index. (v6)
 *   +0x1B8 u32   eth_txcons  TX consumer (next-to-reclaim) index. (v6)
 *   +0x1BC u32   eth_txfree  free TX descriptor slots. (v6)
 *   +0x1C0 u32   eth_txdesc  tx_ring[tx_cons] — OWNED across the stall means
 *                            TX-done is stuck (the vendor SDK's hang condition,
 *                            a stall class distinct from RX runout). (v6)
 *   +0x1C4 u32   eth_cpuicr  live CPUICR — CPU-port RX/TX DMA enable. (v6)
 *   +0x1C8 u32   eth_sirr    live SIRR — switch interface (TRXRDY). (v6)
 *   +0x1CC u32   eth_rxpkts  dev rx_packets (low 32) — forward-progress gauge:
 *                            unchanged across captures = nothing received. (v6)
 *   +0x1D0 u32   eth_txpkts  dev tx_packets (low 32) — forward-progress gauge. (v6)
 *
 * The candidate lists are cold-path only (read in the panic notifier), so
 * normal operation pays nothing — unlike the earlier hot-path probe rings
 * that risked perturbing the very timing they measured.
 *
 * Record version history:
 *   v1 (firmware v3.7.0)  magic..reason
 *   v2 (firmware v3.8.0)  + epc@+0xF0, ra@+0xF4, softirq@+0xF8,
 *                           timer/hrtimer candidate lists@+0x100/+0x120
 *   v3 (firmware v3.8.3)  + delayed_work entries in tfns resolved to their
 *                           work->func (kernel-time-timer.c.patch), wheel
 *                           overdue@+0x13C, pending count@+0x140
 *   v4 (firmware v3.8.4)  + per-softirq run counts@+0x144, total hardirq
 *                           count@+0x16C, NAPI poll-list fns@+0x170/+0x174 —
 *                           names the NET_RX side the timer lists cannot
 *   v5 (firmware v4.0.0)  + rtl8196e eth recovery snapshot@+0x190..+0x1AC
 *                           (resync/kick/zero/seen counters + live CPUIISR/
 *                           CPUIIMR + rx_idx), pulled via the __weak
 *                           rtl8196e_eth_panic_snapshot() — disambiguates
 *                           "resync fired but failed" from "never fired"
 *                           after a field recurrence of the storm.
 *   v6 (firmware v4.0.0)  + switch-core/TX/ring-progress state@+0x1B0..+0x1D0
 *                           (rx_desc@rx_idx, tx_prod/cons/free, tx_desc@tx_cons,
 *                           CPUICR, SIRR, rx/tx_packets) — tells an RX-runout
 *                           storm from a broader switch-core or TX-done stall
 *                           (the vendor stuck-detector watched TX-done).
 */
#define WDT_REC_SIZE		0x280U	/* v7 core record (offsets unchanged) */
#define WDT_REC_MAGIC		0x50414E43U	/* "PANC" */
/*
 * Record v8 (2026-07-08) — the justification the v7 freeze note demanded:
 * the first fully-instrumented field crash (issue #99, v4.0.0-rc4, frtz13
 * uptime 676476 s) showed every v7 eth detector counter at ZERO — the record
 * proved the previous root-cause theory wrong but could not name the actual
 * storming interrupt line. v8 turns the final-frame snapshot into a film:
 *   - v8 scalar block @+0x200..+0x2FF: jiffies, CP0 Cause/Status, GIMR/GISR,
 *     preempt_count, current->comm, a raw UART1 8250 register snapshot
 *     (IER/IIR/LSR/MSR/MCR — the prime storm suspect line), INTC dispatch
 *     stats (incl. the empty-pending count no other counter sees), per-line
 *     last-seen jiffies, and the eth activity taps (counters + last-activity
 *     stamps + NAPI state + RX ring bases).
 *   - flight recorder @+0x280..+0x767: the newest 31 one-second samples of
 *     per-line interrupt/softirq/NAPI deltas, sampled by a storm-proof
 *     HRTIMER_MODE_REL_HARD timer (the same context the softlockup detector
 *     provably keeps running from during the field hang).
 *   - printk tail @+0x768..+0xFEF: the last ~2 KB of the kernel log at
 *     panic — contains the softlockup report (incl. the compiled-in
 *     INTR_STORM per-IRQ utilization table) and the backtrace that headless
 *     field units could never show us. Strictly best-effort: length marker
 *     written last, pre-cleared, so a failed dump can't corrupt the decode.
 * The v7 core record (offsets 0x000..0x1FF) is byte-compatible.
 * Page top 0xFF0..0xFFF belongs to boothold — never written here.
 */
#define WDT_MAP_SIZE		0x1000U	/* v8 maps the whole reserved page */
#define WDT_PAGE_GUARD		0xFF0U	/* first byte we must NOT touch (boothold) */
#define WDT_REC_VERSION		8U
#define WDT_REC_VERSION_V7	7U	/* still decoded: one-boot leftover after upgrade */
#define WDT_REC_VERSION_V6	6U	/* still decoded: one-boot leftover after upgrade */
#define WDT_REC_VERSION_V5	5U	/* still decoded: one-boot leftover after upgrade */
#define WDT_REC_VERSION_V4	4U	/* still decoded: one-boot leftover after upgrade */
#define WDT_REC_VERSION_V3	3U	/* still decoded: one-boot leftover after upgrade */
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
#define WDT_REC_OFF_NPEND	0x140		/* u32 total queued wheel timers (..0x143) */
#define WDT_REC_NR_SIRQ		10U		/* per-softirq counts kept (>= NR_SOFTIRQS) */
#define WDT_REC_OFF_SIRQCNT	0x144		/* WDT_REC_NR_SIRQ u32 (..0x16B) */
#define WDT_REC_OFF_HARDIRQ	0x16C		/* u32 total hardirq count */
#define WDT_REC_OFF_NNAPI	0x170		/* u32 NAPI poll-fn count */
#define WDT_REC_OFF_NAPIFNS	0x174		/* WDT_REC_NR_FNS u32 (..0x18B) */
/* v5: rtl8196e eth recovery snapshot (..0x1AF, clear of boothold@0xFF4) */
#define WDT_REC_OFF_ETH_FLAGS	0x190		/* u32 1 if snapshot valid (eth up) */
#define WDT_REC_OFF_ETH_RESYNC	0x194		/* u32 rx_runout_resync */
#define WDT_REC_OFF_ETH_KICK	0x198		/* u32 rx_runout_kick */
#define WDT_REC_OFF_ETH_ZERO	0x19C		/* u32 rx_runout_zero (in-progress) */
#define WDT_REC_OFF_ETH_SEEN	0x1A0		/* u32 swcore_runout_seen (in-progress) */
#define WDT_REC_OFF_ETH_IISR	0x1A4		/* u32 live CPUIISR */
#define WDT_REC_OFF_ETH_IIMR	0x1A8		/* u32 live CPUIIMR */
#define WDT_REC_OFF_ETH_RXIDX	0x1AC		/* u32 RX ring cursor */
/* v6: switch-core / DMA / ring-progress state (..0x1D3, clear of boothold@0xFF4) */
#define WDT_REC_OFF_ETH_RXDESC	0x1B0		/* u32 rx_pkthdr_ring[rx_idx] */
#define WDT_REC_OFF_ETH_TXPROD	0x1B4		/* u32 TX producer index */
#define WDT_REC_OFF_ETH_TXCONS	0x1B8		/* u32 TX consumer index */
#define WDT_REC_OFF_ETH_TXFREE	0x1BC		/* u32 free TX slots */
#define WDT_REC_OFF_ETH_TXDESC	0x1C0		/* u32 tx_ring[tx_cons] */
#define WDT_REC_OFF_ETH_CPUICR	0x1C4		/* u32 live CPUICR */
#define WDT_REC_OFF_ETH_SIRR	0x1C8		/* u32 live SIRR */
#define WDT_REC_OFF_ETH_RXPKTS	0x1CC		/* u32 dev rx_packets (low 32) */
#define WDT_REC_OFF_ETH_TXPKTS	0x1D0		/* u32 dev tx_packets (low 32) */
/* v7: bounded-poll detector state + A/B discriminator + switch desync (..0x1FF, clear of boothold@0xFF4) */
#define WDT_REC_OFF_ETH_POLLHIT		0x1D4	/* u32 poll_budget_hit */
#define WDT_REC_OFF_ETH_STALLRUN	0x1D8	/* u32 rx_stall_run (detector run) */
#define WDT_REC_OFF_ETH_DEEPRST		0x1DC	/* u32 swcore_deep_reset */
#define WDT_REC_OFF_ETH_RPDCR0		0x1E0	/* u32 live CPURPDCR0 (switch RX pkthdr ptr) */
#define WDT_REC_OFF_ETH_RMDCR0		0x1E4	/* u32 live CPURMDCR0 (switch RX mbuf ptr) */
#define WDT_REC_OFF_ETH_WILDPH		0x1E8	/* u32 diag rx_wild_pkthdr     (A) */
#define WDT_REC_OFF_ETH_WILDMB		0x1EC	/* u32 diag rx_wild_mbuf       (A) */
#define WDT_REC_OFF_ETH_NOSHADOW	0x1F0	/* u32 diag rx_mbuf_no_shadow  (A) */
#define WDT_REC_OFF_ETH_SKEW		0x1F4	/* u32 diag rx_pkthdr_mbuf_skew (A) */
#define WDT_REC_OFF_ETH_BADLEN		0x1F8	/* u32 diag rx_bad_len         (B) */
#define WDT_REC_OFF_ETH_P6DCR0		0x1FC	/* u32 live P6_DCR0 (CPU-port desc counter) */
#define WDT_REC_STAT_UNSET	0xFFFFFFFFU	/* sentinel: stats walk did not complete */

/* ---- v8 scalar block @0x200..0x2FF (see the v8 rationale above) ---- */
#define WDT_REC_OFF_V8_JIFFIES	0x200	/* u32 jiffies at panic (anchor for the stamps) */
#define WDT_REC_OFF_V8_CAUSE	0x204	/* u32 CP0 Cause — which IPs are pending */
#define WDT_REC_OFF_V8_STATUS	0x208	/* u32 CP0 Status — which IPs are enabled, IE bit */
#define WDT_REC_OFF_V8_GIMR	0x20C	/* u32 INTC global mask */
#define WDT_REC_OFF_V8_GISR	0x210	/* u32 INTC global status */
#define WDT_REC_OFF_V8_PREEMPT	0x214	/* u32 preempt_count() — hardirq/softirq nesting */
#define WDT_REC_OFF_V8_COMM	0x218	/* char[16] current->comm (interrupted task) */
#define WDT_REC_OFF_V8_U1_IER	0x228	/* u32 raw UART1 IER (value in bits 31:24) */
#define WDT_REC_OFF_V8_U1_IIR	0x22C	/* u32 raw UART1 IIR */
#define WDT_REC_OFF_V8_U1_LSR	0x230	/* u32 raw UART1 LSR */
#define WDT_REC_OFF_V8_U1_MSR	0x234	/* u32 raw UART1 MSR */
#define WDT_REC_OFF_V8_U1_MCR	0x238	/* u32 raw UART1 MCR */
#define WDT_REC_OFF_V8_INTC_ENT	0x23C	/* u32 INTC chained-handler entries */
#define WDT_REC_OFF_V8_INTC_EMP	0x240	/* u32 INTC entries with empty pending */
#define WDT_REC_OFF_V8_LS_TC0	0x244	/* u32 last-seen jiffies, GISR bit 8 (TC0) */
#define WDT_REC_OFF_V8_LS_UART0	0x248	/* u32 last-seen jiffies, GISR bit 12 (UART0) */
#define WDT_REC_OFF_V8_LS_UART1	0x24C	/* u32 last-seen jiffies, GISR bit 13 (UART1) */
#define WDT_REC_OFF_V8_LS_ETH	0x250	/* u32 last-seen jiffies, GISR bit 15 (switch) */
#define WDT_REC_OFF_V8_E_ISRCNT	0x254	/* u32 eth ISR invocations */
#define WDT_REC_OFF_V8_E_ISRJ	0x258	/* u32 jiffies at last eth ISR */
#define WDT_REC_OFF_V8_E_BURST	0x25C	/* u32 eth ISR per-jiffy burst high-water */
#define WDT_REC_OFF_V8_E_POLLC	0x260	/* u32 NAPI poll invocations */
#define WDT_REC_OFF_V8_E_POLLJ	0x264	/* u32 jiffies at last NAPI poll */
#define WDT_REC_OFF_V8_E_DLV	0x268	/* u32 packets delivered by the poll (sum) */
#define WDT_REC_OFF_V8_E_KICKT	0x26C	/* u32 tx-reclaim timer napi_schedule kicks */
#define WDT_REC_OFF_V8_E_KICKJ	0x270	/* u32 jiffies at last tx-reclaim kick */
#define WDT_REC_OFF_V8_E_NAPI	0x274	/* u32 live napi->state bits */
#define WDT_REC_OFF_V8_E_PHBASE	0x278	/* u32 rx_pkthdr_ring base (KSEG1, vs cpurpdcr0) */
#define WDT_REC_OFF_V8_E_MBBASE	0x27C	/* u32 rx_mbuf_ring base (KSEG1, vs cpurmdcr0) */

/* ---- v8 flight-recorder copy @0x280..0x767 ---- */
#define WDT_FLT_OFF_MAGIC	0x280	/* u32 "FLT1", written LAST (torn-read guard) */
#define WDT_FLT_OFF_NS		0x284	/* u32 samples copied */
#define WDT_FLT_OFF_SSIZE	0x288	/* u32 sizeof(struct rtl819x_wdt_flt_sample) */
#define WDT_FLT_OFF_PERIOD	0x28C	/* u32 sampling period, ms */
#define WDT_FLT_OFF_SAMPLES	0x290	/* samples, oldest first */
#define WDT_FLT_MAGIC		0x464C5431U	/* "FLT1" */
#define WDT_FLT_NS_RAM		64	/* RAM ring depth (~64 s of history) */
#define WDT_FLT_NS_REC		31	/* newest samples copied to DRAM at panic */
#define WDT_FLT_PERIOD_MS	1000

/*
 * ---- v8 printk tail @0x768..0xFEF (strictly best-effort) ----
 * Sized against the softlockup report's print order (kernel/watchdog.c):
 * BUG line → report_cpu_status() (the INTR_STORM per-IRQ table) → modules →
 * show_regs (regs+stack, the ~1.5 KB bulk) → panic banner. The capture keeps
 * the NEWEST bytes, so on overflow the oldest lines clip first — 2180 bytes
 * leaves ~600 B of headroom above the show_regs+banner bulk so the BUG line
 * and the per-IRQ table survive. (Bench-measured: a quiet boot's whole log
 * is ~2 KB, ending exactly at the panic banner.)
 */
#define WDT_TAIL_OFF_LEN	0x768	/* u32 text length, 0 = no/failed capture */
#define WDT_TAIL_OFF_TXT	0x76C
#define WDT_TAIL_MAX		(WDT_PAGE_GUARD - WDT_TAIL_OFF_TXT)	/* 2180 bytes */

/*
 * Platform-constant MMIO the v8 capture reads directly via KSEG1 (uncached,
 * always mapped on MIPS32 — safe in the atomic panic path, no ioremap
 * needed). Same SoC on every supported board (lidl, sengled-e39-g8c).
 * UART1 is "serial@2100" (reg-shift 2, register value in bits 31:24); the
 * INTC is "intc@3000" (GIMR @+0, GISR @+4). See rtl819x.dtsi.
 */
#define WDT_V8_GIMR	((void __iomem *)CKSEG1ADDR(0x18003000))
#define WDT_V8_GISR	((void __iomem *)CKSEG1ADDR(0x18003004))
#define WDT_V8_UART1(r)	((void __iomem *)CKSEG1ADDR(0x18002100 + ((r) << 2)))

/*
 * One 1 Hz flight-recorder sample: u16 saturating deltas of the interrupt/
 * softirq/NAPI counters, plus the raw eth IISR/IIMR and NAPI state. 40 bytes
 * — 31 samples + header fit in 0x280..0x767 with room to spare.
 * d_jiffies proves the sampling cadence (≈ HZ between samples; a gap says
 * the sampler itself was stalled, which is diagnostic in its own right).
 */
struct rtl819x_wdt_flt_sample {
	u32 iisr;		/* live CPUIISR (0 if eth down) */
	u32 iimr;		/* live CPUIIMR */
	u16 d_jiffies;		/* jiffies delta since previous sample */
	u16 d_hardirq;		/* total hardirqs (kstat sum) */
	u16 d_tc0;		/* INTC dispatches, GISR bit 8 */
	u16 d_uart0;		/* INTC dispatches, GISR bit 12 */
	u16 d_uart1;		/* INTC dispatches, GISR bit 13 */
	u16 d_eth_line;		/* INTC dispatches, GISR bit 15 */
	u16 d_net_rx;		/* NET_RX softirq runs */
	u16 d_timer_sirq;	/* TIMER softirq runs */
	u16 d_eth_isr;		/* eth ISR invocations */
	u16 d_poll;		/* NAPI poll invocations */
	u16 d_delivered;	/* packets delivered by the poll */
	u16 d_rxpkts;		/* dev rx_packets */
	u16 d_intc;		/* INTC chained-handler entries */
	u16 d_intc_empty;	/* INTC entries with empty pending */
	u16 napi_state;		/* napi->state low bits */
	u16 pad;
};

static_assert(sizeof(struct rtl819x_wdt_flt_sample) == 40);
static_assert(WDT_FLT_OFF_SAMPLES + WDT_FLT_NS_REC * sizeof(struct rtl819x_wdt_flt_sample)
	      <= WDT_TAIL_OFF_LEN, "flight-recorder copy overruns the printk-tail window");
static_assert(WDT_TAIL_OFF_TXT + WDT_TAIL_MAX <= WDT_PAGE_GUARD,
	      "printk tail overruns the boothold page-top flags");

static_assert(NR_SOFTIRQS <= WDT_REC_NR_SIRQ,
	      "panic-record per-softirq array too small for NR_SOFTIRQS");

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

	/*
	 * Constant write, same pattern as .start: the up-counter resets
	 * on the rising edge of WDTCLR (bit 23), which hardware then
	 * auto-clears. Deliberately NOT a read-modify-write: the RMW used
	 * through v1.5 paid an uncached MMIO read per kick and, worse,
	 * read WDIND back and wrote it back set — W1C-erasing the one
	 * reset-cause bit we are still hoping to observe. Side
	 * effect: a chip adopted with a non-max OVSEL is normalized to
	 * the max bucket on the first kick — exactly what .start would
	 * have done anyway.
	 */
	writel(WDT_ENABLE_PATTERN | WDTCLR, wdt->base);
	return 0;
}

static int rtl819x_wdt_set_timeout(struct watchdog_device *wdd,
				   unsigned int timeout)
{
	/*
	 * No OVSEL recalculation: the chip is always armed at the maximum
	 * bucket (~671 s overflow at slowclk=25 kHz), and `timeout` is the
	 * soft contract that drives userspace / framework ping cadence.
	 * The framework validates against min_timeout and, because we
	 * declare max_hw_heartbeat_ms, bridges any longer soft timeout
	 * with core-generated pings instead of rejecting it.
	 */
	wdd->timeout = timeout;
	return 0;
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
 * Collect the .poll function of each NAPI instance scheduled on this CPU's
 * softnet_data.poll_list — the NET_RX analog of timer_collect_pending_fns().
 * When the RX storm has NET_RX pending, the perpetually-scheduled napi names
 * the driver feeding it (the rtl8196e eth poll). Local to the driver: unlike
 * the timer wheel (static timer_bases in kernel/time/timer.c, reached via a
 * patch), softnet_data is a normal per-CPU export, so no kernel patch is
 * needed. List walk → best-effort, called only after the reset is armed.
 */
static int rtl819x_wdt_collect_napi_fns(void **out, int max)
{
	struct softnet_data *sd = this_cpu_ptr(&softnet_data);
	struct napi_struct *n;
	int cnt = 0;

	list_for_each_entry(n, &sd->poll_list, poll_list) {
		if (cnt >= max)
			break;
		out[cnt++] = n->poll;
	}
	return cnt;
}

/*
 * Panic notifier — close the soft-lockup blind spot.
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
 * CONFIG_PANIC_TIMEOUT path this notifier was meant to bypass. NOTIFY_DONE
 * lets subsequent notifiers continue to run within the ~1.31 s grace
 * window before the chip overflows — crashlog dumpers still get a
 * turn. See the audit notes.
 *
 * Atomic notifier: callback runs in atomic context, must not sleep. The
 * chip-arming write and the panic-record writes below are all plain MMIO /
 * memcpy_toio into uncached mappings — no sleeping, no allocation. The
 * culprit function pointer is stored raw and only resolved to a symbol on
 * the next boot, so no kallsyms lookup happens in this atomic path.
 */
/*
 * Weak default for the eth recovery snapshot (record v5). The rtl8196e-eth driver
 * provides the strong override; this returns false when that driver is not
 * built in, so the notifier records eth_flags=0 instead of failing to link.
 */
__weak bool rtl8196e_eth_panic_snapshot(struct rtl8196e_eth_panic *out)
{
	return false;
}

/* Weak default for the 1 Hz eth flight sample (record v8) — same linkage. */
__weak bool rtl8196e_eth_flight_sample(struct rtl8196e_eth_flight *out)
{
	return false;
}

/*
 * v8 flight recorder. A 1 Hz HRTIMER_MODE_REL_HARD timer samples interrupt/
 * softirq/NAPI counter deltas into a RAM ring; the panic notifier copies the
 * newest WDT_FLT_NS_REC samples into the reserved DRAM page. The hard-hrtimer
 * context is the one context proven to keep running during the field storm
 * (the softlockup detector itself runs there and both detected the hang and
 * measured the frozen wheel mid-storm). Wheel timers are explicitly the
 * wrong tool: the captured hang froze the wheel for 20.8 s.
 *
 * Single instance (one watchdog on this SoC) — file-scope state, written
 * only from the (sole) CPU's hardirq context; the panic notifier reads it
 * from the same CPU, so no locking is needed on this UP platform.
 */
static struct rtl819x_wdt_flt_sample rtl819x_wdt_flt_ring[WDT_FLT_NS_RAM];
static unsigned int rtl819x_wdt_flt_head;	/* next write index */
static struct hrtimer rtl819x_wdt_flt_timer;
static struct {
	u32 jiffies, hardirq, tc0, uart0, uart1, eth_line;
	u32 net_rx, timer_sirq, eth_isr, poll, delivered, rxpkts;
	u32 intc, intc_empty;
} rtl819x_wdt_flt_prev;

/* Saturating u16 delta against the stored previous value. */
static u16 rtl819x_wdt_flt_d(u32 cur, u32 *prev)
{
	u32 d = cur - *prev;

	*prev = cur;
	return d > 0xFFFFU ? 0xFFFFU : (u16)d;
}

static enum hrtimer_restart rtl819x_wdt_flt_fn(struct hrtimer *t)
{
	struct rtl819x_wdt_flt_sample *s =
		&rtl819x_wdt_flt_ring[rtl819x_wdt_flt_head];
	struct rtl8196e_eth_flight ef = {};
	int cpu = smp_processor_id();

	rtl8196e_eth_flight_sample(&ef);	/* leaves zeros if eth is down */

	s->iisr        = ef.iisr;
	s->iimr        = ef.iimr;
	s->d_jiffies   = rtl819x_wdt_flt_d((u32)jiffies, &rtl819x_wdt_flt_prev.jiffies);
	s->d_hardirq   = rtl819x_wdt_flt_d((u32)kstat_cpu_irqs_sum(cpu),
					   &rtl819x_wdt_flt_prev.hardirq);
	s->d_tc0       = rtl819x_wdt_flt_d(rtl819x_intc_stats.count[8],
					   &rtl819x_wdt_flt_prev.tc0);
	s->d_uart0     = rtl819x_wdt_flt_d(rtl819x_intc_stats.count[12],
					   &rtl819x_wdt_flt_prev.uart0);
	s->d_uart1     = rtl819x_wdt_flt_d(rtl819x_intc_stats.count[13],
					   &rtl819x_wdt_flt_prev.uart1);
	s->d_eth_line  = rtl819x_wdt_flt_d(rtl819x_intc_stats.count[15],
					   &rtl819x_wdt_flt_prev.eth_line);
	s->d_net_rx    = rtl819x_wdt_flt_d((u32)kstat_softirqs_cpu(NET_RX_SOFTIRQ, cpu),
					   &rtl819x_wdt_flt_prev.net_rx);
	s->d_timer_sirq = rtl819x_wdt_flt_d((u32)kstat_softirqs_cpu(TIMER_SOFTIRQ, cpu),
					   &rtl819x_wdt_flt_prev.timer_sirq);
	s->d_eth_isr   = rtl819x_wdt_flt_d(ef.isr_cnt, &rtl819x_wdt_flt_prev.eth_isr);
	s->d_poll      = rtl819x_wdt_flt_d(ef.poll_cnt, &rtl819x_wdt_flt_prev.poll);
	s->d_delivered = rtl819x_wdt_flt_d(ef.poll_delivered,
					   &rtl819x_wdt_flt_prev.delivered);
	s->d_rxpkts    = rtl819x_wdt_flt_d(ef.rx_packets, &rtl819x_wdt_flt_prev.rxpkts);
	s->d_intc      = rtl819x_wdt_flt_d(rtl819x_intc_stats.entries,
					   &rtl819x_wdt_flt_prev.intc);
	s->d_intc_empty = rtl819x_wdt_flt_d(rtl819x_intc_stats.empty,
					   &rtl819x_wdt_flt_prev.intc_empty);
	s->napi_state  = (u16)ef.napi_state;
	s->pad         = 0;

	rtl819x_wdt_flt_head = (rtl819x_wdt_flt_head + 1) % WDT_FLT_NS_RAM;

	hrtimer_forward_now(t, ms_to_ktime(WDT_FLT_PERIOD_MS));
	return HRTIMER_RESTART;
}

/*
 * Copy the newest WDT_FLT_NS_REC samples to the DRAM window, oldest first.
 * Deterministic fixed-size copy (no walk) — called from the committed part
 * of the panic notifier, before the chip is armed. Magic written last so a
 * torn copy decodes as "no flight data" rather than garbage.
 */
static void rtl819x_wdt_flt_dump(struct rtl819x_wdt *wdt)
{
	unsigned int idx = (rtl819x_wdt_flt_head + WDT_FLT_NS_RAM - WDT_FLT_NS_REC)
			   % WDT_FLT_NS_RAM;
	unsigned int i;

	for (i = 0; i < WDT_FLT_NS_REC; i++) {
		memcpy_toio(wdt->rec + WDT_FLT_OFF_SAMPLES +
			    i * sizeof(struct rtl819x_wdt_flt_sample),
			    &rtl819x_wdt_flt_ring[idx],
			    sizeof(struct rtl819x_wdt_flt_sample));
		idx = (idx + 1) % WDT_FLT_NS_RAM;
	}
	writel(WDT_FLT_NS_REC, wdt->rec + WDT_FLT_OFF_NS);
	writel(sizeof(struct rtl819x_wdt_flt_sample), wdt->rec + WDT_FLT_OFF_SSIZE);
	writel(WDT_FLT_PERIOD_MS, wdt->rec + WDT_FLT_OFF_PERIOD);
	wmb();
	writel(WDT_FLT_MAGIC, wdt->rec + WDT_FLT_OFF_MAGIC);
}

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
	 *            callbacks (fn_addr == NULL — the soft-lockup case). ra names the
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
		/*
		 * NMI-safe fast accessor, NOT ktime_get_boottime_seconds():
		 * the coarse accessors retry on the timekeeping seqcount and
		 * spin forever if the panic interrupted a timekeeping writer
		 * (CONFIG_PANIC_ON_OOPS promotes an oops in that window to a
		 * panic). This read runs BEFORE the chip-arm writes, so an
		 * unbounded wait here would cost the record AND the fast
		 * reset. div_u64: cold path, Lexra soft-divide
		 * cost irrelevant.
		 */
		writel((u32)div_u64(ktime_get_boot_fast_ns(), NSEC_PER_SEC),
		       wdt->rec + WDT_REC_OFF_UPTIME);
		writel((u32)(uintptr_t)fn, wdt->rec + WDT_REC_OFF_FNADDR);
		writel(regs ? (u32)regs->cp0_epc : 0, wdt->rec + WDT_REC_OFF_EPC);
		writel(regs ? (u32)regs->regs[31] : 0, wdt->rec + WDT_REC_OFF_RA);
		writel((u32)local_softirq_pending(), wdt->rec + WDT_REC_OFF_SOFTIRQ);
		writel(0, wdt->rec + WDT_REC_OFF_NTFN);	/* until the walks below fill them */
		writel(0, wdt->rec + WDT_REC_OFF_NHFN);
		writel(WDT_REC_STAT_UNSET, wdt->rec + WDT_REC_OFF_LAG);
		writel(0, wdt->rec + WDT_REC_OFF_NPEND);
		/*
		 * v4: per-softirq run counts + total hardirq count on this
		 * (sole, UP) CPU. Plain per-CPU counter reads — no list walk —
		 * so they belong in the committed core record (before magic),
		 * not the best-effort section. Cumulative since boot; the next
		 * boot divides by uptime to get the average TIMER vs NET_RX
		 * softirq rate and the hardirq rate, the discriminator the
		 * timer-only record could not give for the frozen-wheel storm.
		 */
		{
			int cpu = smp_processor_id();
			unsigned int s;

			for (s = 0; s < NR_SOFTIRQS; s++)
				writel((u32)kstat_softirqs_cpu(s, cpu),
				       wdt->rec + WDT_REC_OFF_SIRQCNT + s * 4);
			writel((u32)kstat_cpu_irqs_sum(cpu),
			       wdt->rec + WDT_REC_OFF_HARDIRQ);
		}
		writel(0, wdt->rec + WDT_REC_OFF_NNAPI);	/* until the walk below */
		/*
		 * v5: rtl8196e eth recovery snapshot. Plain counter reads + two MMIO
		 * loads (the same the NAPI poll does) — no list walk, no locks —
		 * so it belongs in the committed core record before magic. The
		 * producer is __weak: a kernel without the eth driver leaves the
		 * symbol NULL and we just record eth_flags=0. resync>0 here means
		 * the poll resync fired and the box stormed anyway; resync==0
		 * means it never fired, and eth_iisr names the storming source.
		 */
		{
			struct rtl8196e_eth_panic eth;

			if (rtl8196e_eth_panic_snapshot(&eth)) {
				writel(eth.up,     wdt->rec + WDT_REC_OFF_ETH_FLAGS);
				writel(eth.resync, wdt->rec + WDT_REC_OFF_ETH_RESYNC);
				writel(eth.kick,   wdt->rec + WDT_REC_OFF_ETH_KICK);
				/* zero/seen retired in v7 (RUNOUT-latch model) — keep the
				 * slots zeroed so a v7 record reads unambiguously. */
				writel(0,          wdt->rec + WDT_REC_OFF_ETH_ZERO);
				writel(0,          wdt->rec + WDT_REC_OFF_ETH_SEEN);
				writel(eth.iisr,   wdt->rec + WDT_REC_OFF_ETH_IISR);
				writel(eth.iimr,   wdt->rec + WDT_REC_OFF_ETH_IIMR);
				writel(eth.rx_idx, wdt->rec + WDT_REC_OFF_ETH_RXIDX);
				/* v6: switch-core / DMA / ring-progress state */
				writel(eth.rx_desc,    wdt->rec + WDT_REC_OFF_ETH_RXDESC);
				writel(eth.tx_prod,    wdt->rec + WDT_REC_OFF_ETH_TXPROD);
				writel(eth.tx_cons,    wdt->rec + WDT_REC_OFF_ETH_TXCONS);
				writel(eth.tx_free,    wdt->rec + WDT_REC_OFF_ETH_TXFREE);
				writel(eth.tx_desc,    wdt->rec + WDT_REC_OFF_ETH_TXDESC);
				writel(eth.cpuicr,     wdt->rec + WDT_REC_OFF_ETH_CPUICR);
				writel(eth.sirr,       wdt->rec + WDT_REC_OFF_ETH_SIRR);
				writel(eth.rx_packets, wdt->rec + WDT_REC_OFF_ETH_RXPKTS);
				writel(eth.tx_packets, wdt->rec + WDT_REC_OFF_ETH_TXPKTS);
				/* v7: bounded-poll detector + A/B discriminator + switch desync */
				writel(eth.poll_budget_hit,   wdt->rec + WDT_REC_OFF_ETH_POLLHIT);
				writel(eth.rx_stall_run,      wdt->rec + WDT_REC_OFF_ETH_STALLRUN);
				writel(eth.swcore_deep_reset, wdt->rec + WDT_REC_OFF_ETH_DEEPRST);
				writel(eth.cpurpdcr0,         wdt->rec + WDT_REC_OFF_ETH_RPDCR0);
				writel(eth.cpurmdcr0,         wdt->rec + WDT_REC_OFF_ETH_RMDCR0);
				writel(eth.wild_pkthdr,       wdt->rec + WDT_REC_OFF_ETH_WILDPH);
				writel(eth.wild_mbuf,         wdt->rec + WDT_REC_OFF_ETH_WILDMB);
				writel(eth.mbuf_no_shadow,    wdt->rec + WDT_REC_OFF_ETH_NOSHADOW);
				writel(eth.skew,              wdt->rec + WDT_REC_OFF_ETH_SKEW);
				writel(eth.bad_len,           wdt->rec + WDT_REC_OFF_ETH_BADLEN);
				writel(eth.p6_dcr0,           wdt->rec + WDT_REC_OFF_ETH_P6DCR0);
			} else {
				writel(0, wdt->rec + WDT_REC_OFF_ETH_FLAGS);
			}
			/*
			 * v8 eth activity taps — valid only when the snapshot
			 * above succeeded; zeroed otherwise so the decode
			 * reads unambiguously.
			 */
			if (readl(wdt->rec + WDT_REC_OFF_ETH_FLAGS)) {
				writel(eth.isr_cnt,          wdt->rec + WDT_REC_OFF_V8_E_ISRCNT);
				writel(eth.isr_last_j,       wdt->rec + WDT_REC_OFF_V8_E_ISRJ);
				writel(eth.isr_burst_max,    wdt->rec + WDT_REC_OFF_V8_E_BURST);
				writel(eth.poll_cnt,         wdt->rec + WDT_REC_OFF_V8_E_POLLC);
				writel(eth.poll_last_j,      wdt->rec + WDT_REC_OFF_V8_E_POLLJ);
				writel(eth.poll_delivered,   wdt->rec + WDT_REC_OFF_V8_E_DLV);
				writel(eth.kick_txreclaim,   wdt->rec + WDT_REC_OFF_V8_E_KICKT);
				writel(eth.kick_txreclaim_j, wdt->rec + WDT_REC_OFF_V8_E_KICKJ);
				writel(eth.napi_state,       wdt->rec + WDT_REC_OFF_V8_E_NAPI);
				writel(eth.rx_ph_base,       wdt->rec + WDT_REC_OFF_V8_E_PHBASE);
				writel(eth.rx_mb_base,       wdt->rec + WDT_REC_OFF_V8_E_MBBASE);
			} else {
				unsigned int off;

				for (off = WDT_REC_OFF_V8_E_ISRCNT;
				     off <= WDT_REC_OFF_V8_E_MBBASE; off += 4)
					writel(0, wdt->rec + off);
			}
		}
		/*
		 * v8 scalar block: system-level context the eth snapshot cannot
		 * carry. All plain reads / KSEG1 MMIO loads — committed class.
		 * The jiffies anchor turns every *_last_j / last_seen_j stamp
		 * into "seconds before the panic" with one subtraction.
		 */
		writel((u32)jiffies,        wdt->rec + WDT_REC_OFF_V8_JIFFIES);
		writel(read_c0_cause(),     wdt->rec + WDT_REC_OFF_V8_CAUSE);
		writel(read_c0_status(),    wdt->rec + WDT_REC_OFF_V8_STATUS);
		writel(readl(WDT_V8_GIMR),  wdt->rec + WDT_REC_OFF_V8_GIMR);
		writel(readl(WDT_V8_GISR),  wdt->rec + WDT_REC_OFF_V8_GISR);
		writel((u32)preempt_count(), wdt->rec + WDT_REC_OFF_V8_PREEMPT);
		memcpy_toio(wdt->rec + WDT_REC_OFF_V8_COMM, current->comm,
			    sizeof(current->comm) < 16 ? sizeof(current->comm) : 16);
		/*
		 * Raw UART1 8250 snapshot (prime storm-suspect line). Reads
		 * are side-effect-benign here except IIR (a read can clear a
		 * THRI source) — irrelevant post-mortem, the box is about to
		 * reset. Value sits in bits 31:24 (reg-shift 2 platform).
		 */
		writel(readl(WDT_V8_UART1(1)), wdt->rec + WDT_REC_OFF_V8_U1_IER);
		writel(readl(WDT_V8_UART1(2)), wdt->rec + WDT_REC_OFF_V8_U1_IIR);
		writel(readl(WDT_V8_UART1(5)), wdt->rec + WDT_REC_OFF_V8_U1_LSR);
		writel(readl(WDT_V8_UART1(6)), wdt->rec + WDT_REC_OFF_V8_U1_MSR);
		writel(readl(WDT_V8_UART1(4)), wdt->rec + WDT_REC_OFF_V8_U1_MCR);
		writel(rtl819x_intc_stats.entries, wdt->rec + WDT_REC_OFF_V8_INTC_ENT);
		writel(rtl819x_intc_stats.empty,   wdt->rec + WDT_REC_OFF_V8_INTC_EMP);
		writel(rtl819x_intc_stats.last_seen_j[8],  wdt->rec + WDT_REC_OFF_V8_LS_TC0);
		writel(rtl819x_intc_stats.last_seen_j[12], wdt->rec + WDT_REC_OFF_V8_LS_UART0);
		writel(rtl819x_intc_stats.last_seen_j[13], wdt->rec + WDT_REC_OFF_V8_LS_UART1);
		writel(rtl819x_intc_stats.last_seen_j[15], wdt->rec + WDT_REC_OFF_V8_LS_ETH);
		/* Flight-recorder copy: deterministic, so still committed class. */
		rtl819x_wdt_flt_dump(wdt);
		/* Pre-clear the printk-tail marker: the capture below is best-effort. */
		writel(0, wdt->rec + WDT_TAIL_OFF_LEN);
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
		int i, nt, nh, nn;

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

		/*
		 * v4: NAPI poll-list — names the NET_RX engine the timer lists
		 * structurally cannot. List walk, so best-effort like the timer
		 * walks above; count written last so a torn read sees 0.
		 */
		nn = rtl819x_wdt_collect_napi_fns(fns, WDT_REC_NR_FNS);
		for (i = 0; i < nn; i++)
			writel((u32)(uintptr_t)fns[i],
			       wdt->rec + WDT_REC_OFF_NAPIFNS + i * 4);
		wmb();
		writel((u32)nn, wdt->rec + WDT_REC_OFF_NNAPI);

		/*
		 * v8 printk tail — LAST of the best-effort captures, inside
		 * the ~1.31 s grace window. By this point the log already
		 * holds the softlockup report (utilization block + the
		 * INTR_STORM per-IRQ table when hardirqs ate the CPU), the
		 * backtrace, and the panic banner — everything a serial
		 * console would have shown. kmsg_dump_get_buffer() is the
		 * crash-dumper API: lockless printk ringbuffer readers, fills
		 * the buffer with the NEWEST messages that fit. The length
		 * marker at +0x800 was pre-cleared in the committed section
		 * and is written last: a stall or failure here leaves len=0
		 * and costs nothing but this bonus capture.
		 */
		{
			static char tail[WDT_TAIL_MAX];
			struct kmsg_dump_iter iter;
			size_t len = 0;

			kmsg_dump_rewind(&iter);
			if (kmsg_dump_get_buffer(&iter, true, tail, sizeof(tail),
						 &len) && len) {
				memcpy_toio(wdt->rec + WDT_TAIL_OFF_TXT, tail, len);
				wmb();
				writel((u32)len, wdt->rec + WDT_TAIL_OFF_LEN);
			}
		}
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
 * Decode the v8 additions: scalar block, flight-recorder table, printk tail.
 * Emitted as separate prefixed lines (not appended to the main record line,
 * which already brushes LOG_LINE_MAX): S26panicrec captures the whole
 * "rtl819x-wdt" block. Process context (probe) — kmalloc and long loops OK.
 */
static void rtl819x_wdt_report_v8(struct rtl819x_wdt *wdt)
{
	struct device *dev = wdt->wdd.parent;
	char comm[17];
	u32 pj = readl(wdt->rec + WDT_REC_OFF_V8_JIFFIES);

	memcpy_fromio(comm, wdt->rec + WDT_REC_OFF_V8_COMM, 16);
	comm[16] = '\0';

	dev_info(dev,
		 "v8: jiffies=%u cause=0x%08x status=0x%08x gimr=0x%08x gisr=0x%08x preempt=0x%x comm=\"%s\"\n",
		 pj,
		 readl(wdt->rec + WDT_REC_OFF_V8_CAUSE),
		 readl(wdt->rec + WDT_REC_OFF_V8_STATUS),
		 readl(wdt->rec + WDT_REC_OFF_V8_GIMR),
		 readl(wdt->rec + WDT_REC_OFF_V8_GISR),
		 readl(wdt->rec + WDT_REC_OFF_V8_PREEMPT),
		 comm);
	dev_info(dev,
		 "v8: uart1[ier=0x%02x iir=0x%02x lsr=0x%02x msr=0x%02x mcr=0x%02x] intc=%u empty=%u last_seen(j ago): tc0=%u uart0=%u uart1=%u eth=%u\n",
		 readl(wdt->rec + WDT_REC_OFF_V8_U1_IER) >> 24,
		 readl(wdt->rec + WDT_REC_OFF_V8_U1_IIR) >> 24,
		 readl(wdt->rec + WDT_REC_OFF_V8_U1_LSR) >> 24,
		 readl(wdt->rec + WDT_REC_OFF_V8_U1_MSR) >> 24,
		 readl(wdt->rec + WDT_REC_OFF_V8_U1_MCR) >> 24,
		 readl(wdt->rec + WDT_REC_OFF_V8_INTC_ENT),
		 readl(wdt->rec + WDT_REC_OFF_V8_INTC_EMP),
		 pj - readl(wdt->rec + WDT_REC_OFF_V8_LS_TC0),
		 pj - readl(wdt->rec + WDT_REC_OFF_V8_LS_UART0),
		 pj - readl(wdt->rec + WDT_REC_OFF_V8_LS_UART1),
		 pj - readl(wdt->rec + WDT_REC_OFF_V8_LS_ETH));
	if (readl(wdt->rec + WDT_REC_OFF_ETH_FLAGS))
		dev_info(dev,
			 "v8: eth[isr=%u last %uj ago, burstmax=%u/j poll=%u last %uj ago, dlv=%u kicktxr=%u last %uj ago, napi=0x%x phbase=0x%08x mbbase=0x%08x]\n",
			 readl(wdt->rec + WDT_REC_OFF_V8_E_ISRCNT),
			 pj - readl(wdt->rec + WDT_REC_OFF_V8_E_ISRJ),
			 readl(wdt->rec + WDT_REC_OFF_V8_E_BURST),
			 readl(wdt->rec + WDT_REC_OFF_V8_E_POLLC),
			 pj - readl(wdt->rec + WDT_REC_OFF_V8_E_POLLJ),
			 readl(wdt->rec + WDT_REC_OFF_V8_E_DLV),
			 readl(wdt->rec + WDT_REC_OFF_V8_E_KICKT),
			 pj - readl(wdt->rec + WDT_REC_OFF_V8_E_KICKJ),
			 readl(wdt->rec + WDT_REC_OFF_V8_E_NAPI),
			 readl(wdt->rec + WDT_REC_OFF_V8_E_PHBASE),
			 readl(wdt->rec + WDT_REC_OFF_V8_E_MBBASE));

	/* Flight-recorder table: one line per sample, oldest first. */
	if (readl(wdt->rec + WDT_FLT_OFF_MAGIC) == WDT_FLT_MAGIC &&
	    readl(wdt->rec + WDT_FLT_OFF_SSIZE) == sizeof(struct rtl819x_wdt_flt_sample)) {
		u32 ns = readl(wdt->rec + WDT_FLT_OFF_NS);
		u32 i;

		if (ns > WDT_FLT_NS_REC)
			ns = WDT_FLT_NS_REC;
		dev_info(dev, "flight| %u samples, period %ums, newest last:\n",
			 ns, readl(wdt->rec + WDT_FLT_OFF_PERIOD));
		for (i = 0; i < ns; i++) {
			struct rtl819x_wdt_flt_sample s;

			memcpy_fromio(&s, wdt->rec + WDT_FLT_OFF_SAMPLES +
				      i * sizeof(s), sizeof(s));
			dev_info(dev,
				 "flight|%3d: iisr=0x%x iimr=0x%x dj=%u hi=%u tc0=%u u0=%u u1=%u eth=%u netrx=%u tsirq=%u eisr=%u poll=%u dlv=%u rxp=%u intc=%u emp=%u napi=0x%x\n",
				 (int)i - (int)ns + 1, s.iisr, s.iimr, s.d_jiffies,
				 s.d_hardirq, s.d_tc0, s.d_uart0, s.d_uart1,
				 s.d_eth_line, s.d_net_rx, s.d_timer_sirq,
				 s.d_eth_isr, s.d_poll, s.d_delivered, s.d_rxpkts,
				 s.d_intc, s.d_intc_empty, s.napi_state);
		}
	}

	/* printk tail: re-emit line by line under a greppable prefix. */
	{
		u32 len = readl(wdt->rec + WDT_TAIL_OFF_LEN);

		if (len && len <= WDT_TAIL_MAX) {
			char *buf = kmalloc(len + 1, GFP_KERNEL);

			if (buf) {
				char *p, *nl;

				memcpy_fromio(buf, wdt->rec + WDT_TAIL_OFF_TXT, len);
				buf[len] = '\0';
				dev_info(dev, "panic-log| --- last %u bytes of the panicking boot's kernel log ---\n",
					 len);
				for (p = buf; *p; p = nl) {
					nl = strchr(p, '\n');
					if (nl)
						*nl++ = '\0';
					else
						nl = p + strlen(p);
					if (*p)
						dev_info(dev, "panic-log| %s\n", p);
				}
				kfree(buf);
			}
		}
	}
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

	if (ver >= WDT_REC_VERSION_V2 && ver <= WDT_REC_VERSION) {
		char v4stat[420];
		char v5stat[480];

		rtl819x_wdt_softirq_decode(sirqmask, sirq, sizeof(sirq));
		rtl819x_wdt_fns_decode(wdt, WDT_REC_OFF_NTFN, WDT_REC_OFF_TFNS,
				       tfns, sizeof(tfns));
		rtl819x_wdt_fns_decode(wdt, WDT_REC_OFF_NHFN, WDT_REC_OFF_HFNS,
				       hfns, sizeof(hfns));
		wstat[0] = '\0';
		if (ver >= WDT_REC_VERSION_V3) {
			u32 lag = readl(wdt->rec + WDT_REC_OFF_LAG);
			u32 npend = readl(wdt->rec + WDT_REC_OFF_NPEND);

			if (lag != WDT_REC_STAT_UNSET)
				scnprintf(wstat, sizeof(wstat),
					  " overdue=%uj pending=%u", lag, npend);
		}
		v4stat[0] = '\0';
		if (ver >= WDT_REC_VERSION_V4) {	/* v4: NET_RX-side counters */
			char sc[160], napi[200];
			size_t p = 0;
			u32 s;

			sc[0] = '\0';
			for (s = 0; s < ARRAY_SIZE(rtl819x_wdt_softirq_names); s++) {
				u32 c = readl(wdt->rec + WDT_REC_OFF_SIRQCNT + s * 4);

				if (!c)
					continue;
				p += scnprintf(sc + p, sizeof(sc) - p, "%s%s:%u",
					       p ? "|" : "",
					       rtl819x_wdt_softirq_names[s], c);
			}
			if (!p)
				scnprintf(sc, sizeof(sc), "none");
			rtl819x_wdt_fns_decode(wdt, WDT_REC_OFF_NNAPI,
					       WDT_REC_OFF_NAPIFNS, napi,
					       sizeof(napi));
			scnprintf(v4stat, sizeof(v4stat),
				  " softirqs=[%s] hardirqs=%u napi=[%s]", sc,
				  readl(wdt->rec + WDT_REC_OFF_HARDIRQ), napi);
		}
		v5stat[0] = '\0';
		if (ver >= WDT_REC_VERSION_V5) {	/* eth recovery snapshot */
			if (readl(wdt->rec + WDT_REC_OFF_ETH_FLAGS)) {
				size_t p = scnprintf(v5stat, sizeof(v5stat),
					  " eth=[up=1 resync=%u kick=%u",
					  readl(wdt->rec + WDT_REC_OFF_ETH_RESYNC),
					  readl(wdt->rec + WDT_REC_OFF_ETH_KICK));
				if (ver <= WDT_REC_VERSION_V6)	/* v5/v6: legacy RUNOUT-latch in-progress counters */
					p += scnprintf(v5stat + p, sizeof(v5stat) - p,
					  " zero=%u seen=%u",
					  readl(wdt->rec + WDT_REC_OFF_ETH_ZERO),
					  readl(wdt->rec + WDT_REC_OFF_ETH_SEEN));
				p += scnprintf(v5stat + p, sizeof(v5stat) - p,
					  " iisr=0x%x iimr=0x%x rxidx=%u",
					  readl(wdt->rec + WDT_REC_OFF_ETH_IISR),
					  readl(wdt->rec + WDT_REC_OFF_ETH_IIMR),
					  readl(wdt->rec + WDT_REC_OFF_ETH_RXIDX));
				if (ver >= WDT_REC_VERSION_V6)	/* v6: switch-core/TX/ring state */
					p += scnprintf(v5stat + p, sizeof(v5stat) - p,
					  " rxdesc=0x%x txprod=%u txcons=%u txfree=%u txdesc=0x%x cpuicr=0x%x sirr=0x%x rxpkts=%u txpkts=%u",
					  readl(wdt->rec + WDT_REC_OFF_ETH_RXDESC),
					  readl(wdt->rec + WDT_REC_OFF_ETH_TXPROD),
					  readl(wdt->rec + WDT_REC_OFF_ETH_TXCONS),
					  readl(wdt->rec + WDT_REC_OFF_ETH_TXFREE),
					  readl(wdt->rec + WDT_REC_OFF_ETH_TXDESC),
					  readl(wdt->rec + WDT_REC_OFF_ETH_CPUICR),
					  readl(wdt->rec + WDT_REC_OFF_ETH_SIRR),
					  readl(wdt->rec + WDT_REC_OFF_ETH_RXPKTS),
					  readl(wdt->rec + WDT_REC_OFF_ETH_TXPKTS));
				if (ver >= WDT_REC_VERSION_V7)	/* v7: bounded-poll detector + A/B + switch desync */
					p += scnprintf(v5stat + p, sizeof(v5stat) - p,
					  " pollhit=%u stallrun=%u deepreset=%u rpdcr0=0x%x rmdcr0=0x%x p6dcr0=0x%x A:wildph=%u wildmb=%u noshadow=%u skew=%u B:badlen=%u",
					  readl(wdt->rec + WDT_REC_OFF_ETH_POLLHIT),
					  readl(wdt->rec + WDT_REC_OFF_ETH_STALLRUN),
					  readl(wdt->rec + WDT_REC_OFF_ETH_DEEPRST),
					  readl(wdt->rec + WDT_REC_OFF_ETH_RPDCR0),
					  readl(wdt->rec + WDT_REC_OFF_ETH_RMDCR0),
					  readl(wdt->rec + WDT_REC_OFF_ETH_P6DCR0),
					  readl(wdt->rec + WDT_REC_OFF_ETH_WILDPH),
					  readl(wdt->rec + WDT_REC_OFF_ETH_WILDMB),
					  readl(wdt->rec + WDT_REC_OFF_ETH_NOSHADOW),
					  readl(wdt->rec + WDT_REC_OFF_ETH_SKEW),
					  readl(wdt->rec + WDT_REC_OFF_ETH_BADLEN));
				scnprintf(v5stat + p, sizeof(v5stat) - p, "]");
			} else {
				scnprintf(v5stat, sizeof(v5stat), " eth=[down]");
			}
		}
		/*
		 * v5stat (the eth recovery snapshot) is placed right after the softirq
		 * mask — ahead of the long timers[]/hrtimers[]/softirqs[] blocks —
		 * so that on a fully-populated record approaching LOG_LINE_MAX
		 * the decisive eth fields survive even if the tail
		 * (reason, then the candidate lists) is truncated.
		 */
		dev_info(dev,
			 "previous boot ended in panic: uptime=%us pc=%pS ra=%pS running=%pS softirq=0x%x[%s]%s timers=[%s] hrtimers=[%s]%s%s reason=\"%s\"\n",
			 up, (void *)(uintptr_t)epc, (void *)(uintptr_t)ra,
			 (void *)(uintptr_t)fna, sirqmask, sirq, v5stat, tfns, hfns,
			 wstat, v4stat, reason);
		if (ver >= WDT_REC_VERSION)
			rtl819x_wdt_report_v8(wdt);
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
	/*
	 * No .get_timeleft: the hardware has no readable countdown, and
	 * the v1.5 op returned the constant `timeout`, which is not a
	 * time-left. Absent the op the core answers WDIOC_GETTIMELEFT
	 * with EOPNOTSUPP — honest. BusyBox `watchdog` never calls it.
	 */
	.restart	= rtl819x_wdt_restart,
};

/*
 * Debug aid kept behind dev_dbg: dump sysc[0x3100..0x3120] at probe so
 * we can correlate cold-boot vs watchdog-fired vs software-reboot
 * register values across runs and refine the reset-cause decoder if
 * a future SoC rev populates WDIND reliably. Not emitted
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
	u32 raw;
	int ret;

	wdt = devm_kzalloc(dev, sizeof(*wdt), GFP_KERNEL);
	if (!wdt)
		return -ENOMEM;

	wdt->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(wdt->base))
		return PTR_ERR(wdt->base);

	wdt->wdd.info			= &rtl819x_wdt_info;
	wdt->wdd.ops			= &rtl819x_wdt_ops;
	wdt->wdd.parent			= dev;
	wdt->wdd.min_timeout		= WDT_TIMEOUT_SECS_MIN;
	wdt->wdd.max_hw_heartbeat_ms	= WDT_HW_WINDOW_MS;
	wdt->wdd.timeout		= WDT_TIMEOUT_SECS_DEFAULT;

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
	 * future bringup data refine the reset-cause decoder.
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
	if (rmem && rmem->size >= WDT_MAP_SIZE) {
		/*
		 * v8 maps the whole 4 KB page (record + flight recorder +
		 * printk tail). Writes stay below WDT_PAGE_GUARD — the page
		 * top belongs to boothold (enforced by the static_asserts at
		 * the layout block).
		 */
		wdt->rec = devm_ioremap(dev, rmem->base, WDT_MAP_SIZE);
		if (!wdt->rec)
			dev_warn(dev, "panic record region map failed; post-mortem disabled\n");
	} else {
		dev_warn(dev, "no usable memory-region reservation; post-mortem disabled\n");
	}
	rtl819x_wdt_report_panic_record(wdt);

	/*
	 * Start the v8 flight recorder. HRTIMER_MODE_REL_HARD: fires from the
	 * timer hardirq — the context the softlockup detector demonstrably
	 * kept running from during the captured field hang. Started
	 * unconditionally (the sampler is a few dozen word ops per second);
	 * without a mapped record page its history simply never gets dumped.
	 */
	hrtimer_setup(&rtl819x_wdt_flt_timer, rtl819x_wdt_flt_fn,
		      CLOCK_MONOTONIC, HRTIMER_MODE_REL_HARD);
	hrtimer_start(&rtl819x_wdt_flt_timer, ms_to_ktime(WDT_FLT_PERIOD_MS),
		      HRTIMER_MODE_REL_HARD);

	rtl819x_wdt_dump_bringup(wdt);

	ret = devm_watchdog_register_device(dev, &wdt->wdd);
	if (ret) {
		dev_err(dev, "watchdog_register_device failed: %d\n", ret);
		return ret;
	}

	/*
	 * Soft-lockup -> panic -> HW reset path. See the
	 * rtl819x_wdt_panic_notify() comment block for the full rationale.
	 * Priority pinned to INT_MAX so we run at the head of the panic
	 * notifier chain — see the audit notes.
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

	dev_info(dev, "v" DRV_VERSION " (J. Nilo) - record v%u, timeout:%us, nowayout:%d\n",
		 WDT_REC_VERSION, wdt->wdd.timeout, nowayout);

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
