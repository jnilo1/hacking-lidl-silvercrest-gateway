// SPDX-License-Identifier: GPL-2.0+
/*
 * Realtek RTL8196E UART1 glue driver for 8250 core.
 *
 * This driver is specifically for UART1 (0x18002100) which requires hardware
 * flow control for communication with the EFR32 Zigbee NCP. UART0 (0x18002000)
 * uses the standard ns16550a driver and serves as the system console.
 *
 * Manages the SoC-specific flow control register (bit 29 @ 0x18002110) needed
 * for reliable RTS/CTS operation - setting CRTSCTS in termios alone is not
 * sufficient on this SoC. Also forces registration as ttyS1 to avoid stealing
 * the console (ttyS0) from UART0.
 *
 * Copyright (C) 2025 Jacques Nilo
 */

#include <linux/device.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/serial_8250.h>
#include <linux/serial_core.h>
#include <linux/serial_reg.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/of_irq.h>
#include <linux/of_platform.h>
#include <linux/clk.h>

#include "8250.h"

/*
 * RTL8196E UART Flow Control Register
 * Physical address: 0x18002110
 * Virtual address:  0xB8002110 (KSEG1)
 *
 * Bit 29: Hardware Flow Control Enable
 *   0 = Disabled (default) - causes UART overruns
 *   1 = Enabled - proper RTS/CTS operation
 */
#define RTL8196E_UART_FLOW_CTRL_REG_PHYS	0x18002110
#define RTL8196E_UART_FLOW_CTRL_BIT		BIT(29)

/*
 * PIN_MUX_SEL register (physical 0x18000040).
 * Bits 1, 3, 6 must be set for UART1 TXD/RXD signals to reach the
 * physical pins.  Without this, the UART peripheral works internally
 * (THRE fires, DMA runs) but no electrical signal reaches the EFR32.
 */
#define RTL8196E_PIN_MUX_SEL_PHYS		0x18000040
#define RTL8196E_PIN_MUX_UART1_BITS		(BIT(1) | BIT(3) | BIT(6))

/**
 * struct rtl8196e_uart_data - Private data for RTL8196E UART
 * @line: UART line number assigned by serial core
 * @clk: Optional clock for UART
 * @flow_ctrl_base: Virtual address of flow control register
 * @supports_afe: True if auto-flow-control is enabled in DT
 */
struct rtl8196e_uart_data {
	int line;
	struct clk *clk;
	void __iomem *flow_ctrl_base;
	bool supports_afe;
};

/**
 * rtl8196e_uart_enable_flow_control() - Enable hardware flow control
 * @data: RTL8196E UART private data
 *
 * Configures the RTL8196E-specific hardware flow control register.
 * This is REQUIRED for proper RTS/CTS operation - setting CRTSCTS
 * in termios alone is not sufficient on this SoC.
 */
static void rtl8196e_uart_enable_flow_control(struct rtl8196e_uart_data *data)
{
	u32 reg_val;

	if (!data->flow_ctrl_base) {
		pr_warn("RTL8196E UART: Flow control register not mapped\n");
		return;
	}

	reg_val = readl(data->flow_ctrl_base);

	if (reg_val & RTL8196E_UART_FLOW_CTRL_BIT) {
		pr_debug("RTL8196E UART: HW flow control already enabled (0x%08x)\n",
			 reg_val);
		return;
	}

	/* Enable hardware flow control */
	reg_val |= RTL8196E_UART_FLOW_CTRL_BIT;
	writel(reg_val, data->flow_ctrl_base);

	/* Read back to verify */
	reg_val = readl(data->flow_ctrl_base);
	if (reg_val & RTL8196E_UART_FLOW_CTRL_BIT) {
		pr_debug("RTL8196E UART: HW flow control enabled (reg=0x%08x)\n",
			 reg_val);
	} else {
		pr_err("RTL8196E UART: Failed to enable HW flow control!\n");
	}
}

/**
 * rtl8196e_uart_disable_flow_control() - Disable hardware flow control
 * @data: RTL8196E UART private data
 *
 * Disables the RTL8196E-specific hardware flow control register.
 * Called when CRTSCTS is removed from termios.
 */
