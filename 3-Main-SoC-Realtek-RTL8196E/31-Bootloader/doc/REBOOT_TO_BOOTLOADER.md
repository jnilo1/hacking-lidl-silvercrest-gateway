# Reboot-to-bootloader: enter `<RealTek>` prompt from Linux

## Overview

A single command from Linux SSH reboots the gateway into the `<RealTek>`
bootloader prompt, ready for TFTP firmware updates — no need to press
ESC on the serial console.

```sh
devmem 0x00050000 32 0x484F4C44 && devmem 0x00050004 32 0xB007C0DE && reboot
```

The flag is **one-shot**: the bootloader clears it before entering
download mode, so the next reboot boots Linux normally.

---

## How it works

The mechanism uses a **two-word magic in DRAM** that survives the
watchdog reset triggered by `reboot`.  No flash writes are involved.

1. Linux writes `0x484F4C44` ("HOLD") to physical address `0x00050000`
   and `0xB007C0DE` to `0x00050004` via `/dev/mem`.
2. Linux triggers `reboot`, which causes a watchdog reset.
3. The CPU restarts at `BFC00000` (flash reset vector).  The btcode
   re-initialises the DDR controller, but DRAM cell contents survive
   because the DDR2 retention time (~64-256 ms) exceeds the re-init
   delay (~1-2 ms).
4. The stage-2 bootloader checks `0x80050000` (kseg0 cached alias of
   physical `0x00050000`) for the two-word magic.
5. If both words match, the bootloader **clears them** and enters
   download mode (`goToDownMode()`).
6. If they don't match (normal boot, cold power-on), the bootloader
   proceeds to load and boot the kernel as usual.

Two words (64 bits) are checked to eliminate false positives from stale
DRAM data, which was observed to survive even brief power interruptions
on this hardware.

### Boot flow with boot-hold

```
setClkInitConsole()
initHeap()
initInterrupt()
initFlash()
showBoardInfo()
                    ← NEW: check BOOTHOLD_RAM[0..1]
                       if match → clear, goToDownMode(), return
check_image()
doBooting()
```

---

## DRAM address selection

Address `0x80050000` (physical `0x00050000`) was chosen because it is
not touched by any code that runs before the boot-hold check:

| Region                          | Address range              | Status    |
|---------------------------------|----------------------------|-----------|
| Exception vectors               | `0x80000000 - 0x800001FF` | Avoid     |
| **Boot-hold flag**              | **`0x80050000 - 0x80050007`** | **Used** |
| DDR calibration (`DDR_cali_API7`, `Calc_TRxDly`) | `0xA0080000`, `0xA0100000` | Avoid |
| DDR size detection (`Calc_Dram_Size`) | `0xA0000000`, power-of-2 offsets | Avoid |
| Stage-2 code/data/BSS           | `0x80400000 - 0x80422000` | Avoid     |
| TFTP load area                  | `0x80500000+`             | Avoid     |

---

## Bootloader implementation

In `boot/main.c`, at file scope:

```c
#define BOOTHOLD_MAGIC0 0x484F4C44  /* "HOLD" */
#define BOOTHOLD_MAGIC1 0xB007C0DE  /* second guard word */
#define BOOTHOLD_RAM    ((volatile unsigned long *)0x80050000)
```

In `start_kernel()`, after `showBoardInfo()`:

```c
if (BOOTHOLD_RAM[0] == BOOTHOLD_MAGIC0 &&
    BOOTHOLD_RAM[1] == BOOTHOLD_MAGIC1) {
    BOOTHOLD_RAM[0] = 0;
    BOOTHOLD_RAM[1] = 0;
    prom_printf("---Boot hold requested\n");
    goToDownMode();
    return;
}
```

---

## Linux-side usage

### With devmem (BusyBox applet)

```sh
devmem 0x00050000 32 0x484F4C44 && devmem 0x00050004 32 0xB007C0DE && reboot
```

### With /dev/mem (fallback)

```sh
printf 'HOLD' | dd of=/dev/mem bs=1 seek=$((0x50000)) conv=notrunc 2>/dev/null
printf '\xB0\x07\xC0\xDE' | dd of=/dev/mem bs=1 seek=$((0x50004)) conv=notrunc 2>/dev/null
sync && reboot
```

---

## Experimental results

Tested on the Lidl Silvercrest gateway (RTL8196E, 32 MB DDR2):

| Test | Result |
|------|--------|
| DRAM retention across watchdog reset | **Survives** — `DEADBEEF` at `0x80050000` preserved after `J BFC00000` |
| Boot-hold from Linux SSH (`devmem` + `reboot`) | **Works** — bootloader prints `---Boot hold requested` and enters `<RealTek>` prompt |
| One-shot behavior (subsequent reboot) | **Works** — flag is cleared, Linux boots normally |
| Full power cycle (disconnect all cables) | **Flag cleared** — DRAM lost, normal boot |
| Brief power glitch (disconnect only 3.3V, GND+TX+RX still connected) | **Flag may survive** — back-feeding through serial pins keeps DDR2 alive; this is a non-issue in practice |

---

## Design alternatives considered

### Flash-based flag (approach B)

Write a 4-byte magic to flash offset `0x1FFF0` (last sector of mtd0).
The bootloader reads it, clears it via sector read-modify-write, and
enters download mode.  This is guaranteed to work regardless of DRAM
retention but causes one flash erase+write cycle per use.

Not implemented — DRAM approach works reliably on this hardware and
avoids flash wear entirely.  Could be added as a fallback if needed
(see git history for the design notes).
