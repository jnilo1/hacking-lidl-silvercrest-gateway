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
#include <linux/mfd/syscon.h>
#include <linux/regmap.h>

#include "8250.h"

#define DRV_NAME    "rtl8196e-uart"
#define DRV_VERSION "1.4"

/*
 * RTL8196E UART Flow Control Register
 * Physical address: 0x18002110 == UART1 base (0x18002100) + 0x10 == MCR
 *                   with regshift=2 (reg 4 << 2).
 *
 * This 32-bit word at 0x18002110 is the MCR register seen through the
 * big-endian byte-lane routing of the SoC bus: writeb() by the 8250
 * core lands in bits 31:24 (the MCR byte), and bit 29 of the 32-bit
 * word is UART_MCR_AFE (bit 5 of the MCR byte). Our readl/writel RMW
 * preserves DTR/RTS/OUT2 (bits 24/25/27) that the core writes.
 *
 * Validated on hardware (2026-04-23) via devmem cycles:
 *   - boot:             0x2B000000 (DTR|RTS|OUT2|AFE)
 *   - stty -crtscts:    0x0B000000 (AFE cleared by core writeb)
 *   - stty crtscts:     0x2B000000 (AFE restored by our set_termios)
 *
 * Bit 29: Hardware Flow Control Enable (MCR_AFE alias)
 *   0 = Disabled (default) - causes UART overruns
 *   1 = Enabled - proper RTS/CTS operation
 */
#define RTL8196E_UART_FLOW_CTRL_OFFSET		0x10	/* reg 4 (MCR) << regshift=2 */
#define RTL8196E_UART_FLOW_CTRL_BIT		BIT(29)

/*
 * Full MCR pattern enforced when CRTSCTS is active: DTR|RTS|OUT2|AFE,
 * shifted into bits 24..31 by the SoC's byte-lane routing (see comment
 * above). This is the boot-time value 0x2B000000 documented at the top
 * of the file; we re-enforce it on every enable_flow_control() call.
 */
#define RTL8196E_UART_MCR_PATTERN	\
	(((u32)(UART_MCR_DTR | UART_MCR_RTS | UART_MCR_OUT2 | UART_MCR_AFE)) << 24)

/*
 * PIN_MUX_SEL register (offset 0x40 in system controller).
 * Bits 1, 3, 6 must be set for UART1 TXD/RXD signals to reach the
 * physical pins.  Without this, the UART peripheral works internally
 * (THRE fires, DMA runs) but no electrical signal reaches the EFR32.
 */
#define RTL8196E_PIN_MUX_UART1_BITS		(BIT(1) | BIT(3) | BIT(6))

/**
 * struct rtl8196e_uart_data - Private data for RTL8196E UART
 * @line: UART line number assigned by serial core
 * @clk: Optional clock for UART
 * @flow_ctrl_base: Virtual address of flow control register
 * @supports_afe: True if auto-flow-control is enabled in DT
 * @flow_active: True while CRTSCTS/AFE flow control is currently engaged.
 *   Gates the set_mctrl RTS-pin guard (issue #109): only force RTS on when
 *   hardware flow control actually owns the line. Synced to the absolute
 *   CRTSCTS state on every set_termios call (audit 8250RTL-008).
 */
struct rtl8196e_uart_data {
	int line;
	struct clk *clk;
	void __iomem *flow_ctrl_base;
	bool supports_afe;
	bool flow_active;
	struct device *dev;
};

/**
 * rtl8196e_uart_enable_flow_control() - Enable hardware flow control
 * @port: UART port (used to take port->lock around the RMW)
 * @data: RTL8196E UART private data
 *
 * Configures the RTL8196E-specific hardware flow control register.
 * This is REQUIRED for proper RTS/CTS operation - setting CRTSCTS
 * in termios alone is not sufficient on this SoC.
 *
 * Locking: takes port->lock with IRQ disabled around the readl/writel.
 * Without this, the 8250 core's byte-level MCR writes (e.g. from
 * serial8250_set_mctrl, serial8250_em485_stop_tx) can clobber bit 29
 * (AFE) between our readl() and writel() — confirmed cause of UART RX
 * FIFO overruns under bursty load at 460800 (issue #89).
 */
static void rtl8196e_uart_enable_flow_control(struct uart_port *port,
					      struct rtl8196e_uart_data *data)
{
	unsigned long flags = 0;
	u32 reg_val;

