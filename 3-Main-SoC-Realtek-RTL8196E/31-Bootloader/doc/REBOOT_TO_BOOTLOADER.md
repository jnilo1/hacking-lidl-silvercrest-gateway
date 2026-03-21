# Reboot-to-bootloader: enter `<RealTek>` prompt from Linux

## Overview

A single command from Linux SSH reboots the gateway into the `<RealTek>`
bootloader prompt, ready for TFTP firmware updates — no need to press
ESC on the serial console.

```sh
devmem 0x003FFFFC 32 0x484F4C44 && reboot
```

The flag is **one-shot**: the bootloader clears it before entering
download mode, so the next reboot boots Linux normally.

---

## How it works

The mechanism uses a **magic word in DRAM** that survives the
watchdog reset triggered by `reboot`.  No flash writes are involved.

1. Linux writes `0x484F4C44` ("HOLD") to physical address `0x003FFFFC`
   via `/dev/mem`.
2. Linux triggers `reboot`, which causes a watchdog reset.
3. The CPU restarts at `BFC00000` (flash reset vector).  The btcode
   re-initialises the DDR controller, but DRAM cell contents survive
   because the DDR2 retention time (~64-256 ms) exceeds the re-init
   delay (~1-2 ms).
4. The stage-2 bootloader checks `0x803FFFFC` (kseg0 cached alias of
   physical `0x003FFFFC`) for the magic word.
5. If it matches, the bootloader **clears it** and enters
   download mode (`goToDownMode()`).
6. If it doesn't match (normal boot, cold power-on), the bootloader
   proceeds to load and boot the kernel as usual.

A full power cycle (disconnect all cables) clears DRAM and restores
normal boot.

### Boot flow with boot-hold

```
setClkInitConsole()
initHeap()
initInterrupt()
initFlash()
showBoardInfo()
                    ← check BOOTHOLD_RAM[0]
                       if match → clear, goToDownMode(), return
check_image()
doBooting()
```

---

## DRAM address selection

### Why 0x003FFFFC with reserved-memory

Physical `0x003FFFFC` is safe from all btcode early-boot code (DDR
calibration, decompressor, TFTP).  However, the kernel's page allocator
normally uses this page — writing through KSEG0 (cached) overwrites any
value written by `devmem` through KSEG1 (uncached), a classic
KSEG0/KSEG1 cache coherency conflict.

The fix: the device tree declares this page as `reserved-memory` with
`no-map`.  The kernel never allocates it — no cache lines, no conflict.
`devmem` writes persist reliably.

**Top of DRAM (`0x01FFFFFC`) is NOT safe**: the btcode initialises the
stack pointer at the top of RAM (`0x82000000`) and pushes data starting
at `0x81FFFFFC` during DDR calibration — producing false positives on
every boot, including cold power-on.

### Address safety

| Region                          | Address range              | Status    |
|---------------------------------|----------------------------|-----------|
| Exception vectors               | `0x80000000 - 0x800001FF` | Avoid     |
| DDR calibration (`DDR_cali_API7`, `Calc_TRxDly`) | `0xA0080000`, `0xA0100000` | Avoid |
| DDR size detection (`Calc_Dram_Size`) | `0xA0000000`, power-of-2 offsets up to `0xA4000000` | Avoid |
| Stage-1.5 (piggy)              | `0x80100000+`              | Avoid     |
| LZMA workspace                  | `0x80300000`               | Avoid     |
| **Boot-hold flag**              | **`0x803FFFFC`**           | **Used**  |
| Stage-2 code/data/BSS           | `0x80400000 - 0x80422000` | Avoid     |
| TFTP load area                  | `0x80500000 - 0x81500000` | Avoid     |
| btcode stack (grows down)       | `0x81FFFFFC` and below     | Avoid     |

---

## Bootloader implementation

In `boot/main.c`, at file scope:

```c
#define BOOTHOLD_MAGIC  0x484F4C44  /* "HOLD" */
#define BOOTHOLD_RAM    ((volatile unsigned long *)0x803FFFFC)
```

In `start_kernel()`, after `showBoardInfo()`:

```c
if (BOOTHOLD_RAM[0] == BOOTHOLD_MAGIC) {
    BOOTHOLD_RAM[0] = 0;
    prom_printf("---Boot hold requested\n");
    goToDownMode();
    return;
}
```

---

## Kernel device tree reservation

In `rtl8196e.dts`:

```dts
memory@0 {
    device_type = "memory";
    reg = <0x00000000 0x02000000>;  /* 32MB */
};

reserved-memory {
    #address-cells = <1>;
    #size-cells = <1>;
    ranges;

    boothold@3ff000 {
        reg = <0x003FF000 0x1000>;  /* 4KB reserved for boothold flag */
        no-map;
    };
};
```

The `no-map` property removes this page from `memblock` before the page
allocator starts — no runtime cost, no exception handling.  On MIPS,
KSEG0/KSEG1 are hardware-mapped (no TLB), so `/dev/mem` access still
works.  The 4 KB cost (0.01% of 32 MB) is negligible.

---

## Linux-side usage

### With devmem (BusyBox applet)

```sh
devmem 0x003FFFFC 32 0x484F4C44 && reboot
```

Or use the `boothold` script installed in `/userdata/usr/bin/`.

### With /dev/mem (fallback)

```sh
printf 'HOLD' | dd of=/dev/mem bs=1 seek=$((0x3FFFFC)) conv=notrunc 2>/dev/null
sync && reboot
```

---

## Experimental results

Tested on the Lidl Silvercrest gateway (RTL8196E, 32 MB DDR2):

| Test | Result |
|------|--------|
| DRAM retention across watchdog reset | **Survives** — magic at `0x803FFFFC` preserved after reset |
| Boot-hold from Linux SSH (`devmem` + `reboot`) | **Works** — bootloader prints `---Boot hold requested` and enters `<RealTek>` prompt |
| Value persistence (kernel running) | **Works** — page excluded from allocator via reserved-memory no-map |
| One-shot behavior (subsequent reboot) | **Works** — flag is cleared, Linux boots normally |
| Full power cycle (disconnect all cables) | **Flag cleared** — DRAM lost, normal boot |

---

## Design alternatives considered

### Top of DRAM (0x01FFFFFC)

Attempted: reduce DT memory size by 4 KB to exclude the last page.
Failed: the btcode stack starts at top of RAM and writes data there
during DDR calibration on every boot (including cold power-on),
producing false HOLD detections.

### Flash-based flag

Write a 4-byte magic to flash offset `0x1FFF0` (last sector of mtd0).
The bootloader reads it, clears it via sector read-modify-write, and
enters download mode.  This is guaranteed to work regardless of DRAM
retention but causes one flash erase+write cycle per use.

Not implemented — DRAM approach works reliably on this hardware and
avoids flash wear entirely.
