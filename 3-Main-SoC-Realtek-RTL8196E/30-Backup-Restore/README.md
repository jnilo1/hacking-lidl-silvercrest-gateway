# Backup and Restore the 16 MiB Flash

The RTL8196E SPI NOR stores the Realtek bootloader, Linux kernel, root
filesystem, and persistent data. A complete 16 MiB backup is the recovery point
for a failed install and the only way to return exactly to a device's original
vendor state.

Make a backup before the first flash, before a board/kernel experiment, and
before a manual partition update. Store it outside the repository and do not
publish it: vendor data, identifiers, credentials, or network configuration may
be present.

## Choose a method

| Gateway state | Method | Writes to gateway? | Requirements |
| --- | --- | --- | --- |
| Linux running with known root credentials | [`backup_gateway.sh`](#method-1--backup-over-ssh) | No | Ethernet + SSH |
| Linux credentials unavailable, bootloader works | [Bootloader `FLR`](#method-2--bootloader-flr--tftp) | No | UART + same-L2 TFTP |
| Bootloader corrupted or flash chip inaccessible in circuit | [External SPI programmer](#method-3--external-spi-programmer) | Read is safe; restore writes | Desoldering and SPI tools |

For a stock Tuya image, the SSH service is normally on port 2333; using it still
requires valid root credentials. If those credentials are unavailable, use the
serial bootloader read before installing the replacement firmware.

## Verify every backup

A full image must be exactly 16,777,216 bytes:

```bash
stat -c '%n %s bytes' fullflash.bin
sha256sum fullflash.bin
```

Keep the hash next to the backup. Prefer two independent storage locations.
Do not treat a set of zero-byte or short partition files as a successful backup
merely because the script created a directory.

## Method 1 — Backup over SSH

The repository-root script detects this project's SSH service on port 22 or the
stock Tuya service on port 2333, reads every MTD partition, verifies its size,
and concatenates a full image.

```bash
./backup_gateway.sh --linux-ip <gateway-ip> \
  --output /path/outside/the/repository/gateway-backup
```

If the gateway uses the usual project address:

```bash
./backup_gateway.sh --linux-ip 192.168.1.88 \
  --output /srv/backups/rtl8196e-before-upgrade
```

The output contains:

```text
fullflash.bin
mtd0_<name>.bin
mtd1_<name>.bin
...
backup.log
```

The script asks for SSH authentication as needed. It is read-only with respect
to the gateway. Review `backup.log`, confirm every partition reports `[OK]`, and
verify the full image size and hash.

## Method 2 — Bootloader `FLR` + TFTP

Use this before a first install when stock SSH credentials are unavailable, or
when Linux no longer boots. It requires the RTL8196E serial console at 38400
8N1 and a computer on the same L2 subnet as the bootloader.

### Enter the bootloader

From a running custom system:

```bash
ssh root@<gateway-ip> 'boothold 192.168.1.6 && reboot'
```

From stock firmware or a broken Linux system, open the serial console, apply
power, and press `Esc` repeatedly until `<RealTek>` appears. See the
[hardware/UART instructions](../../docs/getting-started.md#6-open-the-gateway-and-connect-the-serial-console).

The default bootloader TFTP address is `192.168.1.6`. On another subnet, use
`IPCONFIG <address>` at the prompt or pass a supported address to a V2.7+
`boothold` command.

### Read the complete flash

At the serial prompt, copy all 16 MiB from flash to RAM:

```text
RealTek> FLR 80500000 00000000 01000000
(Y)es , (N)o ? --> Y
Flash Read Succeeded!
```

On the computer, download that RAM buffer from the bootloader TFTP server:

```bash
tftp -m binary 192.168.1.6 -c get fullflash.bin
```

Verify the exact size and hash before leaving the bootloader or running an
install. `FLR` reads only; it does not change flash.

### Restore a complete image

Restoring overwrites every byte of the device flash. Resolve the exact backup
path, board, and file size before continuing.

Upload the image to RAM:

```bash
tftp -m binary 192.168.1.6 -c put fullflash.bin
```

Then write RAM to flash at the serial prompt:

```text
RealTek> FLW 00000000 80500000 01000000
```

Do not interrupt power during `FLW`. The repository-root
`restore_gateway.sh` provides the same guided full-image workflow and performs
host-side checks before the write.

### Partition-level commands

`FLR` and `FLW` use this form:

```text
FLR <ram-address> <flash-offset> <size>
FLW <flash-offset> <ram-address> <size>
```

Current custom layout:

| MTD | Offset / size | `FLR` | `FLW` |
| --- | --- | --- | --- |
| boot + config | `0x000000` / `0x020000` | `FLR 80500000 00000000 00020000` | `FLW 00000000 80500000 00020000` |
| kernel | `0x020000` / `0x1E0000` | `FLR 80500000 00020000 001E0000` | `FLW 00020000 80500000 001E0000` |
| rootfs | `0x200000` / `0x200000` | `FLR 80500000 00200000 00200000` | `FLW 00200000 80500000 00200000` |
| userdata | `0x400000` / `0xC00000` | `FLR 80500000 00400000 00C00000` | `FLW 00400000 80500000 00C00000` |

Original Lidl/Tuya layout:

| MTD | Offset / size | Purpose |
| --- | --- | --- |
| mtd0 | `0x000000` / `0x020000` | Bootloader + config |
| mtd1 | `0x020000` / `0x1E0000` | Kernel |
| mtd2 | `0x200000` / `0x200000` | Rootfs |
| mtd3 | `0x400000` / `0x020000` | Tuya label |
| mtd4 | `0x420000` / `0xBE0000` | JFFS2 overlay |

Prefer a complete full-flash backup. Partition-level restores are for users who
understand the active layout and image headers.

## Method 3 — External SPI programmer

Use an external programmer only if the Realtek bootloader cannot read/write the
flash. On this board, an in-circuit SOP8 clip does not work reliably; the flash
chip must be desoldered.

Required equipment:

- CH341A-compatible SPI programmer configured for 25xx flash;
- SOP8-to-DIP adapter for the package width;
- appropriate soldering, flux, and ESD tools.

Detect the chip:

```bash
flashrom -p ch341a_spi -c GD25Q128C
```

Read it at least twice and compare hashes:

```bash
flashrom -p ch341a_spi -c GD25Q128C -r fullflash-read1.bin
flashrom -p ch341a_spi -c GD25Q128C -r fullflash-read2.bin
sha256sum fullflash-read1.bin fullflash-read2.bin
```

Only after matching reads should a restore be considered:

```bash
flashrom -p ch341a_spi -c GD25Q128C -w fullflash.bin
```

Writing the wrong image or using the wrong voltage can make recovery harder.

## Utilities

| Script | Purpose |
| --- | --- |
| `../../backup_gateway.sh` | Detect Linux type and create a verified SSH backup |
| `../../restore_gateway.sh` | Guide a full TFTP + `FLW` restore |
| `split_flash.sh` | Split a 16 MiB image into partition files |
| `scripts/restore_mtd_via_ssh.sh` | Restore a partition on original Tuya firmware |

Split a current custom image:

```bash
./split_flash.sh fullflash.bin
```

Split an original Lidl/Tuya image:

```bash
./split_flash.sh fullflash.bin lidl
```

For installation failures, continue with the central
[troubleshooting guide](../../docs/troubleshooting.md).
