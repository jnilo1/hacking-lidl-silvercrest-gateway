# MEMO — OT-RCP UART Baudrate: 460800 vs 115200

**Date:** 2026-02-27
**Context:** Analysis of why 460800 baud fails on the Lidl Silvercrest gateway,
and what to try when hardware is available again.

---

## 1. Why 460800 matters

Two reasons to want 460800 instead of 115200:

1. **`universal-silabs-flasher` default probe sequence** only tries Spinel at
   460800 (`DEFAULT_PROBE_METHODS`). At 115200, the flasher fails to auto-detect
   the firmware and aborts. The workaround (`--probe-methods spinel:115200`) works
   but is non-standard and easy to forget.

2. **`otbr-posix`** (OpenThread Border Router) defaults to 460800 for its RCP
   serial connection. Running at 115200 requires an explicit config override.

The original SDK sample (`ot-rcp.slcp.sdk-original`) uses 460800 for both
reasons. We downgraded to 115200 after observing HDLC parsing errors.

---

## 2. What we ruled out

### 2.1 Baud rate generator accuracy

The RTL8196E UART peripheral clock is **200 MHz** (confirmed in device tree:
`clock-frequency = <200000000>` on `uart1`). This is independent of the CPU
clock (400 MHz); it is the reference fed to the 16550A divisor register.

Linux `uart_get_divisor()` computes: `(uartclk + 8×baud) / (16×baud)`

| Baudrate | Divisor | Actual Hz  | Error   |
|----------|---------|------------|---------|
| 115200   | 109     | 114,679    | −0.45 % |
| 460800   | 27      | 462,963    | +0.47 % |

Both are well within the UART standard tolerance of ±2 %. Clock accuracy is
**not** the cause of the HDLC errors.

### 2.2 Hardware flow control register

The RTL8196E UART has a proprietary flow-control gate at physical address
`0x18002110`, bit 29. The custom driver `8250_rtl819x.c` enables this bit and
mirrors it dynamically with the `CRTSCTS` termios flag. This mechanism is
confirmed working at 115200. Whether it is fast enough at 460800 is a separate
question (see section 3).

### 2.3 IRAM / D-MEM

Placing the IRQ handler in the tightly-coupled on-chip SRAM (I-MEM, 16 KB,
zero wait-state) would save ~50–80 cycles per interrupt. At 400 MHz that is
~200 ns — two orders of magnitude below the 217 µs budget we need. IRAM
addresses execution speed, not scheduling latency. It is not the right lever
here.

---

## 3. Root cause hypothesis: FIFO trigger + IRQ latency

### 3.1 The chain

```
EFR32 (TX @ 460800, HW flow)
    │
    │  22 µs/byte
    ▼
RTL8196E UART1 (16-byte FIFO, 16550A)
    │  IRQ → kernel handler → drain FIFO → reassert RTS
    ▼
serialgateway (userspace, select + read loop)
    │
    ▼
TCP socket → host
```

### 3.2 Current FIFO trigger configuration

In `8250_rtl819x.c`:

```c
uart.port.fifosize = 16;
uart.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_10;  // trigger at 8 bytes
```

In AFE mode (Automatic Flow Control Enable, MCR bit 5), the 16550A
automatically deasserts RTS when the RX FIFO reaches the trigger threshold.
RTS is reasserted when the FIFO drops below that threshold.

### 3.3 The timing budget

After RTS is deasserted (FIFO = 8 bytes), the EFR32 sees CTS fall and stops
transmitting — but it may already have 1–2 bytes in flight. The kernel IRQ
handler must drain the FIFO before those additional bytes cause an overflow.

| Trigger | IRQ/RTS fires after | Bytes in flight | Overflow margin | IRQ latency budget @ 460800 | IRQ latency budget @ 115200 |
|---------|--------------------|-----------------|-----------------|-----------------------------|------------------------------|
| 1 byte  | 22 µs              | 1–2             | 13 bytes        | **~283 µs**                 | ~1130 µs                     |
| 4 bytes | 87 µs              | 1–2             | 10 bytes        | **~217 µs**                 | ~868 µs                      |
| 8 bytes | 174 µs             | 1–2             | 6 bytes         | **~130 µs**                 | ~520 µs                      |
| 14 bytes| 304 µs             | 1–2             | 0 bytes         | **~0 µs**                   | ~174 µs                      |

*Overflow margin = 16 − trigger − 2 bytes in flight.
IRQ latency budget = overflow margin × (10 / baudrate).*

The RTL8196E running embedded Linux can easily incur 200–300 µs of interrupt
latency when the Ethernet driver, jffs2 GC, or another IRQ handler holds
interrupts disabled. At 460800 with the current trigger of 8 bytes, the budget
is only **130 µs** — borderline. At 115200 it is **520 µs** — comfortable.

This explains exactly why 115200 is stable and 460800 is not.

---

## 4. Proposed fix

Lower the RX FIFO trigger from 8 to 4 bytes in `8250_rtl819x.c`:

```c
// Before (current):
uart.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_10;  // 8 bytes

// After (proposed):
uart.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_01;  // 4 bytes
```

This raises the IRQ latency budget from 130 µs to **217 µs** at 460800 —
enough headroom to survive typical embedded Linux scheduling jitter.

