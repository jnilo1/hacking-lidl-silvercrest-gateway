# LED management on the Silvercrest/Lidl Zigbee gateway (RTL8196E)

## Hardware

The gateway has two front-panel LEDs, active-low, wired to RTL8196E
pad B3 and B2 respectively:

| LED      | Label   | Pad | Function (original firmware)       | Driven by          |
|----------|---------|-----|------------------------------------|---------------------|
| STATUS   | status  | B3  | System / WPS indicator             | CPU via GPIO        |
| LAN      | lan     | B2  | Ethernet link & activity           | Switch ASIC LED controller |

Pin B2 is a **dual-function pad**: it can be routed to either the GPIO
controller or the switch ASIC LED controller, depending on `PIN_MUX_SEL2`
bits [1:0] (0b00 = ASIC LED, 0b11 = GPIO).  In the original firmware it
is **not** used as a GPIO — it is driven entirely by the ASIC hardware.

Both LEDs share the same electrical characteristics and, on the stock
firmware, glow at the same (fairly high) brightness.

## Original Lidl/Tuya firmware (Linux 3.10, vendor SDK)

The vendor BSP is based on Linux 3.10 but carries over several
drivers from the older 2.6.30 SDK (Ethernet, GPIO, ASIC layer).

Both LEDs are managed through the switch ASIC LED controller, configured
in `LEDMODE_DIRECT` mode 0 (Link / Activity).  A custom kernel driver
(`leds-rtl8196e.c`) exposes a procfs interface:

    echo 1 > /proc/led1    # STATUS LED on
    echo 0 > /proc/led1    # STATUS LED off

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
    lan-led    { gpios = <&gpio0 10 GPIO_ACTIVE_LOW>;
                 linux,default-trigger = "netdev"; };
};
```

This introduced two changes for the LAN LED:

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
`gpio-leds` model with a **software PWM layer** based on `hrtimer`:

- Each LED gets one hrtimer running at ~1 kHz (period = 1 ms).
- `brightness_set(N)` adjusts the duty cycle to `N / 255`.
- At `N = 0` or `N = 255` the timer is stopped and the GPIO is held
  steady — no interrupt overhead when full-on or full-off.
- Existing triggers call `brightness_set()` as usual; the PWM layer is
  transparent.

### Requirements

- **`CONFIG_HIGH_RES_TIMERS=y`**: needed for sub-millisecond hrtimer
  precision.  The RTL8196E timer hardware already supports one-shot
  mode (`CLOCK_EVT_FEAT_ONESHOT` in `timer-rtl819x.c`), so enabling
  this option is safe.
- **`CONFIG_LEDS_GPIO_PWM=y`**: replaces `CONFIG_LEDS_GPIO`.

### CPU overhead

On the RLX4181 (Lexra MIPS) at ~400 MHz, two LEDs toggling at 1 kHz
produce 2000 hrtimer interrupts per second.  Each interrupt is a single
GPIO register read-modify-write (~65 cycles).  Total: **~0.03 % CPU**.

### User interface

Standard Linux LED sysfs — no custom tooling required:

```sh
# Set LAN LED to 25 % brightness
echo 64 > /sys/class/leds/lan/brightness

# Set STATUS LED to 25 % (matching LAN)
echo 64 > /sys/class/leds/status/brightness

# Full brightness (no PWM overhead)
echo 255 > /sys/class/leds/status/brightness

# Triggers work unchanged
echo netdev > /sys/class/leds/lan/trigger
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

    lan-led {
        label = "lan";
        gpios = <&gpio0 10 GPIO_ACTIVE_LOW>;
        default-state = "off";
        linux,default-trigger = "netdev";
    };
};
```

### Files

| File | Role |
|------|------|
| `leds-gpio-pwm.c`                  | Driver source                          |
| `LED-DESIGN-NOTES.md`              | This document                          |
| `patches/drivers-leds-Kconfig.patch`| Adds `CONFIG_LEDS_GPIO_PWM` to Kconfig |
| `patches/drivers-leds-Makefile.patch`| Adds build rule to Makefile           |
