/* SPDX-License-Identifier: GPL-2.0 */
/*
 * rtl819x_intc_stats.h - live dispatch statistics of the RTL819x INTC.
 *
 * Cross-subsystem contract between the rtl819x irqchip (producer) and the
 * rtl819x watchdog (consumer: 1 Hz flight recorder + panic record v8).
 *
 * Motivation (issue #99): the field soft-lockup is interrupt-storm-shaped,
 * but the storming line is unidentified. Two blind spots in the stock
 * accounting drove this header:
 *   - a chained-handler invocation that finds mask&status == 0 dispatches
 *     nothing and increments NO existing counter — an INTC-level storm
 *     (parent IP re-asserting with empty pending) is invisible;
 *   - kstat per-IRQ counts give volume but not recency; per-line last-seen
 *     jiffies answer "who was active during the final 20 s" in a single
 *     subtraction against the jiffies captured at panic.
 *
 * Producer cost: two u32 stores per chained-handler entry plus two per
 * dispatched bit, all to one cacheline-sized BSS struct — negligible next to
 * the MMIO reads the handler already performs.
 *
 * UP platform, written only from the (sole) CPU's hardirq context, read from
 * panic/hrtimer context — plain u32 loads are torn-free on MIPS32.
 */
#ifndef _LINUX_RTL819X_INTC_STATS_H
#define _LINUX_RTL819X_INTC_STATS_H

#include <linux/types.h>

#define RTL819X_INTC_NR_LINES	32	/* GIMR/GISR are one 32-bit register */

struct rtl819x_intc_stats {
	u32 entries;			/* chained-handler invocations */
	u32 empty;			/* invocations with mask&status == 0 */
	u32 count[RTL819X_INTC_NR_LINES];	/* dispatches per GISR bit */
	u32 last_seen_j[RTL819X_INTC_NR_LINES];	/* jiffies at last dispatch */
};

/*
 * Strong definition lives in drivers/irqchip/irq-rtl819x.c, which is
 * unconditionally built in on this platform (it is the system INTC).
 */
extern struct rtl819x_intc_stats rtl819x_intc_stats;

#endif /* _LINUX_RTL819X_INTC_STATS_H */
