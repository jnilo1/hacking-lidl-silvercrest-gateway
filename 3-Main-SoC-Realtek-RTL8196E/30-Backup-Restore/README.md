# Backup & Restore — Flash Memory (GD25Q128C, 16 MiB)

The gateway's GD25Q128C SPI flash stores the bootloader, kernel, rootfs, and userdata. This guide covers three backup/restore methods depending on your situation.

> **Warning:** Flashing can permanently damage the device. Always verify your backups before modifying anything.

## Which method?

| Method | When to use | Requirements |
|--------|-------------|--------------|
| **1. SSH** (`backup_gateway.sh`) | Gateway boots into Linux | Ethernet + SSH access |
| **2. Bootloader** (FLR/FLW) | Linux is broken, or preventive backup | Serial console + TFTP |
| **3. SPI programmer** | Bootloader is corrupted | Desolder flash chip |

**Method 1 is recommended** — it works with both custom firmware (SSH:22) and original Tuya firmware (SSH:2333).

---

## Method 1 — SSH backup via `backup_gateway.sh`

The unified script at the repository root auto-detects the firmware type and dumps all partitions via SSH:

```sh
./backup_gateway.sh                                    # auto-detect everything
./backup_gateway.sh --linux-ip 192.168.1.71            # different gateway IP
./backup_gateway.sh --output /tmp/my-backup            # custom output directory
```

Output: `backups/YYYYMMDD-HHMM/` containing `fullflash.bin`, individual `mtdX_name.bin` files, and `backup.log`.

To restore a backup, use `restore_gateway.sh` (guides through TFTP upload + FLW).

---

## Method 2 — Bootloader (FLR + TFTP)

Use this when Linux doesn't boot. Requires a serial console (3.3V UART, 38400 8N1).

### Entering bootloader mode

**From Linux (SSH):**
```sh
ssh root@192.168.1.88 boothold
```

**From serial console:** power on the gateway and press **ESC** repeatedly until the `<RealTek>` prompt appears.

### Full flash backup

On the serial console, read the entire flash (16 MiB) into RAM:
```
RealTek>FLR 80500000 00000000 01000000
(Y)es , (N)o ? --> Y
Flash Read Succeeded!
```

Then download it from your host:
```sh
tftp -m binary 192.168.1.6 -c get fullflash.bin
```

The file must be exactly **16,777,216 bytes**. Verify with `md5sum fullflash.bin`.

### Full flash restore

Upload the image from your host:
```sh
tftp -m binary 192.168.1.6 -c put fullflash.bin
```

Write it to flash (overwrites everything):
```
RealTek>FLW 00000000 80500000 01000000
```

### Per-partition backup/restore

`FLR` reads flash into RAM, `FLW` writes RAM to flash:
```
FLR <ram_addr> <flash_offset> <size>
FLW <flash_offset> <ram_addr> <size>
```

**Custom firmware (4 partitions):**

| MTD | Description | FLR | FLW |
|-----|-------------|-----|-----|
| mtd0 | Bootloader + Config | `FLR 80500000 00000000 00020000` | `FLW 00000000 80500000 00020000` |
| mtd1 | Kernel | `FLR 80500000 00020000 001E0000` | `FLW 00020000 80500000 001E0000` |
| mtd2 | Rootfs | `FLR 80500000 00200000 00200000` | `FLW 00200000 80500000 00200000` |
| mtd3 | JFFS2 Userdata | `FLR 80500000 00400000 00C00000` | `FLW 00400000 80500000 00C00000` |

**Original Lidl/Tuya firmware (5 partitions):**

| MTD | Description | FLR | FLW |
|-----|-------------|-----|-----|
| mtd0 | Bootloader + Config | `FLR 80500000 00000000 00020000` | `FLW 00000000 80500000 00020000` |
| mtd1 | Kernel | `FLR 80500000 00020000 001E0000` | `FLW 00020000 80500000 001E0000` |
| mtd2 | Rootfs | `FLR 80500000 00200000 00200000` | `FLW 00200000 80500000 00200000` |
| mtd3 | Tuya Label | `FLR 80500000 00400000 00020000` | `FLW 00400000 80500000 00020000` |
| mtd4 | JFFS2 Overlay | `FLR 80500000 00420000 00BE0000` | `FLW 00420000 80500000 00BE0000` |

For each partition: FLR to read into RAM, then `tftp get` to download. To restore: `tftp put`, then FLW.

---

## Method 3 — SPI programmer (CH341A)

Use this only if the bootloader is corrupted and the gateway is completely unresponsive. Requires **desoldering** the SPI flash chip.

### Hardware

- CH341A USB SPI programmer (use the 25xx entry)
- SOP8 to 200 mil DIP adapter
- Flux and desoldering braid or pump

<p align="center">
  <img src="./media/image1.jpeg" alt="CH341A programmer" width="50%">
</p>

> A programming clip does **not** work on this board.

### Detect the chip

```sh
flashrom -p ch341a_spi -c GD25Q128C
```

Expected output:
```
Found GigaDevice flash chip "GD25Q128C" (16384 kB, SPI) on ch341a_spi.
No operations were specified.
```

If the chip is not detected, check your connections and install the latest version from [flashrom.org](https://www.flashrom.org/).

### Read (backup)

```sh
flashrom -p ch341a_spi -c GD25Q128C -r fullflash.bin
```

### Write (restore)

```sh
flashrom -p ch341a_spi -c GD25Q128C -w fullflash.bin
```

Ensure `fullflash.bin` is exactly 16 MiB. The operation takes a few minutes.

---

## Scripts

| Script | Description |
|--------|-------------|
| `../../backup_gateway.sh` | Unified backup — auto-detects gateway state, dumps all partitions via SSH |
| `../../restore_gateway.sh` | Restore a fullflash.bin — guides through LOADADDR + FLW |
| `split_flash.sh` | Split a 16 MiB backup into individual partition files |
| `scripts/restore_mtd_via_ssh.sh` | Restore partitions via SSH (original firmware only) |

### split_flash.sh

```sh
./split_flash.sh fullflash.bin              # custom firmware (4 partitions, default)
./split_flash.sh fullflash.bin lidl         # original Lidl/Tuya (5 partitions)
```

Creates `mtd0_boot+cfg.bin`, `mtd1_kernel.bin`, `mtd2_rootfs.bin`, etc. next to the input file.