	if (!data->flow_ctrl_base) {
		dev_warn(data->dev, "flow control register not mapped\n");
		return;
	}

	/* @port may be NULL during probe-time pre-registration, where
	 * no concurrency exists. Skip lock acquisition in that case. */
	if (port)
		uart_port_lock_irqsave(port, &flags);
	/*
	 * Force the full MCR pattern (DTR|RTS|OUT2|AFE) on every call: the
	 * 8250 core's byte-wise MCR writes during set_termios preserve AFE
	 * but stomp DTR/RTS/OUT2 to its mctrl shadow, leaving the SoC at
	 * MCR=0x20000000 (AFE only). With RTS clear under AFE the SoC
	 * asserts !RTS to the EFR32 → RCP Spinel responses throttle →
	 * otbr-agent times out. The earlier "skip if AFE already set"
	 * fast-path masked this — we must re-OR every time.
	 */
	reg_val = readl(data->flow_ctrl_base);
	reg_val |= RTL8196E_UART_MCR_PATTERN;
	writel(reg_val, data->flow_ctrl_base);
	/* Arm the set_mctrl RTS guard while flow control owns the line. */
	data->flow_active = true;
	/* Read back under lock to verify atomically */
	reg_val = readl(data->flow_ctrl_base);
	if (port)
		uart_port_unlock_irqrestore(port, flags);

	if ((reg_val & RTL8196E_UART_MCR_PATTERN) == RTL8196E_UART_MCR_PATTERN) {
		dev_dbg(data->dev, "HW flow control enforced (reg=0x%08x)\n",
			reg_val);
	} else {
		dev_err(data->dev,
			"MCR pattern incomplete: 0x%08x (want 0x%08x set)\n",
			reg_val, RTL8196E_UART_MCR_PATTERN);
	}
}

/**
 * rtl8196e_uart_disable_flow_control() - Disable hardware flow control
 * @port: UART port (used to take port->lock around the RMW)
 * @data: RTL8196E UART private data
 *
 * Disables the RTL8196E-specific hardware flow control register.
 * Called when CRTSCTS is removed from termios.
 *
 * Locking: same rationale as enable_flow_control — see comment there.
 */
static void rtl8196e_uart_disable_flow_control(struct uart_port *port,
					       struct rtl8196e_uart_data *data)
{
	unsigned long flags = 0;
	u32 reg_val;

	if (!data->flow_ctrl_base) {
		dev_warn(data->dev, "flow control register not mapped\n");
		return;
	}

	/* @port NULL allowed at probe time only — see enable_flow_control. */
	if (port)
		uart_port_lock_irqsave(port, &flags);
	/* Disarm the set_mctrl RTS guard: software may manage RTS again. */
	data->flow_active = false;
	reg_val = readl(data->flow_ctrl_base);
	if (!(reg_val & RTL8196E_UART_FLOW_CTRL_BIT)) {
		if (port)
			uart_port_unlock_irqrestore(port, flags);
		dev_dbg(data->dev, "HW flow control already disabled (0x%08x)\n",
			reg_val);
		return;
	}
	reg_val &= ~RTL8196E_UART_FLOW_CTRL_BIT;
	writel(reg_val, data->flow_ctrl_base);
	/* Read back under lock to verify atomically */
	reg_val = readl(data->flow_ctrl_base);
	if (port)
		uart_port_unlock_irqrestore(port, flags);

	if (!(reg_val & RTL8196E_UART_FLOW_CTRL_BIT)) {
		dev_dbg(data->dev, "HW flow control disabled (reg=0x%08x)\n",
			reg_val);
	} else {
		dev_err(data->dev, "Failed to disable HW flow control!\n");
	}
}

/**
 * rtl8196e_uart_set_divisor() - Custom divisor programmer
 * @port: UART port
 * @baud: target baud rate
 * @quot: divisor computed by the 8250 core (clock / (16 * baud))
 * @quot_frac: fractional divisor (unused on this SoC)
 *
 * The RTL8196E UART interprets the value written to DLL/DLM as (N + 1),
 * not N like a textbook 16550A. Evidence:
 *   - The stock Realtek bootloader uses `divisor = clock/16/baud - 1`
 *     (see 31-Bootloader/boot/uart.c).
 *   - Leaving it alone produces usable baud at 115200/230400 (error
 *     <1.4%, within tolerance) but catastrophic ~3% error at 460800,
 *     manifesting as ~40% framing errors on the wire.
 *   - Programming `quot - 1` restores a 0.47% error at 460800 and
 *     matches what the RTL hardware actually emits — verified live by
 *     arming the bridge at a fake baud such that the unpatched core
 *     programmed quot-1 and observing FE=0.
 *
 * Compensate by programming (quot - 1) so the hardware ends up at the
 * requested baud rate.
 */