static void rtl8196e_uart_disable_flow_control(struct rtl8196e_uart_data *data)
{
	u32 reg_val;

	if (!data->flow_ctrl_base) {
		pr_warn("RTL8196E UART: Flow control register not mapped\n");
		return;
	}

	reg_val = readl(data->flow_ctrl_base);

	if (!(reg_val & RTL8196E_UART_FLOW_CTRL_BIT)) {
		pr_debug("RTL8196E UART: HW flow control already disabled (0x%08x)\n",
			 reg_val);
		return;
	}

	/* Disable hardware flow control */
	reg_val &= ~RTL8196E_UART_FLOW_CTRL_BIT;
	writel(reg_val, data->flow_ctrl_base);

	/* Read back to verify */
	reg_val = readl(data->flow_ctrl_base);
	if (!(reg_val & RTL8196E_UART_FLOW_CTRL_BIT)) {
		pr_debug("RTL8196E UART: HW flow control disabled (reg=0x%08x)\n",
			 reg_val);
	} else {
		pr_err("RTL8196E UART: Failed to disable HW flow control!\n");
	}
}

/**
 * rtl8196e_uart_set_termios() - Custom set_termios handler
 * @port: UART port
 * @termios: New termios settings
 * @old: Old termios settings
 *
 * This function is called whenever termios settings change (via tcsetattr/stty).
 * It monitors the CRTSCTS flag and synchronizes the RTL8196E hardware flow
 * control register (bit 29) accordingly.
 */
static void rtl8196e_uart_set_termios(struct uart_port *port,
				      struct ktermios *termios,
				      struct ktermios *old)
{
	struct rtl8196e_uart_data *data = port->private_data;
	bool crtscts_new, crtscts_old;

	/*
	 * Let the 8250 core program baud/LCR/AFE; we only mirror the SoC
	 * flow-control gate (bit 29) after this.
	 */
	serial8250_do_set_termios(port, termios, old);

	/* Only manage HW flow control if AFE is supported */
	if (!data || !data->supports_afe)
		return;

	/* Check if CRTSCTS flag changed */
	crtscts_new = termios->c_cflag & CRTSCTS;
	crtscts_old = old ? (old->c_cflag & CRTSCTS) : false;

	if (crtscts_new == crtscts_old)
		return; /* No change, nothing to do */

	/* Synchronize SoC flow-control gate with CRTSCTS */
	if (crtscts_new) {
		pr_debug("RTL8196E UART: CRTSCTS enabled, activating HW flow control\n");
		rtl8196e_uart_enable_flow_control(data);
	} else {
		pr_debug("RTL8196E UART: CRTSCTS disabled, deactivating HW flow control\n");
		rtl8196e_uart_disable_flow_control(data);
	}
}

/**
 * rtl8196e_uart_probe() - Probe and initialize RTL8196E UART
 * @pdev: Platform device
 *
 * Initializes the UART port and configures RTL8196E-specific features.
 *
 * Return: 0 on success, negative error code on failure
 */
