/*
 * Realtek RTL819x Timer/Clocksource Driver
 *
 * This driver provides clocksource and clockevent support for Realtek RTL819x
 * SoCs (RTL8196E, RTL8197D, etc.). The hardware provides two 28-bit timers:
 *
 * - Timer1: Free-running counter for clocksource (monotonic time)
 * - Timer0: One-shot timer for clockevent (scheduling kernel ticks)
 *
 * Key features:
 * - 28-bit hardware counters with configurable clock divider
 * - Proper memory barriers (writel/readl) for safe MMIO access
 * - timer_of framework for base/clock/irq init (v1.2 conversion)
 *
 * Copyright (C) 2019 Gaspare Bruno <gaspare@anlix.io>
 * Copyright (C) 2025 Jacques Nilo (security improvements)
 *
 * This file is subject to the terms and conditions of the GNU General Public
 * License. See the file "COPYING" in the main directory of this archive
 * for more details.
 */

#include <linux/interrupt.h>
#include <linux/init.h>
#include <linux/of.h>
#include <linux/clockchips.h>
#include <linux/clocksource.h>
#include <linux/sched_clock.h>
#include <linux/clk.h>

#include "timer-of.h"

#define DRV_VERSION "1.2"

/* ========================================================================== */
/* Hardware Definitions */
/* ========================================================================== */

/* Timer Controller Registers */
#define REALTEK_TC_REG_DATA0		0x00	/* Timer0 data register */
#define REALTEK_TC_REG_DATA1		0x04	/* Timer1 data register */
#define REALTEK_TC_REG_COUNT0		0x08	/* Timer0 current count */
#define REALTEK_TC_REG_COUNT1		0x0c	/* Timer1 current count */
#define REALTEK_TC_REG_CTRL		0x10	/* Main control register */
#define REALTEK_TC_CTRL_TC0_EN		BIT(31)	/* Timer0 enable */
#define REALTEK_TC_CTRL_TC0_MODE	BIT(30)	/* Timer0 mode (0=Timer, 1=Counter) */
#define REALTEK_TC_CTRL_TC1_EN		BIT(29)	/* Timer1 enable */
#define REALTEK_TC_CTRL_TC1_MODE	BIT(28) /* Timer1 mode (0=Timer, 1=Counter) */
#define REALTEK_TC_REG_IR		0x14	/* Interrupt control register */
#define REALTEK_TC_IR_TC0_EN		BIT(31) /* Timer0 interrupt enable */
#define REALTEK_TC_IR_TC1_EN		BIT(30) /* Timer1 interrupt enable */
#define REALTEK_TC_IR_TC0_PENDING	BIT(29) /* Timer0 interrupt pending */
#define REALTEK_TC_IR_TC1_PENDING	BIT(28) /* Timer1 interrupt pending */
#define REALTEK_TC_REG_CLOCK_DIV	0x18	/* Clock divider register */

/* Hardware counter resolution and adjustment */
#define REALTEK_TIMER_RESOLUTION	28
#define RTLADJ_TICK(x)			((x) >> (32 - REALTEK_TIMER_RESOLUTION))

static int rtl819x_set_state_shutdown(struct clock_event_device *cd);
static int rtl819x_set_state_oneshot(struct clock_event_device *cd);
static int rtl819x_timer_set_next_event(unsigned long delta,
					struct clock_event_device *evt);
static irqreturn_t rtl819x_timer_interrupt(int irq, void *dev_id);

/*
 * Single timer instance (this is the platform's only system timer).
 * timer_of owns the register mapping, the refclk and the IRQ; the
 * clocksource read and sched_clock paths reach the base through it.
 */
