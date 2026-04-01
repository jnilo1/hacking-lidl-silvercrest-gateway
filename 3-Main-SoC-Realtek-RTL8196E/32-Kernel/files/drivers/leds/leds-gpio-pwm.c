// SPDX-License-Identifier: GPL-2.0-only
/*
 * GPIO LED driver with software PWM brightness control
 *
 * Drop-in replacement for leds-gpio that adds brightness control (0-255)
 * via low-frequency software PWM using kernel timer_list (jiffies-based).
 * At brightness 0 or max the timer is stopped (zero CPU overhead).
 *
 * Uses HZ-based timers (250 Hz on RTL8196E) instead of hrtimers to avoid
 * hard-IRQ interference with UART transfers.
 *
 * PWM period = PWM_PERIOD_JIFFIES jiffies. With HZ=250 and period=4:
 *   PWM frequency = 62.5 Hz (above flicker threshold).
 *   Brightness 60/255 ≈ 1/4 duty cycle (25%).
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
#include <linux/timer.h>
#include <linux/slab.h>

#define PWM_PERIOD_JIFFIES	4	/* 4 jiffies = 16ms @ HZ=250 → 62.5 Hz */
#define MAX_BRIGHTNESS		255

struct gpio_pwm_led {
	struct led_classdev	cdev;
	struct gpio_desc	*gpiod;
	struct timer_list	timer;
	unsigned int		brightness;	/* current target 0-255    */
	unsigned int		counter;	/* position in PWM cycle   */
	bool			pwm_active;	/* timer currently runs    */
	spinlock_t		lock;
};

/* ----- timer callback --------------------------------------------------- */

static void gpio_pwm_timer_fn(struct timer_list *t)
{
	struct gpio_pwm_led *led = from_timer(led, t, timer);
	unsigned int bright, threshold;
	unsigned long flags;

	spin_lock_irqsave(&led->lock, flags);
	bright = led->brightness;
	spin_unlock_irqrestore(&led->lock, flags);

	/* Should not happen, but guard anyway */
	if (bright == 0 || bright >= MAX_BRIGHTNESS) {
		led->pwm_active = false;
		return;
	}

	/* threshold = number of jiffies ON per period */
	threshold = (bright * PWM_PERIOD_JIFFIES + MAX_BRIGHTNESS / 2) / MAX_BRIGHTNESS;
	if (threshold == 0)
		threshold = 1;

	gpiod_set_value(led->gpiod, led->counter < threshold ? 1 : 0);

	led->counter++;
	if (led->counter >= PWM_PERIOD_JIFFIES)
		led->counter = 0;

	mod_timer(&led->timer, jiffies + 1);
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
			del_timer_sync(&led->timer);
			led->pwm_active = false;
		}
		gpiod_set_value(led->gpiod, 0);
	} else if (value >= MAX_BRIGHTNESS) {
		/* Full ON -- stop PWM, force GPIO high */
		if (led->pwm_active) {
			del_timer_sync(&led->timer);
			led->pwm_active = false;
		}
		gpiod_set_value(led->gpiod, 1);
	} else {
		/* Intermediate -- start PWM if not already running */
		if (!led->pwm_active) {
			led->counter = 0;
			led->pwm_active = true;
			mod_timer(&led->timer, jiffies + 1);
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

	timer_setup(&led->timer, gpio_pwm_timer_fn, 0);

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

	dev_info(dev, "%d LED(s) registered\n", count);

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
