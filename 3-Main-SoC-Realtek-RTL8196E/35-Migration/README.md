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
./flash_install_rtl8196e.sh [-y] [--boot-ip <IP>] [LINUX_IP]
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

**Board and kernel selection** — `BOARD` (`lidl` default, or `sengled-e39-g8c`) and
`KERNEL` (`6.18` default, or `7.1`) pick which kernel image is baked into the fullflash.
A Lidl gateway needs neither; set them for the Sengled Smart Hub G4 or the 7.1 line:
```bash
KERNEL=7.1 ./flash_install_rtl8196e.sh -y 192.168.1.88
BOARD=sengled-e39-g8c ./flash_install_rtl8196e.sh
```

**LAN not on the `192.168.1.x` subnet** — the bootloader's download-mode /
TFTP server IP defaults to `192.168.1.6`. Override it with `--boot-ip` (or the
`BOOT_IP` env var; the flag wins). The `--boot-ip` flag is available from
**v3.7.0**; handing the address to the bootloader over `boothold` needs
bootloader **V2.7+** on the gateway, so no serial `IPCONFIG` is needed:
```bash
# Upgrade a gateway on a 192.168.0.x LAN
./flash_install_rtl8196e.sh --boot-ip 192.168.0.6 192.168.0.88

# First flash (gateway already at the bootloader prompt), unattended
./flash_install_rtl8196e.sh -y --boot-ip 192.168.0.6
```

#### Pre-v3.0 → v3.x : non-default radio configurations

The upgrade preserves `/userdata/etc/radio.conf` if it exists. When it
**doesn't** exist (the v2.x default — pre-v3.0 firmware shipped
`serialgateway` and didn't use this file), the script auto-seeds the
v2.x default state in the new userdata:

```
FIRMWARE=ncp
FIRMWARE_BAUD=115200
```

This is right for the vast majority of v2.x installs (NCP-UART-HW @
115200 was the v2.x default). **If your v2.x gateway runs a non-default
firmware** (e.g., OT-RCP for Thread/Matter, or a custom-built NCP at a
non-default baud), create `/userdata/etc/radio.conf` on the gateway
**before** running `flash_install_rtl8196e.sh` — the upgrade will pick
it up via the normal save/restore path and the auto-seed is skipped.

Recipe per v2.x firmware:

```bash
# OT-RCP @ 115200 (Thread Border Router, v2.x)
ssh root@192.168.1.88 'cat > /userdata/etc/radio.conf <<EOF
FIRMWARE=otrcp
FIRMWARE_BAUD=115200
MODE=otbr
EOF'

# RCP @ 115200 (Multi-PAN, v2.x)
ssh root@192.168.1.88 'cat > /userdata/etc/radio.conf <<EOF
FIRMWARE=rcp
FIRMWARE_BAUD=115200
EOF'

# NCP at a non-default baud you built yourself
ssh root@192.168.1.88 'cat > /userdata/etc/radio.conf <<EOF
FIRMWARE=ncp
FIRMWARE_BAUD=460800
EOF'
```

**v3.0 → v3.2+** : `radio.conf` already exists on v3.0/v3.1 (with at
least `BRIDGE_BAUD` or `MODE`/`OTBR_BAUD`); it's preserved as-is. The
init scripts in v3.2+ read the canonical `FIRMWARE_BAUD` first and fall
back to the legacy `BRIDGE_BAUD`/`OTBR_BAUD` if it's absent, so old
configs keep working unchanged. The next `flash_efr32.sh` invocation
strips the legacy keys and writes only `FIRMWARE_BAUD`. Optional: tidy
up by hand using the recipes above.

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
| kernel | 0x020000 | `32-Kernel/kernel-img/<board>/kernel-<line>.img` (default `lidl`/`6.18`) | Keep cs6c header |
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
the reflash — no prompts needed. It also carries over **anything you added under
`/userdata`** that the skeleton does not ship — a custom program in `usr/bin`, a
script, a whole new directory (subdirectories and empty dirs included). Skeleton
defaults are taken from the new image.

```bash
cd 3-Main-SoC-Realtek-RTL8196E
./flash_remote.sh [-y] [--boot-ip <IP>] <bootloader|kernel|rootfs|userdata> <LINUX_IP>
```

Environment variables: `BOOT_IP` (default: 192.168.1.6), `SSH_TIMEOUT`,
`SSH_PASSWORD`, `NET_MODE`, `RADIO_MODE`, `CONFIRM`.

If your LAN is not on the `192.168.1.x` subnet, set `BOOT_IP` (env) or pass
`--boot-ip <IP>` (e.g. `--boot-ip 192.168.0.6`) to an address on your subnet.
The `--boot-ip` flag is available from **v3.7.0**. With bootloader V2.7+, the
script hands this address to `boothold`, so the gateway comes up on it in
download mode — no serial console or `IPCONFIG` needed, and the "same subnet"
TFTP requirement below is satisfied automatically. On older bootloaders the
argument is ignored and the download-mode IP stays at the compiled default
`192.168.1.6`.