static void rtl8196e_uart_set_divisor(struct uart_port *port, unsigned int baud,
				      unsigned int quot, unsigned int quot_frac)
{
	unsigned int adjusted = quot > 1 ? quot - 1 : quot;

	(void)quot_frac;
	serial8250_do_set_divisor(port, baud, adjusted);
}

/**
 * rtl8196e_uart_set_termios() - Custom set_termios handler
 * @port: UART port
 * @termios: New termios settings
 * @old: Old termios settings
 *
 * This function is called whenever termios settings change (via tcsetattr/stty).
 * It synchronizes the RTL8196E hardware flow control register (bit 29) with
 * the CRTSCTS flag.
 *
 * The sync is on the *absolute* CRTSCTS state, not on transitions:
 * edge-detection left @flow_active stale-true (RTS guard armed, AFE off)
 * from the probe-time pre-enable until the first CRTSCTS toggle, because
 * the first open arrives with default termios and no edge (audit
 * 8250RTL-008). Re-enforcing the full MCR pattern on every CRTSCTS termios
 * call is also one more layer against shadow-MCR clobbers (v3.5.1).
 */
static void rtl8196e_uart_set_termios(struct uart_port *port,
				      struct ktermios *termios,
				      const struct ktermios *old)
{
	struct rtl8196e_uart_data *data = port->private_data;

	/*
	 * Let the 8250 core program baud/LCR/AFE; we only mirror the SoC
	 * flow-control gate (bit 29) after this.
	 */
	serial8250_do_set_termios(port, termios, old);

	/* Only manage HW flow control if AFE is supported */
	if (!data || !data->supports_afe)
		return;

	if (termios->c_cflag & CRTSCTS)
		rtl8196e_uart_enable_flow_control(port, data);
	else
		rtl8196e_uart_disable_flow_control(port, data);
}

/**
 * rtl8196e_uart_set_mctrl() - Custom modem-control programmer
 * @port: UART port
 * @mctrl: modem control bits requested by serial_core / 8250 core
 *
 * While hardware AFE owns the RTS line, never let a software caller deassert
 * RTS. With CRTSCTS active but UPSTAT_AUTORTS not advertised, serial_core's
 * uart_throttle() path calls uart_clear_mctrl(port, TIOCM_RTS) whenever the
 * tty RX buffer backs up; that write lands in the MCR (RTS bit cleared) and,
 * under AFE, pins RTS deasserted to the EFR32 — the SoC tells the RCP "do not
 * send" and never lifts it, so Spinel responses stall and otbr-agent times out
 * after hours/days of uptime (issue #109; confirmed in the field by a
 * 0x18002110 readout of 0x20000000 at the wedge, restored to 0x2B000000 by an
 * otbr-agent restart). The v3.5.1 hotfix only re-asserts the pattern on
 * probe and on a CRTSCTS off->on transition, which steady-state OTBR never
 * triggers; this guard closes every runtime set_mctrl path instead.
 *
 * Re-OR TIOCM_RTS so RTS stays asserted in the MCR; the real backpressure is
 * still handled by hardware AFE, which gates the physical RTS line on the RX
 * FIFO level regardless. Only active while flow control is engaged, so a
 * deliberate `stty -crtscts` still releases RTS to software control.
 */