static struct timer_of to = {
	.flags = TIMER_OF_BASE | TIMER_OF_CLOCK | TIMER_OF_IRQ,
	/*
	 * No .of_base.name on purpose: that selects plain of_iomap(), no
	 * region claim — the watchdog@311c neighbour owns its own window
	 * (audit TMR-009; the timer node's reg was shrunk to 0x1c so a
	 * future claiming accessor stays safe too).
	 */
	.of_clk = {
		.name = "refclk",
	},
	.of_irq = {
		.handler = rtl819x_timer_interrupt,
		.flags = IRQF_TIMER,
	},
	.clkevt = {
		.name			= "rtl819x-timer",
		.rating			= 100,
		.features		= CLOCK_EVT_FEAT_ONESHOT,
		.set_next_event		= rtl819x_timer_set_next_event,
		.set_state_oneshot	= rtl819x_set_state_oneshot,
		.set_state_shutdown	= rtl819x_set_state_shutdown,
	},
};

/*
 * Helper macros for timer register access with memory barriers
 * Use writel/readl (not __raw_*) for proper MMIO ordering
 */
#define tc_w32(val, reg) writel(val, timer_of_base(&to) + reg)
#define tc_r32(reg)      readl(timer_of_base(&to) + reg)

/* ========================================================================== */
/* Clocksource Implementation (Timer1) */
/* ========================================================================== */

/**
 * rtl819x_tc1_count_read - Read free-running Timer1 counter
 * @cs: Clocksource structure
 *
 * Returns current 28-bit counter value, adjusted for proper scaling.
 */
static u64 rtl819x_tc1_count_read(struct clocksource *cs)
{
	return RTLADJ_TICK(tc_r32(REALTEK_TC_REG_COUNT1));
}

/**
 * rtl819x_read_sched_clock - Fast scheduler clock source
 *
 * Provides high-resolution time for scheduler. Must be fast and notrace.
 */
static u64 notrace rtl819x_read_sched_clock(void)
{
	return RTLADJ_TICK(tc_r32(REALTEK_TC_REG_COUNT1));
}

/* Clocksource definition */
static struct clocksource rtl819x_clocksource = {
	.name	= "RTL819X counter",
	.read	= rtl819x_tc1_count_read,
	.flags	= CLOCK_SOURCE_IS_CONTINUOUS,
};

/**
 * rtl819x_clocksource_init - Initialize and register clocksource
 * @freq: Timer frequency in Hz
 *
 * Configures Timer1 as free-running counter and registers with kernel
 * timekeeping, then registers the scheduler clock.
 *
 * Return: 0 on success, negative error from clocksource_register_hz().
 */
static int __init rtl819x_clocksource_init(unsigned long freq)
{
	u32 val;
	int ret;

	/* Configure Timer1 as free-running counter */
	tc_w32(0xfffffff0, REALTEK_TC_REG_DATA1);
	val = tc_r32(REALTEK_TC_REG_CTRL);
	val |= REALTEK_TC_CTRL_TC1_EN | REALTEK_TC_CTRL_TC1_MODE;
	tc_w32(val, REALTEK_TC_REG_CTRL);

	/* Clear and disable Timer1 interrupts (not used) */
	val = tc_r32(REALTEK_TC_REG_IR);
	val |= REALTEK_TC_IR_TC1_PENDING;
	val &= ~REALTEK_TC_IR_TC1_EN;
	tc_w32(val, REALTEK_TC_REG_IR);

	/* Register clocksource with kernel */
	rtl819x_clocksource.rating = 200;
	rtl819x_clocksource.mask = CLOCKSOURCE_MASK(REALTEK_TIMER_RESOLUTION);

	ret = clocksource_register_hz(&rtl819x_clocksource, freq);
	if (ret)
		return ret;

	/* Register scheduler clock (CPU clock is fixed on this platform) */
	sched_clock_register(rtl819x_read_sched_clock, REALTEK_TIMER_RESOLUTION, freq);
	return 0;
}

/* ========================================================================== */
/* Clock Event Device Implementation (Timer0) */
/* ========================================================================== */

/**
 * rtl819x_set_state_shutdown - Disable Timer0 and interrupts
 * @cd: Clock event device
 *
 * Shuts down timer to save power when idle.
 */
