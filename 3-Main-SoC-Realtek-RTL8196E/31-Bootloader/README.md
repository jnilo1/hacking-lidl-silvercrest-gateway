# Open-Source Bootloader for RTL8196E

Replacement bootloader for the Lidl Silvercrest Zigbee gateway (RTL8196E SoC).

## Why use this bootloader

This is the **last missing piece** that makes the entire gateway firmware stack fully open-source — from bootloader to kernel, rootfs, and Zigbee radio firmware.

**Modern toolchain** — Built with GCC 8.5 / musl (crosstool-NG), replacing the legacy Realtek RSDK (GCC 4.6). The code has been simplified and made portable to standard toolchains.

**Clean boot header** — The stock bootloader prints verbose, cluttered output. This version shows only what matters:

```
Realtek RTL8196E  CPU: 400MHz  RAM: 32MB  Flash: GD25Q128
Bootloader: V2.2 - 2026.02.10-18:30+0100 - J. Nilo
```

**Download progress in %** — The stock bootloader prints endless `.` or `#` characters that flood the serial console during TFTP transfers. This version shows a clean percentage indicator:

```
Flashing: 76%
```

**Reboot to bootloader from Linux** — No need to press ESC on the serial console. A single command from Linux SSH writes a magic flag to RAM and reboots; the bootloader detects it and stops at the `<RealTek>` prompt, ready for TFTP. See [Reboot to Bootloader](doc/REBOOT_TO_BOOTLOADER.md) for details.

**Risk-free testing** — The build generates a `test.bin` image that runs entirely from RAM without touching flash. Load it via TFTP, jump to it, and test your bootloader changes live — no risk of bricking. See the [Testing Guide](doc/TESTING.md) for the full workflow.

## Building

```bash
./build_bootloader.sh          # build all variants
./build_bootloader.sh clean    # clean
```

Outputs:
- `boot.bin` — flash image (stays in download mode after boot-code flash)
- `btcode/build/test.bin` — RAM-test image (test without flashing)

## Flashing

### Prerequisites

- Serial adapter connected (38400 8N1)
- Ethernet cable between PC and gateway
- PC on `192.168.1.x` (e.g. `192.168.1.1`)

### Step 1 — Enter download mode

**From Linux (recommended):**

```bash
devmem 0x003FFFFC 32 0x484F4C44 && reboot
```

The gateway reboots and stops at the `<RealTek>` prompt automatically. The flag is one-shot — the next reboot will boot Linux normally.

**From serial console:**

Power on the gateway and press **ESC** repeatedly until the `<RealTek>` prompt appears.

### Step 2 — Send the bootloader via TFTP

```bash
tftp -m binary 192.168.1.6 -c put boot.bin
```

The bootloader auto-detects the image type and flashes it. After flashing, reboot manually:
```
<RealTek>J BFC00000
```

### Flashing kernel, rootfs, or userdata

Same workflow — just send the image with the right Realtek header:

```bash
tftp -m binary 192.168.1.6 -c put rootfs.bin     Will not reboot
tftp -m binary 192.168.1.6 -c put userdata.bin   Will not reboot
tftp -m binary 192.168.1.6 -c put kernel.img     Will reboot
```

The bootloader identifies each image by its header signature and writes it to the correct flash partition.

## Safety

- **Never flash mtd0** without a backup and SPI programmer on hand
- The bootloader is the only recovery path if the device bricks (short of desoldering the flash chip)
- Always verify TFTP transfers completed before rebooting
- Use `test.bin` for testing — it runs from RAM without touching flash

## Documentation

| Document | Contents |
|----------|----------|
| [Command Reference](doc/COMMANDS.md) | All bootloader console commands (memory, TFTP, flash, PHY) |
| [Technical Memo](doc/MEMO_BOOTLOADER.md) | Architecture, boot process, image format, flash layout, build system |
| [Toolchain Notes](doc/BOOTLOADER_TOOLCHAIN_NOTES.md) | Porting post-mortem: RSDK to GCC 8.5 / musl |
| [Testing Guide](doc/TESTING.md) | RAM-test workflow, command validation checklist |
| [Reboot to Bootloader](doc/REBOOT_TO_BOOTLOADER.md) | Enter `<RealTek>` prompt from Linux without pressing ESC |
| [Reset Vector Audit](doc/RESET_VECTOR_AUDIT.md) | Stage-1 DDR init analysis |
