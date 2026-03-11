# Migration Guide

Migrate a Lidl/Silvercrest Zigbee Gateway from Tuya firmware to custom Linux system.

> **IMPORTANT: Backup First!**
>
> Before any migration, make a complete backup of all original partitions (bootloader, kernel, rootfs, userdata). This allows full recovery if something goes wrong.
>
> See **[30-Backup-Restore](../30-Backup-Restore/)** for detailed backup procedures.

## Flash Scripts

Two scripts at the repository root handle all flashing operations:

### `flash_rtl8196e.sh` — RTL8196E main SoC (TFTP)

Flashes the Linux system (bootloader, kernel, rootfs, userdata) to the RTL8196E
via TFTP. The gateway must be in bootloader mode (`<RealTek>` prompt on the
serial console).

```bash
./flash_rtl8196e.sh [--ip ADDRESS]
```

The script:
1. Asks for network configuration (static IP or DHCP) and rebuilds userdata
2. Detects the gateway on the network (ARP probe)
3. Optionally backs up the current flash via TFTP GET (16 MB full backup)
4. Flashes all 4 partitions in order: bootloader, rootfs, userdata, kernel
5. Waits for bootloader UDP notification (OK/FAIL) after each partition

| Image | Location | Description |
|-------|----------|-------------|
| boot.bin | `31-Bootloader/` | Custom bootloader with boothold and ICMP ping |
| kernel.img | `32-Kernel/` | Linux 5.10.246 kernel with rtl8196e-eth driver |
| rootfs.bin | `33-Rootfs/` | Root filesystem (SquashFS, BusyBox + Dropbear) |
| userdata.bin | `34-Userdata/` | User partition (JFFS2, init scripts + serialgateway) |

### `flash_efr32.sh` — Silabs EFR32 radio (OTA via SSH)

Flashes firmware to the EFR32MG21 Zigbee/Thread radio over the network.
The gateway must be running with SSH access (custom firmware already installed).

```bash
./flash_efr32.sh [GATEWAY_IP]
```

The script:
1. Presents a firmware selection menu
2. Installs `universal-silabs-flasher` in a venv if needed
3. SSHes into the gateway to restart serialgateway in flash mode (retries up to 3 times)
4. Flashes the selected firmware via EZSP/Xmodem over `socket://IP:8888`
5. Reboots the gateway

| Firmware | Location | Description |
|----------|----------|-------------|
| bootloader-uart-xmodem-2.4.2.gbl | `23-Bootloader-UART-Xmodem/firmware/` | Gecko Bootloader stage 2 |
| ncp-uart-hw-7.5.1.gbl | `24-NCP-UART-HW/firmware/` | Zigbee NCP for zigbee2mqtt / ZHA (EZSP) |
| rcp-uart-802154.gbl | `25-RCP-UART-HW/firmware/` | Multi-PAN RCP for zigbee2mqtt (EmberZNet 8.x via cpcd) |
| ot-rcp.gbl | `26-OT-RCP/firmware/` | OpenThread RCP for otbr-agent |
| z3-router-7.5.1.gbl | `27-Router/firmware/` | Zigbee 3.0 standalone router |

### `remote_flash.sh` — Remote flash without serial console

Automates the full workflow over SSH: connects to the gateway, sends `boothold` to
reboot into bootloader, waits for it to come up, then runs the appropriate flash script.

```bash
cd 3-Main-SoC-Realtek-RTL8196E
./remote_flash.sh bootloader                # Flash bootloader remotely
./remote_flash.sh kernel                    # Flash kernel (auto-reboots)
./remote_flash.sh rootfs                    # Flash rootfs
./remote_flash.sh userdata                  # Flash userdata (defaults: static IP, Zigbee)
RADIO_MODE=thread ./remote_flash.sh userdata  # Flash userdata in Thread/OTBR mode
```

Requires the custom firmware already running (SSH access to the gateway).

## Prerequisites

### Hardware

- **Serial adapter** connected to gateway (38400 8N1) — required for initial RTL8196E flash;
  not needed for subsequent updates via `remote_flash.sh`
- **Ethernet connection** between PC and gateway (same L2 segment for TFTP)

### Software

- **tftp-hpa** — for RTL8196E flash:
  ```bash
  sudo apt install tftp-hpa
  ```
- **Python 3 + venv** — for EFR32 flash (universal-silabs-flasher is installed automatically)

## Partition Layout

```
0x000000-0x020000  mtd0  boot+cfg     (128 KB)   - Bootloader
0x020000-0x200000  mtd1  linux        (1.9 MB)   - Linux kernel
0x200000-0x400000  mtd2  rootfs       (2 MB)     - Root filesystem
0x400000-0x1000000 mtd3  jffs2-fs     (12 MB)    - User partition
```

## Troubleshooting

### RTL8196E (TFTP flash)

- **Cannot enter bootloader** — verify serial 38400 8N1, press ESC on power-on
- **TFTP transfer fails** — check firewall (UDP 69), verify same subnet, no other TFTP server
- **"Flash Write Successed!" doesn't appear** — wait longer (userdata takes 1-2 min)
- **SSH refused after reboot** — wait 30s, check IP on serial console (`ip addr`)

### EFR32 (OTA flash)

- **SSH timeout** — the script retries 3 times; check gateway is reachable
- **USF probe fails** — serialgateway may not be in flash mode; reboot and retry
- **No progress bar** — only happens when flashing the bootloader (output is captured for error detection)

## Rollback

To restore original firmware, flash the backed-up images from the `<RealTek>` prompt.
See **[30-Backup-Restore](../30-Backup-Restore/)** for detailed restore procedures.
