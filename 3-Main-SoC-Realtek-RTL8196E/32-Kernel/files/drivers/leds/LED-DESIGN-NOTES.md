# LED management on the Silvercrest/Lidl Zigbee gateway (RTL8196E)

## Hardware

The gateway has two front-panel LEDs, active-low, wired to RTL8196E
dual-function pads that can be routed to either the GPIO controller or
the switch ASIC LED controller via the `PIN_MUX_SEL_2` register
(0xB800_0044).

Source: RTL8196E-CG datasheet Rev 1.0, Table 3 (Shared I/O Pin Mapping)
and Table 36 (PIN_MUX_SEL_2).

| LED    | Label  | Pin | GPIO pad | LED function | PIN_MUX_SEL_2 bits | 00 = LED   | 11 = GPIO |
|--------|--------|-----|----------|--------------|---------------------|------------|-----------|
| LAN    | lan    | 117 | GPIOB[2] | LED_PORT0    | [1:0]               | LED_PORT0  | GPIOB2    |
| STATUS | status | 114 | GPIOB[3] | LED_PORT1    | [4:3]               | LED_PORT1  | GPIOB3    |

Default value at reset: **10b (Reserved)** — neither LED nor GPIO mode.
Software must explicitly write 00 (LED) or 11 (GPIO) after boot.

In the original firmware, both pads are set to 00 (ASIC LED mode).
Both LEDs share the same electrical characteristics and glow at the
same (fairly high) brightness.

## Original Lidl/Tuya firmware (Linux 3.10, vendor SDK)

The vendor BSP is based on Linux 3.10 but carries over several
drivers from the older 2.6.30 SDK (Ethernet, GPIO, ASIC layer).

Both LED pads (B2 and B3) are routed to the switch ASIC LED controller
by the SDK's ASIC L2 init (`rtl865x_asicL2.c` line 6041):

```c
REG32(PIN_MUX_SEL2) &= ~((3<<0) | (3<<3) | ...);
//                        ^^^^^^   ^^^^^^
//                        B2/LED0  B3/LED1  → both set to 0b00 = ASIC LED mode
```

A custom Tuya-specific kernel driver (`leds-rtl8196e.c` — not part of
the open Realtek SDK, source not available) exposed a procfs interface
for the STATUS LED:

    echo 1 > /proc/led1    # STATUS LED on
    echo 0 > /proc/led1    # STATUS LED off

This driver most likely controlled LED_PORT1 (B3) through the ASIC LED
controller registers rather than through GPIO, since the pin mux routes
B3 to the ASIC.  This is consistent with both LEDs having identical
brightness in the stock firmware.

### Switch ASIC LED controller

The RTL8196E switch core contains a dedicated LED controller at
register `LEDCREG` (0xBB804300).  During ASIC L2 init
(`rtl865x_asicL2.c`), the vendor code configures it as:

```c
REG32(PIN_MUX_SEL2) &= ~((3<<0) | (3<<3) | ...);  // pins → LED function
REG32(LEDCREG) = (2<<20) | 0;                       // LEDMODE_DIRECT, mode 0
```

- **`LEDMODE_DIRECT`** (bits 21-20 = 0b10): each LED pin is dedicated
  to one switch port — no scanning or multiplexing.
- **Mode 0 = Link / Activity**: the LED is **solidly ON** whenever the
  Ethernet link is up, and blinks off briefly during traffic.

Both pads (B2 for LAN, B3 for STATUS) are routed to the ASIC LED
controller via pin mux (`PIN_MUX_SEL2` bits set to 0b00).  The ASIC
drives the pins entirely in hardware with the same electrical
characteristics, which is why both LEDs glow at the **same high
brightness** — there is no GPIO toggling involved.

## Linux 5.10 port — the regression

When porting to Linux 5.10 with a clean device-tree based architecture,
the two LEDs were unified under the standard `gpio-leds` framework:

```dts
leds {
    compatible = "gpio-leds";
    status-led { gpios = <&gpio0 11 GPIO_ACTIVE_LOW>; };
};
```

This introduced two changes for the LAN LED (initially both LEDs were
declared as gpio-leds, but GPIO 10 has no effect on the LAN LED — see
"Hardware discovery" section below):

1. **Pin mux switched to GPIO mode.**  The GPIO driver
   (`gpio-rtl819x.c`) sets `PIN_MUX_SEL2` bits [1:0] to `0b11` when
   the pin is requested, disconnecting it from the ASIC LED controller.

2. **The `netdev` trigger replaced the ASIC controller.**  Instead of
   the hardware keeping the LED solidly ON with brief off-blinks, the
   software trigger does the opposite: the LED is **OFF by default**
   and flashes **briefly ON** for each TX/RX burst.

3. **`FULL_RST` in `rtl8196e_hw_init()` wipes `LEDCREG`.**  Even if
   the old ASIC driver had been compiled (it was not —
   `CONFIG_RTL819X` is disabled), the new Ethernet driver resets the
   entire switch core on `ndo_open`, clearing any prior LED register
   configuration.  No code re-programmes `LEDCREG` afterwards.

The net result: the LAN LED now has a **very low duty cycle** (~5 % ON)
and appears **visibly dim** compared to the STATUS LED — a clear
regression from the stock firmware where both LEDs matched.

Additionally, the `gpio-leds` driver only supports binary brightness
(0 or 1).  There is no way for users to adjust perceived brightness.

## The `leds-gpio-pwm` driver — rationale and design

### Goal

Provide user-adjustable brightness (0-255) for both LEDs, without
hardware PWM support (the RTL8196E has none), while keeping full
compatibility with standard LED triggers (`netdev`, `heartbeat`,
`default-on`, etc.).