static int rtl819x_set_state_shutdown(struct clock_event_device *cd)
{
	u32 val;

	val = tc_r32(REALTEK_TC_REG_CTRL);
	val &= ~(REALTEK_TC_CTRL_TC0_EN);
	tc_w32(val, REALTEK_TC_REG_CTRL);

	val = tc_r32(REALTEK_TC_REG_IR);
	val &= ~REALTEK_TC_IR_TC0_EN;
	tc_w32(val, REALTEK_TC_REG_IR);
	return 0;
}

/**
 * rtl819x_set_state_oneshot - Configure Timer0 for one-shot mode
 * @cd: Clock event device
 *
 * Prepares timer for single interrupt after specified delta.
 */
static int rtl819x_set_state_oneshot(struct clock_event_device *cd)
{
	u32 val;

	val = tc_r32(REALTEK_TC_REG_CTRL);
	val &= ~(REALTEK_TC_CTRL_TC0_EN | REALTEK_TC_CTRL_TC0_MODE);
	tc_w32(val, REALTEK_TC_REG_CTRL);

	val = tc_r32(REALTEK_TC_REG_IR);
	val |= REALTEK_TC_IR_TC0_EN | REALTEK_TC_IR_TC0_PENDING;
	tc_w32(val, REALTEK_TC_REG_IR);
	return 0;
}

/**
 * rtl819x_timer_set_next_event - Program next timer interrupt
 * @delta: Ticks until next event
 * @evt: Clock event device
 *
 * Loads delta and starts Timer0 to fire interrupt at specified time.
 */
static int rtl819x_timer_set_next_event(unsigned long delta, struct clock_event_device *evt)
{
	u32 val;

	val = tc_r32(REALTEK_TC_REG_CTRL);
	val &= ~REALTEK_TC_CTRL_TC0_EN;
	tc_w32(val, REALTEK_TC_REG_CTRL);

	tc_w32(delta << (32 - REALTEK_TIMER_RESOLUTION), REALTEK_TC_REG_DATA0);

	val |= REALTEK_TC_CTRL_TC0_EN;
	tc_w32(val, REALTEK_TC_REG_CTRL);

	return 0;
}

/**
 * rtl819x_timer_interrupt - Timer0 interrupt handler
 * @irq: Interrupt number
 * @dev_id: Pointer to clock event device
 *
 * Acknowledges interrupt and calls event handler to advance kernel time.
 *
 * Robust against the timer_of init window: request_irq() runs inside
 * timer_of_init(), before Timer0 is quiesced and before clockevents
 * installs event_handler. A stale pending bit (bootloader / soft-reset
 * state) therefore fires here at most once at unmask time: the W1C ack
 * clears it and the NULL event_handler check skips the dispatch.
 */
static irqreturn_t rtl819x_timer_interrupt(int irq, void *dev_id)
{
	struct clock_event_device *cd = dev_id;
	u32 tc0_irs;

	tc0_irs = tc_r32(REALTEK_TC_REG_IR);
	if (!(tc0_irs & REALTEK_TC_IR_TC0_PENDING))
		return IRQ_NONE;

	/* Acknowledge Timer0 interrupt (W1C) */
	tc_w32(tc0_irs | REALTEK_TC_IR_TC0_PENDING, REALTEK_TC_REG_IR);

	/* Call event handler if valid */
	if (likely(cd && cd->event_handler))
		cd->event_handler(cd);

	return IRQ_HANDLED;
}

/* ========================================================================== */
/* Driver Initialization */
/* ========================================================================== */

/**
 * rtl819x_timer_init - Initialize timer driver from device tree
 * @np: Device tree node
 *
 * timer_of_init() maps the registers, enables the refclk and requests
 * the IRQ; this function then programs the divider from the busclk,
 * brings up the clocksource (Timer1), quiesces Timer0 and registers the
 * clockevent. Every failure panics: this is the platform's only timer
 * (audit TMR-006).
 *
 * Ordering note vs the pre-timer_of driver: request_irq() now happens
 * *before* the Timer0 quiesce (it is part of timer_of_init), relaxing
 * the v3.4.0 TMR-002 ordering. That is safe because the IRQ handler is
 * self-contained against the window — see its kernel-doc.
 *
 * Return: 0 on success (any failure panics)
 */
