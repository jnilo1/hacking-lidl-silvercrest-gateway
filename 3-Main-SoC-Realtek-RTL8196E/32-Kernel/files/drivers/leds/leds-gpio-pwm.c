// SPDX-License-Identifier: GPL-2.0-only
/*
 * GPIO LED driver with software PWM brightness control
 *
 * Drop-in replacement for leds-gpio that adds true brightness control
 * (0-255) via high-frequency software PWM using hrtimers.  When
 * brightness == max the GPIO is held steady (no PWM overhead).
 *
 * Designed for SoCs without hardware PWM (e.g. Realtek RTL8196E).
 * CPU cost: ~0.03 % per LED at 1 kHz on a 400 MHz MIPS core.
 *
 * DTS compatible: "gpio-leds-pwm"  (same child-node syntax as gpio-leds)
 *
 * Copyright (C) 2025 Jacques Nilo
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/gpio/consumer.h>
#include <linux/leds.h>
#include <linux/of.h>
#include <linux/hrtimer.h>
#include <linux/slab.h>

#define PWM_PERIOD_NS	(1000000)	/* 1 ms  = 1 kHz */
#define MAX_BRIGHTNESS	255

struct gpio_pwm_led {
	struct led_classdev	cdev;
	struct gpio_desc	*gpiod;
	struct hrtimer		timer;
	unsigned int		brightness;	/* current target 0-255    */
	bool			phase;		/* 0 = ON phase, 1 = OFF   */
	bool			pwm_active;	/* hrtimer currently runs   */
	spinlock_t		lock;
};

/* ----- hrtimer callback ------------------------------------------------- */

static enum hrtimer_restart gpio_pwm_timer_fn(struct hrtimer *hr)
{
	struct gpio_pwm_led *led = container_of(hr, struct gpio_pwm_led, timer);
	unsigned int bright;
	unsigned long flags;
	ktime_t on_ns, off_ns;

	spin_lock_irqsave(&led->lock, flags);
	bright = led->brightness;
	spin_unlock_irqrestore(&led->lock, flags);

	/* Should not happen, but guard anyway */
	if (bright == 0 || bright >= MAX_BRIGHTNESS)
		return HRTIMER_NORESTART;

	if (!led->phase) {
		/* End of ON phase -> turn OFF, schedule OFF duration */
		gpiod_set_value(led->gpiod, 0);
		led->phase = true;
		off_ns = (u64)PWM_PERIOD_NS * (MAX_BRIGHTNESS - bright)
			 / MAX_BRIGHTNESS;
		hrtimer_forward_now(hr, ns_to_ktime(off_ns));
	} else {
		/* End of OFF phase -> turn ON, schedule ON duration */
		gpiod_set_value(led->gpiod, 1);
		led->phase = false;
		on_ns = (u64)PWM_PERIOD_NS * bright / MAX_BRIGHTNESS;
		hrtimer_forward_now(hr, ns_to_ktime(on_ns));
	}

	return HRTIMER_RESTART;
}

/* ----- brightness_set --------------------------------------------------- */

static void gpio_pwm_brightness_set(struct led_classdev *cdev,
				     enum led_brightness value)
{
	struct gpio_pwm_led *led = container_of(cdev, struct gpio_pwm_led, cdev);
	unsigned long flags;

	spin_lock_irqsave(&led->lock, flags);
	led->brightness = value;
	spin_unlock_irqrestore(&led->lock, flags);

	if (value == 0) {
		/* Full OFF -- stop PWM, force GPIO low */
		if (led->pwm_active) {
			hrtimer_cancel(&led->timer);
			led->pwm_active = false;
		}
		gpiod_set_value(led->gpiod, 0);
	} else if (value >= MAX_BRIGHTNESS) {
		/* Full ON -- stop PWM, force GPIO high */
		if (led->pwm_active) {
			hrtimer_cancel(&led->timer);
			led->pwm_active = false;
		}
		gpiod_set_value(led->gpiod, 1);
	} else {
		/* Intermediate -- start PWM if not already running */
		if (!led->pwm_active) {
			led->phase = false;
			gpiod_set_value(led->gpiod, 1);
			led->pwm_active = true;
			hrtimer_start(&led->timer,
				      ns_to_ktime((u64)PWM_PERIOD_NS * value
						  / MAX_BRIGHTNESS),
				      HRTIMER_MODE_REL);
		}
		/*
		 * If already running the new duty cycle is picked up on the
		 * next timer callback via led->brightness -- no restart needed.
		 */
	}
}

/* ----- DT parsing & probe ----------------------------------------------- */

static int gpio_pwm_led_probe_child(struct device *dev,
				     struct device_node *np,
				     struct gpio_pwm_led *led)
{
	struct led_init_data init_data = {};
	const char *state;
	const char *trigger;
	int ret;

	led->gpiod = devm_fwnode_gpiod_get(dev, of_fwnode_handle(np),
					    NULL, GPIOD_OUT_LOW, NULL);
	if (IS_ERR(led->gpiod))
		return PTR_ERR(led->gpiod);

	spin_lock_init(&led->lock);

	hrtimer_init(&led->timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	led->timer.function = gpio_pwm_timer_fn;

	led->cdev.max_brightness = MAX_BRIGHTNESS;
	led->cdev.brightness_set = gpio_pwm_brightness_set;

	init_data.fwnode = of_fwnode_handle(np);

	/* Default state */
	if (!of_property_read_string(np, "default-state", &state)) {
		if (!strcmp(state, "on"))
			led->cdev.brightness = led->cdev.max_brightness;
		else if (!strcmp(state, "keep"))
			led->cdev.brightness = gpiod_get_value(led->gpiod)
					       ? MAX_BRIGHTNESS : 0;
		/* else "off" -> 0 (default) */
	}

	/* Default trigger */
	if (!of_property_read_string(np, "linux,default-trigger", &trigger))
		led->cdev.default_trigger = trigger;

	ret = devm_led_classdev_register_ext(dev, &led->cdev, &init_data);
	if (ret)
		return ret;

	/* Apply initial brightness (may start PWM if intermediate) */
	gpio_pwm_brightness_set(&led->cdev, led->cdev.brightness);

	return 0;
}

static int gpio_pwm_leds_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np, *child;
	struct gpio_pwm_led *leds;
	int count, i, ret;

	np = dev_of_node(dev);
	if (!np)
		return -ENODEV;

	count = of_get_available_child_count(np);
	if (count == 0)
		return -ENODEV;

	leds = devm_kcalloc(dev, count, sizeof(*leds), GFP_KERNEL);
	if (!leds)
		return -ENOMEM;

	i = 0;
	for_each_available_child_of_node(np, child) {
		ret = gpio_pwm_led_probe_child(dev, child, &leds[i]);
		if (ret) {
			dev_err(dev, "failed to register LED %pOFn: %d\n",
				child, ret);
			of_node_put(child);
			return ret;
		}
		i++;
	}

	platform_set_drvdata(pdev, leds);

	return 0;
}

static const struct of_device_id gpio_pwm_leds_of_match[] = {
	{ .compatible = "gpio-leds-pwm" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, gpio_pwm_leds_of_match);

static struct platform_driver gpio_pwm_leds_driver = {
	.probe	= gpio_pwm_leds_probe,
	.driver	= {
		.name		= "leds-gpio-pwm",
		.of_match_table	= gpio_pwm_leds_of_match,
	},
};

module_platform_driver(gpio_pwm_leds_driver);

MODULE_AUTHOR("Jacques Nilo");
MODULE_DESCRIPTION("GPIO LED driver with software PWM brightness control");
MODULE_LICENSE("GPL");
