// SPDX-License-Identifier: GPL-2.0+
/*
 * RTL8196E Status LED Driver
 * 
 * Creates /proc/led1 interface for Silvercrest (Lidl) 
 * Smart Home Gateway "Status" Led
 * Controls GPIO 11 (Port B3) with inverted logic
 *
 * Usage:
 *   echo 1 > /proc/led1   # LED on
 *   echo 0 > /proc/led1   # LED off
 *   cat /proc/led1        # Read state
 *
 * Author: Jacques Nilo
 * License: GPL-2.0+
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/gpio.h>

#define LED_GPIO        11
#define PROC_NAME       "led1"
#define DRIVER_NAME     "leds-rtl8196e"

static struct proc_dir_entry *proc_entry;
static DEFINE_MUTEX(led_mutex);

static ssize_t led_write(struct file *file, const char __user *buf,
                         size_t count, loff_t *pos)
{
    char kbuf[4];
    size_t len;

    if (count == 0)
        return 0;

    len = min(count, sizeof(kbuf) - 1);

    if (copy_from_user(kbuf, buf, len))
        return -EFAULT;

    kbuf[len] = '\0';

    mutex_lock(&led_mutex);

    /* GPIO 11, inverted logic: 0=on, 1=off */
    if (kbuf[0] == '1')
        gpio_set_value(LED_GPIO, 0);  /* Turn on */
    else if (kbuf[0] == '0')
        gpio_set_value(LED_GPIO, 1);  /* Turn off */

    mutex_unlock(&led_mutex);

    return count;
}

static ssize_t led_read(struct file *file, char __user *buf,
                        size_t count, loff_t *pos)
{
    char status[3];
    int val;

    if (*pos > 0)
        return 0;

    if (count < 2)
        return -EINVAL;

    mutex_lock(&led_mutex);
    val = gpio_get_value(LED_GPIO);
    mutex_unlock(&led_mutex);

    /* Inverted logic: GPIO=0 means LED is on */
    status[0] = (val == 0) ? '1' : '0';
    status[1] = '\n';

    if (copy_to_user(buf, status, 2))
        return -EFAULT;

    *pos = 2;
    return 2;
}

static const struct proc_ops led_proc_ops = {
    .proc_read  = led_read,
    .proc_write = led_write,
};

static int __init rtl8196e_led_init(void)
{
    int ret;

    /* Request GPIO */
    ret = gpio_request(LED_GPIO, DRIVER_NAME);
    if (ret) {
        pr_err("%s: cannot request GPIO %d (err=%d)\n",
               DRIVER_NAME, LED_GPIO, ret);
        return ret;
    }

    /* Set as output, LED off at startup (inverted logic) */
    ret = gpio_direction_output(LED_GPIO, 1);
    if (ret) {
        pr_err("%s: cannot set GPIO %d as output (err=%d)\n",
               DRIVER_NAME, LED_GPIO, ret);
        gpio_free(LED_GPIO);
        return ret;
    }

    /* Create /proc/led1 entry */
    proc_entry = proc_create(PROC_NAME, 0644, NULL, &led_proc_ops);
    if (!proc_entry) {
        pr_err("%s: cannot create /proc/%s\n", DRIVER_NAME, PROC_NAME);
        gpio_free(LED_GPIO);
        return -ENOMEM;
    }

    pr_info("%s: /proc/%s created (GPIO %d, inverted logic)\n",
            DRIVER_NAME, PROC_NAME, LED_GPIO);

    return 0;
}

static void __exit rtl8196e_led_exit(void)
{
    proc_remove(proc_entry);
    gpio_set_value(LED_GPIO, 1);  /* Turn off before releasing */
    gpio_free(LED_GPIO);
    pr_info("%s: removed\n", DRIVER_NAME);
}

/* Use device_initcall to ensure GPIO subsystem is ready */
late_initcall(rtl8196e_led_init);
module_exit(rtl8196e_led_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Jacques Nilo");
MODULE_DESCRIPTION("Status LED driver for RTL8196E Silvercrest gateway");