**Cost:** IRQ frequency doubles (from ~5,760 to ~11,520 IRQs/s at full 460800
saturation). At 400 MHz with ~200 cycles/IRQ that is 0.3 % extra CPU load
in the absolute worst case. Zigbee/Thread traffic is bursty and far below
continuous saturation, so the practical cost is negligible.

**No impact on TCP throughput:** the number of bytes delivered per second is
unchanged; only the granularity at which the kernel picks them up differs.

---

## 5. Test plan (when hardware is available)

### Step 1 — Confirm the overrun hypothesis

On the gateway (with 460800 firmware loaded and serialgateway -b 460800):

```bash
# Watch UART overrun counters in real time
cat /proc/tty/driver/serial
# or, if sysfs is available:
cat /sys/class/tty/ttyS1/statistics 2>/dev/null
```

Look for the `oe` (Overrun Error) counter incrementing. If it does, the
hypothesis is confirmed.

Alternatively, read the Line Status Register directly:
```bash
# LSR bit 1 (OE) set = overrun
devmem 0xB8002115 8   # KSEG1 address of UART1 LSR (offset 0x14, reg-shift=2)
```

### Step 2 — Apply the trigger fix

In `3-Main-SoC-Realtek-RTL8196E/32-Kernel/linux-5.10.246-rtl8196e-eth/
drivers/tty/serial/8250/8250_rtl819x.c`, change:

```c
uart.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_10;
```
to:
```c
uart.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_01;
```

Rebuild the kernel and flash. Then test 460800 again.

### Step 3 — Validate with universal-silabs-flasher

If 460800 is stable, restore it as the OT-RCP firmware baudrate:

1. In `26-OT-RCP/patches/sl_uartdrv_usart_vcom_config.h`:
   `SL_UARTDRV_USART_VCOM_BAUDRATE 460800`

2. In `26-OT-RCP/patches/ot-rcp.slcp`:
   `SL_UARTDRV_USART_VCOM_BAUDRATE: 460800`

3. Rebuild firmware, flash, then verify that `universal-silabs-flasher` probes
   successfully **without** `--probe-methods spinel:115200`.

4. Verify `otbr-posix` connects without explicit baudrate override.

### Step 4 — If 460800 still fails after trigger change

The next suspect would be the hardware flow control gate (bit 29 @ 0x18002110)
reacting too slowly. Test by removing HW flow control entirely (both sides)
and checking if 460800 becomes stable — if yes, the issue is in the RTS/CTS
signal path, not the FIFO.

---

## 6. Files to modify

| File | Change |
|------|--------|
| `32-Kernel/.../8250_rtl819x.c` | `UART_FCR_R_TRIG_10` → `UART_FCR_R_TRIG_01` |
| `26-OT-RCP/patches/sl_uartdrv_usart_vcom_config.h` | baudrate 115200 → 460800 (after validation) |
| `26-OT-RCP/patches/ot-rcp.slcp` | baudrate 115200 → 460800 (after validation) |
| `26-OT-RCP/README.md` | update baudrate, remove `--probe-methods` workaround note |

---

## 7. Current workaround (status quo)

Firmware stays at **115200**. Flash with:

```bash
universal-silabs-flasher \
    --device socket://192.168.1.X:8888 \
    --probe-methods spinel:115200 \
    flash --firmware firmware/ot-rcp.gbl
```

And launch serialgateway normally (115200 is the default, no `-b` flag needed).

---

## 8. Spinel bootloader entry — FIXED (2026-03-01)

### Symptom (before fix)

When OT-RCP firmware was running on the EFR32, `universal-silabs-flasher` could
not flash a different firmware. It detected `SPINEL` successfully but then failed
with `FailedToEnterBootloaderError`.

### Root cause

The Spinel `CMD_RESET(BOOTLOADER)` handler in `ncp_base.cpp` (line 1322) is
behind `#if OPENTHREAD_CONFIG_PLATFORM_BOOTLOADER_MODE_ENABLE`. This config is
set in `openthread-core-efr32-config.h` based on whether
`SL_CATALOG_GECKO_BOOTLOADER_INTERFACE_PRESENT` is defined. However,
`sl_component_catalog.h` (which defines that macro) is only `#include`d from
`main.c` — it is **never included** when compiling `ncp_base.cpp`. So the macro
was undefined, the config evaluated to **0**, and the bootloader reset code was
compiled out.

Evidence from the linker map before the fix:
- `otPlatResetToBootloader` (misc.o) — garbage-collected (no linked address)
- `bootloader_rebootAndInstall` (btl_interface.o) — garbage-collected
- `CommandHandler_RESET` — linked, but the bootloader branch was compiled out

### Fix

Added `-DOPENTHREAD_CONFIG_PLATFORM_BOOTLOADER_MODE_ENABLE=1` to `C_DEFS` in
`build_ot_rcp.sh`. This directly enables the config flag at compile time,
bypassing the broken `SL_CATALOG` check. This is safe because
`bootloader_interface` IS in the `.slcp` component list and `btl_interface.o`
IS compiled — only the config gate was broken.

### Verification

After rebuild, `otPlatResetToBootloader` and `bootloader_rebootAndInstall`
should have non-zero linked addresses in the `.map` file (not garbage-collected).
`universal-silabs-flasher` should be able to enter the Gecko Bootloader from
OT-RCP via Spinel `CMD_RESET(RESET_BOOTLOADER)`.