static int __init rtl819x_timer_init(struct device_node *np)
{
	unsigned long timer_rate;
	u32 div_fac;
	int ret;

	ret = timer_of_init(np, &to);
	if (ret)
		panic("Failed to init timer_of for %pOF: %d", np, ret);

	to.clkevt.cpumask = cpumask_of(0);
	timer_rate = timer_of_rate(&to);

	{
		struct clk *busclk;
		u32 bus_rate = 200000000;  /* fallback for DTs without busclk */

		busclk = of_clk_get_by_name(np, "busclk");
		if (!IS_ERR(busclk)) {
			if (clk_prepare_enable(busclk) == 0) {
				bus_rate = clk_get_rate(busclk);
				if (!bus_rate)
					bus_rate = 200000000;
			}
			/* Reference held forever (audit TMR-007). */
		}
		if (timer_rate > bus_rate)
			panic("Invalid timer divider input: bus_rate=%u < timer_rate=%lu\n",
			      bus_rate, timer_rate);
		div_fac = bus_rate / timer_rate;
		if (!div_fac || div_fac > 0xffff)
			panic("Invalid timer divider: %u (bus_rate=%u, timer_rate=%lu)\n",
			      div_fac, bus_rate, timer_rate);
	}
	tc_w32(div_fac << 16, REALTEK_TC_REG_CLOCK_DIV);

	/* Initialize clocksource (Timer1) */
	ret = rtl819x_clocksource_init(timer_rate);
	if (ret)
		panic("Failed to register timer clocksource: %d\n", ret);

	/*
	 * Quiesce Timer0 before exposing the clockevent to the core: clear
	 * any stale pending bit (bootloader / soft-reset state) and disable
	 * both the timer and its interrupt source.
	 */
	{
		u32 ctrl, ir;

		ctrl = tc_r32(REALTEK_TC_REG_CTRL);
		ctrl &= ~REALTEK_TC_CTRL_TC0_EN;
		tc_w32(ctrl, REALTEK_TC_REG_CTRL);

		ir = tc_r32(REALTEK_TC_REG_IR);
		ir &= ~REALTEK_TC_IR_TC0_EN;
		ir |= REALTEK_TC_IR_TC0_PENDING;	/* W1C */
		tc_w32(ir, REALTEK_TC_REG_IR);
	}

	/*
	 * min_delta is expressed in clock ticks at `timer_rate` Hz. We use 8
	 * ticks because the slowclk rework (closing WDT-005) drops timer_rate
	 * from 25 MHz to 25 kHz: 8 ticks ≈ 320 µs, comfortably below the
	 * HZ=250 periodic tick (4 ms) but well above the read/write/arm
	 * latency on this 200 MHz Lexra MIPS. The previous 0x300 = 768 ticks
	 * was fine at 25 MHz (~31 µs) but would force a 30 ms minimum at
	 * 25 kHz — incompatible with HZ=250 scheduling.
	 */
	clockevents_config_and_register(&to.clkevt, timer_rate, 8,
					(1 << REALTEK_TIMER_RESOLUTION) - 1);

	pr_info("timer-rtl819x v" DRV_VERSION " (J. Nilo) - IRQ:%d, CLK:%lu Hz, mult:%d, shift:%d\n",
		timer_of_irq(&to), timer_rate,
		to.clkevt.mult, to.clkevt.shift);

	return 0;
}

/* ========================================================================== */
/* Driver Registration */
/* ========================================================================== */

/* Register with kernel timer framework */
TIMER_OF_DECLARE(rtl819x_timer, "realtek,rtl819x-timer", rtl819x_timer_init);