The individual flash scripts (`flash_bootloader.sh`, `flash_kernel.sh`, etc.)
can also be used directly when the gateway is already in bootloader mode.

### `flash_efr32.sh` — Silabs EFR32 radio (OTA via SSH)

Flashes firmware to the EFR32MG1B Zigbee/Thread radio over the network.
The gateway must be running with SSH access (custom firmware already installed).

```bash
./flash_efr32.sh -y ncp                    # default IP 192.168.1.88
./flash_efr32.sh -y ncp 460800             # NCP at 460800 baud
./flash_efr32.sh -y -g 10.0.0.5 otrcp      # custom IP, OT-RCP
./flash_efr32.sh --help                    # full CLI reference
```

Firmware aliases: `bootloader`, `ncp`, `rcp`, `otrcp`, `router`
(numeric `1`-`5` also accepted).

The script:
1. Pulses `nRST` (sysfs knob) to start the chip from a known-clean state
2. Installs `universal-silabs-flasher` in a venv if needed (auto-reinstalls if probe-methods patch changes)
3. SSHes into the gateway, stops radio daemons, switches the in-kernel UART bridge to flash mode (`flow_control=0`)
4. Probes the running app (or the Gecko Bootloader if the chip is already there), flashes the selected firmware via EZSP/CPC/Spinel + Xmodem over `socket://IP:8888`
5. Writes the chip identity (`FIRMWARE`, `FIRMWARE_VERSION`, `FIRMWARE_BAUD`) and daemon-routing key (`MODE`) to `/userdata/etc/radio.conf` so init scripts arm correctly on next boot AND a future reader can tell what's on the chip without probing
6. Reboots the gateway

| Firmware | Location | Description | `radio.conf` after flash |
|----------|----------|-------------|--------------------------|
| `bootloader-uart-xmodem-2.4.2.gbl` | `23-Bootloader-UART-Xmodem/firmware/` | Gecko Bootloader stage 2 | unchanged (bootloader update doesn't change the app slot) |
| `ncp-uart-hw-<EmberVersion>-<BAUD>.gbl` | `24-NCP-UART-HW/firmware/` | Zigbee NCP for Z2M / ZHA (EZSP) | `FIRMWARE=ncp` + `FIRMWARE_VERSION=<v>` + `FIRMWARE_BAUD=<BAUD>` |
| `rcp-uart-802154-<BAUD>.gbl` | `25-RCP-UART-HW/firmware/` | Multi-PAN RCP for Z2M (EmberZNet 8.x via cpcd) | `FIRMWARE=rcp` + `FIRMWARE_BAUD=<BAUD>` |
| `ot-rcp-<BAUD>.gbl` | `26-OT-RCP/firmware/` | OpenThread RCP — 3 use cases via `radio.conf` | `FIRMWARE=otrcp` + `FIRMWARE_BAUD=<BAUD>` + `MODE=otbr` (case 3 default; remove `MODE` for cases 1/2) |
| `z3-router-<EmberVersion>-<BAUD>.gbl` | `27-Router/firmware/` | Zigbee 3.0 standalone router | `FIRMWARE=router` + `FIRMWARE_VERSION=<v>` + `FIRMWARE_BAUD=115200` |

> Pre-built GBL filenames embed the EmberZNet version (where applicable) and
> the UART baud. `flash_efr32.sh` resolves the right file via a glob, so
> you don't need to track exact filenames after firmware bumps. See
> [`2-Zigbee-Radio-Silabs-EFR32/README.md`](../../2-Zigbee-Radio-Silabs-EFR32/README.md)
> for the per-firmware supported baud sets.

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
- **Boot loop right after a full-flash** — only the *first* full-flash from a
  pre-V2.9 bootloader can do this: the old bootloader still runs the kernel
  handoff for that one reboot, and the switch DMA scribbles DRAM during early
  boot. **Unplug the gateway for a few seconds and plug it back in** — a cold
  power cycle clears it; a warm `reboot` will not. V2.9 (shipped from this
  release) stops the switch DMA before handoff, so every full-flash after V2.9 is
  in place boots clean on its own.

### EFR32 (OTA flash)

- **SSH timeout** — the script retries 3 times; check gateway is reachable
- **USF probe fails** — check `cat /sys/module/rtl8196e_uart_bridge/parameters/flow_control` on the gateway (should be `0` during flash); reboot and retry
- **No progress bar** — only happens when flashing the bootloader (output is captured for error detection)

## Rollback

To restore original firmware, flash the backed-up images from the `<RealTek>` prompt.
See **[30-Backup-Restore](../30-Backup-Restore/README.md)** for detailed restore procedures.