static int rtl8196e_uart_probe(struct platform_device *pdev)
{
	struct uart_8250_port uart = {};
	struct rtl8196e_uart_data *data;
	struct resource *regs;
	int ret;

	data = devm_kzalloc(&pdev->dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;

	/* Get UART registers */
	regs = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!regs) {
		dev_err(&pdev->dev, "No IORESOURCE_MEM resource\n");
		return -EINVAL;
	}

	/* Map flow control register (0x18002110) */
	data->flow_ctrl_base = devm_ioremap(&pdev->dev,
					     RTL8196E_UART_FLOW_CTRL_REG_PHYS,
					     4);
	if (!data->flow_ctrl_base) {
		dev_err(&pdev->dev, "Failed to map flow control register\n");
		return -ENOMEM;
	}

	/* Ensure UART1 pins are muxed to the UART peripheral */
	{
		void __iomem *pin_mux;

		pin_mux = devm_ioremap(&pdev->dev,
				       RTL8196E_PIN_MUX_SEL_PHYS, 4);
		if (pin_mux) {
			u32 val = readl(pin_mux);

			if ((val & RTL8196E_PIN_MUX_UART1_BITS) !=
			    RTL8196E_PIN_MUX_UART1_BITS) {
				val |= RTL8196E_PIN_MUX_UART1_BITS;
				writel(val, pin_mux);
				dev_info(&pdev->dev,
					 "PIN_MUX_SEL: configured for UART1 (0x%08x)\n",
					 readl(pin_mux));
			}
		}
	}

	/* Optional: Get clock if specified in DT */
	data->clk = devm_clk_get(&pdev->dev, NULL);
	if (!IS_ERR(data->clk)) {
		ret = clk_prepare_enable(data->clk);
		if (ret) {
			dev_err(&pdev->dev, "Failed to enable clock: %d\n", ret);
			return ret;
		}
	}

	/* Initialize uart_8250_port structure */
	spin_lock_init(&uart.port.lock);
	uart.port.dev = &pdev->dev;
	uart.port.type = PORT_16550A;
	uart.port.iotype = UPIO_MEM;
	uart.port.mapbase = regs->start;
	uart.port.regshift = 2;  /* 32-bit aligned registers on 8196E */
	uart.port.private_data = data;

	/* Install custom set_termios handler for dynamic flow control */
	uart.port.set_termios = rtl8196e_uart_set_termios;

	/* Get IRQ from device tree */
	uart.port.irq = platform_get_irq(pdev, 0);
	if (uart.port.irq < 0) {
		dev_err(&pdev->dev, "Failed to get IRQ\n");
		ret = uart.port.irq;
		goto err_clk_disable;
	}

	/* Get clock frequency from DT or use default */
	if (of_property_read_u32(pdev->dev.of_node, "clock-frequency",
				 &uart.port.uartclk)) {
		uart.port.uartclk = 200000000; /* Default 200 MHz */
		dev_info(&pdev->dev, "Using default clock frequency: %u Hz\n",
			 uart.port.uartclk);
	}

	/* Map UART registers */
	uart.port.membase = devm_ioremap(&pdev->dev, regs->start,
					  resource_size(regs));
	if (!uart.port.membase) {
		dev_err(&pdev->dev, "Failed to map UART registers\n");
		ret = -ENOMEM;
		goto err_clk_disable;
	}

	/* Set UART capabilities */
	uart.capabilities = UART_CAP_FIFO;

	/* Enable AFE (Automatic Flow Control) if requested in DT */
	if (of_property_read_bool(pdev->dev.of_node, "auto-flow-control") ||
	    of_property_read_bool(pdev->dev.of_node, "uart-has-rtscts")) {
		uart.capabilities |= UART_CAP_AFE;
		data->supports_afe = true;
		/* Enable hardware flow control register (will be managed dynamically) */
		rtl8196e_uart_enable_flow_control(data);
	} else {
		data->supports_afe = false;
	}

	/* Configure FIFO */
	uart.port.fifosize = 16;
	uart.tx_loadsz = 16;
	uart.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_10;

	/* Set port flags */
	uart.port.flags = UPF_FIXED_PORT | UPF_FIXED_TYPE | UPF_BOOT_AUTOCONF;

	/* Force line 1 (ttyS1) to not steal ttyS0 from console uart0 */
	uart.port.line = 1;

	/* Register the port with 8250 subsystem */
	ret = serial8250_register_8250_port(&uart);
	if (ret < 0) {
		dev_err(&pdev->dev, "Failed to register 8250 port: %d\n", ret);
		goto err_clk_disable;
	}

	data->line = ret;
	platform_set_drvdata(pdev, data);

	return 0;

err_clk_disable:
	if (!IS_ERR(data->clk))
		clk_disable_unprepare(data->clk);
	return ret;
}

/**
 * rtl8196e_uart_remove() - Remove RTL8196E UART
 * @pdev: Platform device
 *
 * Return: 0 on success
 */
static int rtl8196e_uart_remove(struct platform_device *pdev)
{
	struct rtl8196e_uart_data *data = platform_get_drvdata(pdev);

	serial8250_unregister_port(data->line);

	if (!IS_ERR(data->clk))
		clk_disable_unprepare(data->clk);

	return 0;
}

/* Device tree match table */
static const struct of_device_id rtl8196e_uart_of_match[] = {
	{ .compatible = "realtek,rtl8196e-uart" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, rtl8196e_uart_of_match);

/* Platform driver structure */
static struct platform_driver rtl8196e_uart_driver = {
	.probe = rtl8196e_uart_probe,
	.remove = rtl8196e_uart_remove,
	.driver = {
		.name = "rtl8196e-uart",
		.of_match_table = rtl8196e_uart_of_match,
	},
};

module_platform_driver(rtl8196e_uart_driver);

MODULE_AUTHOR("Jacques Nilo");
MODULE_DESCRIPTION("Realtek RTL8196E UART driver with hardware flow control");
MODULE_LICENSE("GPL");
