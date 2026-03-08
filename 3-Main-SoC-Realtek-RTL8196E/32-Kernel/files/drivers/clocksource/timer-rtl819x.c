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
 * - Comprehensive error checking and validation
 * - Modern kernel APIs (request_irq, ioremap)
 *
 * Copyright (C) 2019 Gaspare Bruno <gaspare@anlix.io>
 * Copyright (C) 2025 Jacques Nilo (security improvements)
 *
 * This file is subject to the terms and conditions of the GNU General Public
 * License. See the file "COPYING" in the main directory of this archive
 * for more details.
 */

#include <linux/interrupt.h>
#include <linux/reset.h>
#include <linux/init.h>
#include <linux/time.h>
#include <linux/of.h>
#include <linux/of_irq.h>
#include <linux/of_address.h>
#include <linux/clockchips.h>
#include <linux/clocksource.h>
#include <linux/clk-provider.h>
#include <linux/sched_clock.h>
#include <linux/clk.h>

/* ========================================================================== */
/* Hardware Definitions */
/* ========================================================================== */

/* Global pointer to timer register base */
static void __iomem *rtl819x_timer_base;

/*
 * Helper macros for timer register access with memory barriers
 * Use writel/readl (not __raw_*) for proper MMIO ordering
 */
#define tc_w32(val, reg) writel(val, rtl819x_timer_base + reg)
#define tc_r32(reg)      readl(rtl819x_timer_base + reg)

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
static u64 __maybe_unused notrace rtl819x_read_sched_clock(void)
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
 * timekeeping. Also registers scheduler clock if CPU frequency scaling
 * is disabled.
 */
void __init rtl819x_clocksource_init(unsigned long freq)
{
	u32 val;

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

	clocksource_register_hz(&rtl819x_clocksource, freq);

#ifndef CONFIG_CPU_FREQ
	/* Register scheduler clock (if CPU freq is fixed) */
	sched_clock_register(rtl819x_read_sched_clock, REALTEK_TIMER_RESOLUTION, freq);
#endif
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
 */
static irqreturn_t rtl819x_timer_interrupt(int irq, void *dev_id)
{
	struct clock_event_device *cd = dev_id;
	u32 tc0_irs;

	/* Acknowledge Timer0 interrupt */
	tc0_irs = tc_r32(REALTEK_TC_REG_IR);
	tc0_irs |= REALTEK_TC_IR_TC0_PENDING;
	tc_w32(tc0_irs, REALTEK_TC_REG_IR);

	/* Call event handler if valid */
	if (likely(cd && cd->event_handler))
		cd->event_handler(cd);

	return IRQ_HANDLED;
}

/* Clock event device definition */
static struct clock_event_device rtl819x_clockevent = {
	.rating			= 100,
	.features		= CLOCK_EVT_FEAT_ONESHOT,
	.set_next_event		= rtl819x_timer_set_next_event,
	.set_state_oneshot	= rtl819x_set_state_oneshot,
	.set_state_shutdown	= rtl819x_set_state_shutdown,
};

/* ========================================================================== */
/* Driver Initialization */
/* ========================================================================== */

/**
 * rtl819x_timer_init - Initialize timer driver from device tree
 * @np: Device tree node
 *
 * Main initialization function:
 * - Maps hardware registers (using modern ioremap)
 * - Validates clock rate (prevents division by zero)
 * - Configures clock divider
 * - Initializes clocksource (Timer1)
 * - Registers clock event device (Timer0)
 * - Sets up interrupt handler (using modern request_irq)
 *
 * Return: 0 on success, negative error code on failure
 */
static int __init rtl819x_timer_init(struct device_node *np)
{
	struct resource res;
	struct clk *clk;
	unsigned long timer_rate;
	u32 div_fac;
	int ret;

	if (of_address_to_resource(np, 0, &res))
		panic("Failed to get resource for %s", np->name);

	/* Use ioremap (not deprecated ioremap_nocache) */
	rtl819x_timer_base = ioremap(res.start, resource_size(&res));
	if (!rtl819x_timer_base)
		panic("Failed to map memory for %s", np->name);

	rtl819x_clockevent.name = np->name;
	rtl819x_clockevent.irq = irq_of_parse_and_map(np, 0);
	if (!rtl819x_clockevent.irq) {
		pr_err("%s: Failed to map interrupt\n", np->name);
		goto err_iounmap;
	}
	rtl819x_clockevent.cpumask = cpumask_of(0);

	/* Get and validate clock */
	clk = of_clk_get(np, 0);
	if (IS_ERR_OR_NULL(clk))
		panic("Cannot find reference clock for timer!\n");
	ret = clk_prepare_enable(clk);
	if (ret)
		panic("Cannot enable reference clock for timer!\n");
	timer_rate = clk_get_rate(clk);
	if (unlikely(timer_rate == 0))
		panic("Invalid timer rate!\n");
	/* Clock stays enabled (timer runs forever), but release the reference */
	clk_put(clk);

	{
		struct clk *busclk;
		u32 bus_rate = 200000000;  /* fallback for DTs without busclk */

		busclk = of_clk_get_by_name(np, "busclk");
		if (!IS_ERR(busclk)) {
			clk_prepare_enable(busclk);
			bus_rate = clk_get_rate(busclk);
			if (!bus_rate)
				bus_rate = 200000000;
			clk_put(busclk);
		}
		div_fac = bus_rate / timer_rate;
	}
	tc_w32(div_fac << 16, REALTEK_TC_REG_CLOCK_DIV);

	/* Initialize clocksource and clockevent */
	rtl819x_clocksource_init(timer_rate);
	clockevents_config_and_register(&rtl819x_clockevent, timer_rate, 0x300,
					(1 << REALTEK_TIMER_RESOLUTION) - 1);

	/* Register interrupt handler (using modern request_irq API) */
	ret = request_irq(rtl819x_clockevent.irq, rtl819x_timer_interrupt,
			  IRQF_TIMER, np->name, &rtl819x_clockevent);
	if (ret) {
		pr_err("%s: Failed to request IRQ %d: %d\n",
		       np->name, rtl819x_clockevent.irq, ret);
		panic("Failed to setup timer interrupt!\n");
	}

	pr_info("%s: running - mult: %d, shift: %d, IRQ: %d, CLK: %lu.%03luMHz\n",
		np->name, rtl819x_clockevent.mult, rtl819x_clockevent.shift,
		rtl819x_clockevent.irq, timer_rate / 1000000, (timer_rate / 1000) % 1000);

	return 0;

err_iounmap:
	iounmap(rtl819x_timer_base);
	return -EINVAL;
}

/* ========================================================================== */
/* Driver Registration */
/* ========================================================================== */

/* Register with kernel timer framework */
TIMER_OF_DECLARE(rtl819x_timer, "realtek,rtl819x-timer", rtl819x_timer_init);