static void rtl8196e_uart_set_mctrl(struct uart_port *port, unsigned int mctrl)
{
	struct rtl8196e_uart_data *data = port->private_data;

	if (data && data->supports_afe && data->flow_active)
		mctrl |= TIOCM_RTS;

	serial8250_do_set_mctrl(port, mctrl);
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
	data->dev = &pdev->dev;

	/* Map the UART register window WITHOUT claiming the mem region:
	 * the 8250 core claims it itself in serial8250_config_port()
	 * (serial8250_request_std_resource). A devm request here made that
	 * claim fail with -EBUSY and config_port bail out early, which left
	 * up->fcr at 0 (FIFO genuinely disabled on the wire — confirmed via
	 * IIR bits 7:6 = 00) and the rx_trig_bytes sysfs knob unregistered.
	 * Audit 8250RTL-007; plain devm_ioremap is the standard 8250-glue
	 * idiom (cf. 8250_dw).
	 */
	regs = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!regs) {
		dev_err(&pdev->dev, "no UART register resource\n");
		return -EINVAL;
	}
	uart.port.membase = devm_ioremap(&pdev->dev, regs->start,
					 resource_size(regs));
	if (!uart.port.membase) {
		dev_err(&pdev->dev, "Failed to map UART registers\n");
		return -ENOMEM;
	}

	/* flow_ctrl_base is an alias on MCR; assigned after struct init below */

	/* Ensure UART1 pins are muxed to the UART peripheral via syscon.
	 * Audit 8250RTL-001: syscon is required on this SoC — without the
	 * pinmux, UART1 may appear as a usable ttyS1 internally but the
	 * RX/TX signals never reach the EFR32. Treat lookup failure as
	 * fatal (other than -EPROBE_DEFER) rather than warn-and-continue,
	 * so we surface the misconfig clearly instead of producing a
	 * silently-broken serial link. */
	{
		struct regmap *syscon;

		syscon = syscon_regmap_lookup_by_phandle(pdev->dev.of_node,
							 "realtek,syscon");
		if (IS_ERR(syscon)) {
			ret = PTR_ERR(syscon);
			if (ret != -EPROBE_DEFER)
				dev_err(&pdev->dev,
					"syscon lookup failed (%d), cannot mux UART1 pins\n",
					ret);
			return ret;
		}
		ret = regmap_update_bits(syscon, 0x40,
					 RTL8196E_PIN_MUX_UART1_BITS,
					 RTL8196E_PIN_MUX_UART1_BITS);
		if (ret) {
			dev_err(&pdev->dev, "pin mux write failed: %d\n", ret);
			return ret;
		}
	}

	/* Optional: Get clock if specified in DT */
	data->clk = devm_clk_get_optional(&pdev->dev, NULL);
	if (IS_ERR(data->clk))
		return PTR_ERR(data->clk);
	if (data->clk) {
		ret = clk_prepare_enable(data->clk);
		if (ret) {
			dev_err(&pdev->dev, "Failed to enable clock: %d\n", ret);
			return ret;
		}
	}

	/* Initialize uart_8250_port structure */
	uart.port.dev = &pdev->dev;
	uart.port.type = PORT_16550A;
	uart.port.iotype = UPIO_MEM;
	uart.port.mapbase = regs->start;
	uart.port.regshift = 2;  /* 32-bit aligned registers on 8196E */
	uart.port.private_data = data;

	/* Install custom set_termios handler for dynamic flow control */
	uart.port.set_termios = rtl8196e_uart_set_termios;

	/* Install custom divisor programmer (compensates for the RTL's N+1 quirk) */
	uart.port.set_divisor = rtl8196e_uart_set_divisor;

	/* Install custom modem-control programmer: keep RTS asserted under AFE so
	 * serial_core's software throttle cannot wedge the EFR32 link (issue #109). */
	uart.port.set_mctrl = rtl8196e_uart_set_mctrl;

	/* Get IRQ from device tree */
	ret = platform_get_irq(pdev, 0);
	if (ret < 0) {
		dev_err(&pdev->dev, "Failed to get IRQ: %d\n", ret);
		goto err_clk_disable;
	}
	uart.port.irq = ret;

	/* Get clock frequency: DT property > clock framework > 200 MHz fallback */
	if (of_property_read_u32(pdev->dev.of_node, "clock-frequency",
				 &uart.port.uartclk)) {
		if (data->clk)
			uart.port.uartclk = clk_get_rate(data->clk);
		if (!uart.port.uartclk) {
			uart.port.uartclk = 200000000;
			dev_info(&pdev->dev, "uartclk: %u Hz (fallback)\n",
				 uart.port.uartclk);
		} else {
			dev_info(&pdev->dev, "uartclk: %u Hz (clock framework)\n",
				 uart.port.uartclk);
		}
	}

	/* flow_ctrl_base aliases MCR (see header comment). */
	data->flow_ctrl_base = uart.port.membase + RTL8196E_UART_FLOW_CTRL_OFFSET;

	/* Set UART capabilities */
	uart.capabilities = UART_CAP_FIFO;

	/* Enable AFE (Automatic Flow Control) if requested in DT */
	if (of_property_read_bool(pdev->dev.of_node, "auto-flow-control") ||
	    of_property_read_bool(pdev->dev.of_node, "uart-has-rtscts")) {
		uart.capabilities |= UART_CAP_AFE;
		data->supports_afe = true;
		/* Enable hardware flow control register (will be managed dynamically).
		 * port is NULL here: pre-registration, no concurrency yet. */
		rtl8196e_uart_enable_flow_control(NULL, data);
	} else {
		data->supports_afe = false;
	}

	/* Configure FIFO. No .fcr on purpose: the template field is never
	 * copied by serial8250_register_8250_port() (audit 8250RTL-006).
	 * The effective FCR is pinned post-registration instead — see the
	 * trigger-1 erratum block after the ttyS1 line check below.
	 */
	uart.port.fifosize = 16;
	uart.tx_loadsz = 16;

	/* Set port flags */
	uart.port.flags = UPF_FIXED_PORT | UPF_FIXED_TYPE;

	/* Force line 1 (ttyS1) to not steal ttyS0 from console uart0 */
	uart.port.line = 1;

	/* Register the port with 8250 subsystem */
	ret = serial8250_register_8250_port(&uart);
	if (ret < 0) {
		dev_err(&pdev->dev, "Failed to register 8250 port: %d\n", ret);
		goto err_clk_disable;
	}

	data->line = ret;
	/* Audit 8250RTL-002: ttyS1 is a platform contract — rtl8196e-uart-bridge,
	 * S50uart_bridge, S70otbr, and radio.conf all assume /dev/ttyS1. If the
	 * core registered us as a different line (e.g. ttyS1 was already taken
	 * by some other registration), fail probe explicitly instead of leaving
	 * a silently mis-wired bridge. */
	if (ret != 1) {
		dev_err(&pdev->dev, "registered as ttyS%d, expected ttyS1\n", ret);
		serial8250_unregister_port(data->line);
		ret = -EBUSY;
		goto err_clk_disable;
	}

	/* Pin the RX FIFO trigger to 1 (R_TRIG_00), overriding the
	 * PORT_16550A table default (trigger 8) that config_port just set.
	 * Hardware erratum (audit 8250RTL-009): on this UART clone, RX
	 * trigger levels above 1 produce erratic overruns under sustained
	 * line-rate load, non-monotonic in the trigger value (loopback
	 * bench 2026-06-12, 20 s flood, flow control off:
	 *   892857: trig1 oe=0, trig4 oe=548, trig8 oe=53, trig14 oe=2
	 *   460800: trig1 oe=0, trig8 oe=3,  trig14 oe=2088).
	 * Trigger 1 with the FIFO enabled keeps the full 16-byte cushion
	 * against IRQ latency and is wire-identical to the long-proven
	 * v3.x behaviour (FCR=0 on this clone kept the FIFO alive with an
	 * effective trigger of 1 — see 8250RTL-007). The cost, ~1 IRQ per
	 * 1-2 RX bytes at line rate, is the historical baseline. The
	 * rx_trig_bytes sysfs knob stays writable for experiments.
	 */
	{
		struct uart_8250_port *up = serial8250_get_port(data->line);

		up->fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_00;
	}

	/* Re-assert flow control after register_8250_port to cover any MCR
	 * writes performed by the core during port setup.
	 * port is NULL here: just-registered, port struct in core not yet
	 * exposed to userspace; no concurrent open() / set_mctrl() possible. */
	if (data->supports_afe)
		rtl8196e_uart_enable_flow_control(NULL, data);

	platform_set_drvdata(pdev, data);

	dev_info(&pdev->dev,
		 "v" DRV_VERSION " (J. Nilo) - ttyS%d @ %u baud-clk, IRQ %d, FIFO %d, AFE %s\n",
		 data->line, uart.port.uartclk, uart.port.irq,
		 uart.port.fifosize, data->supports_afe ? "on" : "off");

	return 0;

err_clk_disable:
	if (data->clk)
		clk_disable_unprepare(data->clk);
	return ret;
}

/**
 * rtl8196e_uart_remove() - Remove RTL8196E UART
 * @pdev: Platform device
 *
 * Return: 0 on success
 */
static void rtl8196e_uart_remove(struct platform_device *pdev)
{
	struct rtl8196e_uart_data *data = platform_get_drvdata(pdev);

	serial8250_unregister_port(data->line);

	if (data->clk)
		clk_disable_unprepare(data->clk);
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
MODULE_VERSION(DRV_VERSION);
MODULE_LICENSE("GPL");
