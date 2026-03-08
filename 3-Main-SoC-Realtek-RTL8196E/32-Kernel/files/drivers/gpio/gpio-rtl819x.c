// SPDX-License-Identifier: GPL-2.0-only
/*
 * GPIO driver for Realtek RTL8196E SoC
 *
 * The RTL8196E has 4 GPIO ports (A, B, C, D) with 8 pins each = 32 GPIOs
 *   - Port A: GPIO 0-7
 *   - Port B: GPIO 8-15
 *   - Port C: GPIO 16-23
 *   - Port D: GPIO 24-31
 *
 * Register layout (GPIO base 0xB8003500):
 *   0x00: PABCD_CNR  - Port ABCD control (0=GPIO, 1=peripheral)
 *   0x04: PABCD_PTYPE - Port ABCD type
 *   0x08: PABCD_DIR  - Port ABCD direction (0=input, 1=output)
 *   0x0C: PABCD_DAT  - Port ABCD data
 *   0x10: PABCD_ISR  - Port ABCD interrupt status
 *   0x14: PAB_IMR    - Port AB interrupt mask
 *   0x18: PCD_IMR    - Port CD interrupt mask
 *
 * Pin muxing (RTL8196E specific - other chips may differ):
 *   PIN_MUX_SEL_2 (0x18000044) controls GPIO B2-B6 shared with LED_PORT0-4
 *   Bits must be set to 0b11 to enable GPIO mode for these pins.
 *
 * Note: Other RTL819x variants (RTL8196C, RTL8197F) may have different
 * pinmux register layouts. This driver is tested on RTL8196E only.
 *
 * Author: Jacques Nilo
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/gpio/driver.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/spinlock.h>
#include <linux/mfd/syscon.h>
#include <linux/regmap.h>

#define RTL819X_GPIO_REG_CNR    0x00    /* Control register */
#define RTL819X_GPIO_REG_PTYPE  0x04    /* Port type */
#define RTL819X_GPIO_REG_DIR    0x08    /* Direction: 0=in, 1=out */
#define RTL819X_GPIO_REG_DATA   0x0C    /* Data register */
#define RTL819X_GPIO_REG_ISR    0x10    /* Interrupt status */
#define RTL819X_GPIO_REG_IMR    0x14    /* Interrupt mask */

#define RTL819X_GPIO_NUM        32      /* 4 ports x 8 bits */

#define DRIVER_NAME             "gpio-rtl819x"

struct rtl819x_gpio {
    struct gpio_chip        gc;
    void __iomem            *base;
    struct regmap           *syscon;    /* PIN_MUX_SEL_2 for LED/GPIO mux */
    spinlock_t              lock;
};

static inline struct rtl819x_gpio *to_rtl819x_gpio(struct gpio_chip *gc)
{
    return container_of(gc, struct rtl819x_gpio, gc);
}

/*
 * Configure PIN_MUX_SEL_2 for GPIO B2-B6 (shared with LED_PORT0-4)
 * RTL8196E datasheet Table 36:
 *   GPIO 10 (B2): bits 1:0  = 11 for GPIO mode
 *   GPIO 11 (B3): bits 4:3  = 11 for GPIO mode
 *   GPIO 12 (B4): bits 7:6  = 11 for GPIO mode
 *   GPIO 13 (B5): bits 10:9 = 11 for GPIO mode
 *   GPIO 14 (B6): bits 13:12 = 11 for GPIO mode
 */
static void rtl819x_gpio_configure_pinmux(struct rtl819x_gpio *rg, unsigned int offset)
{
    u32 mask = 0, bits = 0;

    if (!rg->syscon)
        return;

    switch (offset) {
    case 10: /* GPIO B2 - LED_PORT0 */
        mask = 0x3 << 0;
        bits = 0x3 << 0;
        break;
    case 11: /* GPIO B3 - LED_PORT1 */
        mask = 0x3 << 3;
        bits = 0x3 << 3;
        break;
    case 12: /* GPIO B4 - LED_PORT2 */
        mask = 0x3 << 6;
        bits = 0x3 << 6;
        break;
    case 13: /* GPIO B5 - LED_PORT3 */
        mask = 0x3 << 9;
        bits = 0x3 << 9;
        break;
    case 14: /* GPIO B6 - LED_PORT4 */
        mask = 0x3 << 12;
        bits = 0x3 << 12;
        break;
    default:
        return; /* No pinmux needed for other GPIOs */
    }

    regmap_update_bits(rg->syscon, 0x44, mask, bits);
}

static int rtl819x_gpio_request(struct gpio_chip *gc, unsigned int offset)
{
    struct rtl819x_gpio *rg = to_rtl819x_gpio(gc);
    unsigned long flags;
    u32 val;

    spin_lock_irqsave(&rg->lock, flags);

    /* Configure pinmux for GPIO B2-B6 (shared with LED ports) */
    rtl819x_gpio_configure_pinmux(rg, offset);

    /* Enable GPIO function (clear bit in CNR = GPIO mode) */
    val = readl(rg->base + RTL819X_GPIO_REG_CNR);
    val &= ~BIT(offset);
    writel(val, rg->base + RTL819X_GPIO_REG_CNR);

    spin_unlock_irqrestore(&rg->lock, flags);

    return 0;
}

static void rtl819x_gpio_free(struct gpio_chip *gc, unsigned int offset)
{
    /* Nothing to do - leave GPIO configured */
}

