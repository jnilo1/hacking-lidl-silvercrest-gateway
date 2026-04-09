# Migration Guide

Migrate a Lidl/Silvercrest Zigbee Gateway from Tuya firmware to custom Linux system.

> **IMPORTANT: Backup First!**
>
> Before any migration, make a complete backup of all original partitions (bootloader, kernel, rootfs, userdata). This allows full recovery if something goes wrong.
>
> See **[30-Backup-Restore](../30-Backup-Restore/README.md)** for detailed backup procedures.

## Flash Scripts

### `flash_install_rtl8196e.sh` — Full firmware install (recommended)

Builds a complete 16 MiB flash image and installs it on the gateway. This is the
recommended script for both first-time installs and upgrades.

```bash
./flash_install_rtl8196e.sh [-y] [LINUX_IP]
```

**First flash** (no argument) — the gateway must already be in bootloader mode:
- Connect a serial console (3.3V UART, 38400 8N1, line wrap ON)
- Power cycle the gateway, press ESC to get the `<RealTek>` prompt
- Then run `./flash_install_rtl8196e.sh`
- User config cannot be saved — you will be prompted for network (static IP or
  DHCP) and radio mode (Zigbee or Thread)

**Upgrade** (with `LINUX_IP`) — the gateway must be running Linux:
- Run `./flash_install_rtl8196e.sh 192.168.1.88` (replace with your gateway IP)
- The script connects via SSH, saves user config (network, password, SSH keys,
  radio mode, Thread credentials), then triggers boothold + reboot to bootloader
- Saved config is injected into the new image — no prompts needed

**Fully automated upgrade** (firmware >= v2.0.0) — no prompts, no serial needed:
- Run `./flash_install_rtl8196e.sh -y 192.168.1.88`
- The `-y` flag skips all confirmation prompts
- Auto-flash + UDP notification: the script uploads, waits for the bootloader to
  confirm, and reports success — no serial console required

The script:
1. Detects firmware type via SSH (custom vs Tuya, using `devmem` presence)
2. Saves user config if custom firmware is running
3. Builds `fullflash.bin` via `build_fullflash.sh` (assembles all 4 partitions)
4. Uploads fullflash.bin via TFTP
5. Firmware >= v2.0.0: auto-flashes and reboots automatically
6. Older firmware / Tuya: guides you through FLW on the serial console

Environment variables for non-interactive use:
```bash
NET_MODE=static RADIO_MODE=zigbee ./flash_install_rtl8196e.sh -y
```

### `build_fullflash.sh` — Build the flash image

Assembles bootloader, kernel, rootfs and userdata into a single verified 16 MiB
image. Called automatically by `flash_install_rtl8196e.sh`, but can also be used
standalone.

```bash
./build_fullflash.sh
```

| Partition | Flash offset | Source | Header handling |
|-----------|-------------|--------|-----------------|
| boot+cfg | 0x000000 | `31-Bootloader/boot.bin` | Strip cvimg header |
| kernel | 0x020000 | `32-Kernel/kernel.img` | Keep cs6c header |
| rootfs | 0x200000 | `33-Rootfs/rootfs.bin` | Strip cvimg header |
| userdata | 0x400000 | `34-Userdata/userdata.bin` | Strip cvimg header |

### `flash_remote.sh` — Per-partition flash (for developers)

Flashes a single partition via SSH + boothold + TFTP. Connects to the running
gateway, sends it to bootloader mode, waits, then runs the appropriate flash
script. No serial console needed. Requires custom firmware >= v2.1.1 (with
the `boothold` binary). Does NOT work on Tuya/stock firmware or v1.0 — use
`flash_install_rtl8196e.sh` for those.

For **userdata**, the script saves user config via SSH before flashing (eth0.conf,
mac_address, radio.conf, passwd, TZ, hostname, dropbear host keys, SSH keys,
Thread credentials). The config is injected into the new image so it survives
the reflash — no prompts needed.

```bash
cd 3-Main-SoC-Realtek-RTL8196E
./flash_remote.sh [-y] <bootloader|kernel|rootfs|userdata> <LINUX_IP>
```

Environment variables: `BOOT_IP` (default: 192.168.1.6), `SSH_USER`, `SSH_TIMEOUT`,
`NET_MODE`, `RADIO_MODE`, `CONFIRM`.

The individual flash scripts (`flash_bootloader.sh`, `flash_kernel.sh`, etc.)
can also be used directly when the gateway is already in bootloader mode.

### `flash_efr32.sh` — Silabs EFR32 radio (OTA via SSH)

Flashes firmware to the EFR32MG21 Zigbee/Thread radio over the network.
The gateway must be running with SSH access (custom firmware already installed).

```bash
./flash_efr32.sh [GATEWAY_IP]
```

The script:
1. Presents a firmware selection menu
2. Installs `universal-silabs-flasher` in a venv if needed (auto-reinstalls if probe-methods patch changes)
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

## Prerequisites

### Hardware

- **Serial adapter** connected to gateway (38400 8N1) — required for initial RTL8196E flash;
  not needed for subsequent updates via `flash_remote.sh`
- **Ethernet connection** between PC and gateway (same L2 segment for TFTP)

### Software

- **tftp-hpa** and **netcat** — for RTL8196E flash:
  ```bash
  sudo apt install tftp-hpa netcat-openbsd
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
See **[30-Backup-Restore](../30-Backup-Restore/README.md)** for detailed restore procedures.