### Approach

A platform driver (`compatible = "gpio-leds-pwm"`) that extends the
`gpio-leds` model with a **software PWM layer** based on `timer_list`:

- Each LED gets one kernel timer firing once per jiffy (250 Hz at HZ=250).
- PWM period = 4 jiffies → 62.5 Hz (above flicker threshold).
- `brightness_set(N)` adjusts the duty cycle to `N / 255`.
- At `N = 0` or `N = 255` the timer is stopped and the GPIO is held
  steady — no interrupt overhead when full-on or full-off.
- Existing triggers call `brightness_set()` as usual; the PWM layer is
  transparent.

Note: an earlier version used `hrtimer` at 1 kHz, but this caused LX bus
contention with UART during sustained Xmodem transfers (EFR32 flash).
The jiffies-based `timer_list` runs in softirq context and does not
interfere with UART interrupt handling.

### Requirements

- **`CONFIG_LEDS_GPIO_PWM=y`**: replaces `CONFIG_LEDS_GPIO`.

### CPU overhead

On the RLX4181 (Lexra MIPS) at ~400 MHz, one LED toggling at 250 Hz
produces 250 timer callbacks per second.  Each callback is a single
GPIO register read-modify-write (~65 cycles).  Total: **~0.004 % CPU**.

### User interface

Standard Linux LED sysfs for the STATUS LED (the LAN LED is controlled
via `led_mode`, not via this driver — see "Dual brightness mode" below):

```sh
# Set STATUS LED to dim (matches LAN LED scan mode)
echo 60 > /sys/class/leds/status/brightness

# Full brightness (no PWM overhead)
echo 255 > /sys/class/leds/status/brightness

# Triggers work unchanged
echo heartbeat > /sys/class/leds/status/trigger
```

### DTS example

```dts
leds {
    compatible = "gpio-leds-pwm";

    status-led {
        label = "status";
        gpios = <&gpio0 11 GPIO_ACTIVE_LOW>;
        default-state = "off";
    };

    /* LAN LED is hardwired to switch ASIC — see section below */
};
```

### Files

| File | Role |
|------|------|
| `leds-gpio-pwm.c`                  | Driver source                          |
| `LED-DESIGN-NOTES.md`              | This document                          |
| `patches/drivers-leds-Kconfig.patch`| Adds `CONFIG_LEDS_GPIO_PWM` to Kconfig |
| `patches/drivers-leds-Makefile.patch`| Adds build rule to Makefile           |

## LAN LED — hardwired to switch ASIC (hardware discovery)

### The problem

Despite the datasheet documenting GPIO B2 (pin 117) as a dual-function
pad switchable between LED_PORT0 and GPIOB2 via `PIN_MUX_SEL_2` bits
[1:0], **testing revealed that GPIO has no physical effect on the LAN
LED**.

Evidence:
- `PIN_MUX_SEL_2` set to `0b11` (GPIO mode) for bits [1:0] ✓
- `PABCD_CNR` bit 10 = 0 (GPIO function) ✓
- `PABCD_DIR` bit 10 = 1 (output) ✓
- `PABCD_DAT` bit 10 toggles correctly with `gpiod_set_value()` ✓
- Direct `devmem` writes to the DATA register also toggle bit 10 ✓
- **The physical LED does not change.**

Conversely, writing to `LEDCREG` (0xBB80_4300) immediately changes the
LAN LED behaviour:
- `LEDCREG = 0x0020_0000` (LEDMODE_DIRECT) → full brightness,
  link/activity
- `LEDCREG = 0x0000_0000` (scan mode) → dim blinking (~25 % of full)

The STATUS LED (GPIO B3) works correctly via GPIO in both GPIO and
ASIC LED modes.

### Conclusion

The LAN LED is physically connected to the switch ASIC's LED_PORT0
output, bypassing the pin mux.  This is likely a PCB design choice by
Tuya/Lidl.  Only `LEDCREG` controls it.

### DIRECTLCR register — true LED off

The `DIRECTLCR` register (0xBB80_4314, physical 0x1B80_4314) controls
the LED output scale in direct mode.  Its reset value is `0x1003FFFF`.

Setting `DIRECTLCR = 0` completely disables the LED output — no residual
glow, unlike scan mode which still produces ~25% perceived brightness.  Restoring
`DIRECTLCR = 0x1003FFFF` re-enables the LED.

This was discovered empirically (not documented in the SDK).  Bit 8
alone is sufficient to turn the LED off, but we write 0 for simplicity.

### LED modes (bright / dim / off)

The `S11leds` init script reads `/userdata/etc/leds.conf` and configures
both LEDs at boot:

```sh
echo MODE=off > /userdata/etc/leds.conf     # all LEDs off
echo MODE=dim > /userdata/etc/leds.conf     # reduced brightness
echo MODE=bright > /userdata/etc/leds.conf  # full brightness (default)
/userdata/etc/init.d/S11leds start
```

Internally, `S11leds` sets:
- **bright**: `DIRECTLCR = default`, `LEDCREG = LEDMODE_DIRECT`, STATUS PWM = 255
- **dim**: `DIRECTLCR = default`, `LEDCREG = 0` (scan mode), STATUS PWM = 60
- **off**: `DIRECTLCR = 0` (LAN LED fully off), STATUS PWM = 0

`serialgateway` and `S70otbr` read `/sys/class/net/eth0/led_mode` to
automatically set the correct STATUS LED brightness when turning it on.
When `led_mode = off`, the STATUS LED stays at 0.