static int rtl819x_gpio_get_direction(struct gpio_chip *gc, unsigned int offset)
{
    struct rtl819x_gpio *rg = to_rtl819x_gpio(gc);
    unsigned long flags;
    u32 val;

    spin_lock_irqsave(&rg->lock, flags);
    val = readl(rg->base + RTL819X_GPIO_REG_DIR);
    spin_unlock_irqrestore(&rg->lock, flags);

    /* DIR bit: 0=input, 1=output (per RTL8196E datasheet) */
    if (val & BIT(offset))
        return GPIO_LINE_DIRECTION_OUT;
    else
        return GPIO_LINE_DIRECTION_IN;
}

static int rtl819x_gpio_direction_input(struct gpio_chip *gc, unsigned int offset)
{
    struct rtl819x_gpio *rg = to_rtl819x_gpio(gc);
    unsigned long flags;
    u32 val;

    spin_lock_irqsave(&rg->lock, flags);

    val = readl(rg->base + RTL819X_GPIO_REG_DIR);
    val &= ~BIT(offset);    /* 0 = input */
    writel(val, rg->base + RTL819X_GPIO_REG_DIR);

    spin_unlock_irqrestore(&rg->lock, flags);

    return 0;
}

static int rtl819x_gpio_direction_output(struct gpio_chip *gc,
                                         unsigned int offset, int value)
{
    struct rtl819x_gpio *rg = to_rtl819x_gpio(gc);
    unsigned long flags;
    u32 val;

    spin_lock_irqsave(&rg->lock, flags);

    /* Set value first */
    val = readl(rg->base + RTL819X_GPIO_REG_DATA);
    if (value)
        val |= BIT(offset);
    else
        val &= ~BIT(offset);
    writel(val, rg->base + RTL819X_GPIO_REG_DATA);

    /* Then set direction to output */
    val = readl(rg->base + RTL819X_GPIO_REG_DIR);
    val |= BIT(offset);     /* 1 = output */
    writel(val, rg->base + RTL819X_GPIO_REG_DIR);

    spin_unlock_irqrestore(&rg->lock, flags);

    return 0;
}

static int rtl819x_gpio_get(struct gpio_chip *gc, unsigned int offset)
{
    struct rtl819x_gpio *rg = to_rtl819x_gpio(gc);
    u32 val;

    val = readl(rg->base + RTL819X_GPIO_REG_DATA);

    return !!(val & BIT(offset));
}

static void rtl819x_gpio_set(struct gpio_chip *gc, unsigned int offset, int value)
{
    struct rtl819x_gpio *rg = to_rtl819x_gpio(gc);
    unsigned long flags;
    u32 val;

    spin_lock_irqsave(&rg->lock, flags);

    val = readl(rg->base + RTL819X_GPIO_REG_DATA);
    if (value)
        val |= BIT(offset);
    else
        val &= ~BIT(offset);
    writel(val, rg->base + RTL819X_GPIO_REG_DATA);

    spin_unlock_irqrestore(&rg->lock, flags);
}

static int rtl819x_gpio_probe(struct platform_device *pdev)
{
    struct device *dev = &pdev->dev;
    struct rtl819x_gpio *rg;
    struct resource *res;
    int ret;

    rg = devm_kzalloc(dev, sizeof(*rg), GFP_KERNEL);
    if (!rg)
        return -ENOMEM;

    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    rg->base = devm_ioremap_resource(dev, res);
    if (IS_ERR(rg->base))
        return PTR_ERR(rg->base);

    /* Get syscon regmap for PIN_MUX_SEL_2 pinmux configuration */
    rg->syscon = syscon_regmap_lookup_by_phandle(dev->of_node, "realtek,syscon");
    if (IS_ERR(rg->syscon)) {
        dev_warn(dev, "no syscon, LED GPIOs may not work\n");
        rg->syscon = NULL;
    }

    spin_lock_init(&rg->lock);

    rg->gc.label            = DRIVER_NAME;
    rg->gc.parent           = dev;
    rg->gc.owner            = THIS_MODULE;
    rg->gc.request          = rtl819x_gpio_request;
    rg->gc.free             = rtl819x_gpio_free;
    rg->gc.get_direction    = rtl819x_gpio_get_direction;
    rg->gc.direction_input  = rtl819x_gpio_direction_input;
    rg->gc.direction_output = rtl819x_gpio_direction_output;
    rg->gc.get              = rtl819x_gpio_get;
    rg->gc.set              = rtl819x_gpio_set;
    rg->gc.base             = 0;
    rg->gc.ngpio            = RTL819X_GPIO_NUM;
    rg->gc.can_sleep        = false;

    ret = devm_gpiochip_add_data(dev, &rg->gc, rg);
    if (ret) {
        dev_err(dev, "failed to register gpio chip: %d\n", ret);
        return ret;
    }

    platform_set_drvdata(pdev, rg);

    dev_info(dev, "registered %d GPIOs\n", RTL819X_GPIO_NUM);

    return 0;
}

static const struct of_device_id rtl819x_gpio_of_match[] = {
    { .compatible = "realtek,realtek-gpio" },
    { .compatible = "realtek,rtl819x-gpio" },
    { .compatible = "realtek,rtl8196e-gpio" },
    { /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, rtl819x_gpio_of_match);

static struct platform_driver rtl819x_gpio_driver = {
    .probe  = rtl819x_gpio_probe,
    .driver = {
        .name           = DRIVER_NAME,
        .of_match_table = rtl819x_gpio_of_match,
    },
};

module_platform_driver(rtl819x_gpio_driver);

MODULE_AUTHOR("Jacques Nilo");
MODULE_DESCRIPTION("GPIO driver for Realtek RTL819x SoCs");
MODULE_LICENSE("GPL");
