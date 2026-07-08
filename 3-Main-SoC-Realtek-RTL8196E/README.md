# Main SoC — Realtek RTL8196E

This section covers the **main processor** running Linux on the gateway.

## What Does the Linux System Do?

The Linux system acts as a **bridge** between the Zigbee coprocessor (Silabs EFR32) and your home automation host (Zigbee2MQTT, Home Assistant, etc.).

```
+-------------------------------------------------------------------+
|                         Lidl Gateway                              |
|                                                                   |
|   +--------------+             +--------------+                   |
|   |   RTL8196E   |    serial   |    Silabs    |                   |
|   |   (Linux)    |<----------->|    EFR32     |  ))) Zigbee       |
|   |              |             |              |                   |
|   |    ttyS1     |             |    ttyS0     |                   |
|   +------+-------+             +--------------+                   |
|          | eth0                                                   |
+----------+--------------------------------------------------------+
           |
           | TCP/IP
           v
    +--------------+
    |   Z2M / HA   |
    |  (your host) |
    +--------------+
```

The **in-kernel UART↔TCP bridge** (`rtl8196e-uart-bridge`, part of the 6.18 kernel) exposes the Zigbee serial port over TCP, allowing remote hosts to communicate with the Zigbee radio. It replaces the former `serialgateway` userspace daemon from v3.0.

---

## Quick Start

### Get the Project

```bash
git clone https://github.com/jnilo1/hacking-lidl-silvercrest-gateway.git
cd hacking-lidl-silvercrest-gateway/3-Main-SoC-Realtek-RTL8196E
```

### Choose Your Path

| | Option 1: Flash Pre-built Images | Option 2: Build from Source |
|---|---|---|
| **For** | Most users | Developers / Hackers |
| **Time** | ~5 minutes | ~1 hour |
| **Requires** | Serial adapter + TFTP | Docker or Ubuntu 22.04 |
| **Use case** | Just want a working Zigbee bridge | Customize the system |

---

## Option 1: Flash Pre-built Images

**Pre-built images are ready to flash.** No compilation needed.

### Images Location

| Image | File | Size | Description |
|-------|------|------|-------------|
| Bootloader | [`31-Bootloader/boot-img/<board>/boot.bin`](./31-Bootloader/README.md) | ~22 KB | Boot code — per-board DRAM bring-up; one image per board shipped |
| Kernel | [`32-Kernel/kernel-img/<board>/kernel-<line>.img`](./32-Kernel/README.md) | ~1.4 MB | Linux kernel — `<board>` ∈ {`lidl`, `sengled-e39-g8c`}, `<line>` ∈ {`6.18`, `7.1`}; four images shipped |
| Root FS | [`33-Rootfs/rootfs.bin`](./33-Rootfs/README.md) | ~900 KB | Base system (BusyBox, Dropbear) — board/kernel-agnostic |
| Userdata | [`34-Userdata/userdata.bin`](./34-Userdata/README.md) | ~12 MB | Apps (nano, otbr-agent, boothold) — board/kernel-agnostic |

> **Note:** The userdata image is 12 MB because it must fill the entire JFFS2 partition to avoid filesystem errors at boot. The actual data is only ~1 MB.

> **Choosing board and kernel:** every flash/build script accepts two environment
> variables — `BOARD` (`lidl` default, or `sengled-e39-g8c` for the Sengled Smart Hub G4)
> and `KERNEL` (`6.18` default, or `7.1`). A Lidl user sets neither and gets the historical
> `lidl`/`6.18` image unchanged.
>
> **Non-Lidl board safety:** a full install (`flash_install_rtl8196e.sh`) also flashes the
> **bootloader**, whose DRAM config is board-specific. Since discussion #140 the flash
> tooling resolves the pre-built `31-Bootloader/boot-img/<board>/boot.bin` from `BOARD=`
> automatically — the same selection mechanism as the kernel — so the image always matches
> the selected board. The upgrade path additionally verifies `/proc/device-tree/model` and
> refuses a board mismatch unless `--force`.

### Flashing

1. Connect to the gateway via serial (38400 8N1) — only needed for initial install with original Tuya bootloader
2. Run the install script **from the repository root**:

```bash
./flash_install_rtl8196e.sh                        # Build fullflash.bin and install (lidl / 6.18)
KERNEL=7.1 ./flash_install_rtl8196e.sh             # ... with the 7.1 kernel line
BOARD=sengled-e39-g8c ./flash_install_rtl8196e.sh  # ... for the Sengled Smart Hub G4
```

The script auto-detects the gateway state:
- **Custom firmware running (SSH:22)** — automatic boothold + reboot + TFTP upload
- **V2 bootloader** — automatic TFTP upload + auto-flash + reboot
- **Old bootloader (Tuya/V1.2)** — TFTP upload + guided FLW on serial console

To flash individual partitions (developers), use the scripts in each subdirectory:

```bash
cd 3-Main-SoC-Realtek-RTL8196E
31-Bootloader/flash_bootloader.sh
32-Kernel/flash_kernel.sh
33-Rootfs/flash_rootfs.sh
34-Userdata/flash_userdata.sh
```

#### Remote Flashing (no serial console)

`flash_remote.sh` handles everything over the network: SSH into the gateway, reboot to bootloader, wait, and flash — no serial console needed.

```bash
cd 3-Main-SoC-Realtek-RTL8196E
./flash_remote.sh rootfs 192.168.1.88                    # Flash rootfs remotely
./flash_remote.sh kernel 192.168.1.88                    # Flash kernel (lidl / 6.18, auto-reboots)
KERNEL=7.1 ./flash_remote.sh kernel 192.168.1.88         # Flash the 7.1 kernel line
BOARD=sengled-e39-g8c ./flash_remote.sh kernel 192.168.1.88  # Flash the Sengled G4 kernel
./flash_remote.sh bootloader 192.168.1.88                # Flash bootloader
./flash_remote.sh userdata 192.168.1.88                  # Flash userdata (defaults: static IP, Zigbee)
```

> The `kernel` component checks the gateway's `/proc/device-tree/model` and refuses to flash
> a kernel built for a different board (pass `--force` to override).

> Flashing **userdata** over SSH preserves your config (network, password, SSH keys, radio,
> Thread credentials) **and** anything you added under `/userdata` that the skeleton does
> not ship — a custom program in `usr/bin`, a script, a whole new directory. A bare
> `34-Userdata/flash_userdata.sh` does a clean wipe instead.

Override defaults via environment variables:

```bash
./flash_remote.sh userdata 192.168.1.88                              # Static IP, Zigbee
RADIO_MODE=thread ./flash_remote.sh userdata 192.168.1.88            # Static IP, Thread/OTBR
IPADDR=10.0.0.50 ./flash_remote.sh userdata 192.168.1.88             # Custom IP, Zigbee
NET_MODE=dhcp RADIO_MODE=thread ./flash_remote.sh userdata 192.168.1.88  # DHCP, Thread/OTBR
```

The individual flash scripts also support non-interactive use directly:

```bash
CONFIRM=y ./flash_rootfs.sh                             # Skip "Proceed?" prompt
NET_MODE=static RADIO_MODE=zigbee CONFIRM=y ./flash_userdata.sh  # Full non-interactive
```

| Variable | Values | Default | Script |
|----------|--------|---------|--------|
| `CONFIRM` | `y` | *(interactive prompt)* | all |
| `NET_MODE` | `static`, `dhcp` | *(interactive prompt)* | flash_userdata.sh |
| `RADIO_MODE` | `zigbee`, `thread` | *(interactive prompt)* | flash_userdata.sh |
| `IPADDR` | IP address | `192.168.1.88` | flash_userdata.sh |
| `NETMASK` | Netmask | `255.255.255.0` | flash_userdata.sh |
| `GATEWAY` | Gateway IP | `192.168.1.1` | flash_userdata.sh |

### After Flashing

| Access | Details |
|--------|---------|
| Serial console | 38400 8N1 on `/dev/ttyUSB0` |
| SSH | Port 22 (Dropbear) |
| Default user | `root` (password: `root`) |
| Zigbee bridge | TCP port 8888 (in-kernel `rtl8196e-uart-bridge`) |

### Configuration

After flashing, tune the configuration to fit your needs. Use `nano` to edit configuration files.

#### 1. Change Root Password (mandatory)

```bash
passwd
```

#### 2. Network Configuration

`flash_userdata.sh` asks for network configuration (static IP or DHCP) at flash time.
The IP is baked into `userdata.bin` before flashing — no manual step needed.

To change the IP after flashing:

```bash
nano /etc/eth0.conf    # Edit IP, netmask, gateway
/userdata/etc/init.d/S10network restart
```

Format:
```
IPADDR=192.168.1.88
NETMASK=255.255.255.0
GATEWAY=192.168.1.1
```

#### 3. Timezone

```bash
nano /etc/TZ
```

Default is Central European Time. Format is POSIX TZ string. Find yours at [tz.cablemap.pl](https://tz.cablemap.pl/). 

For examples:
- `CET-1CEST,M3.5.0/2,M10.5.0/3` — Central Europe (Paris, Berlin)
- `GMT0BST,M3.5.0/1,M10.5.0` — UK
- `EST5EDT,M3.2.0,M11.1.0` — US Eastern
- `PST8PDT,M3.2.0,M11.1.0` — US Pacific

#### 4. NTP Servers

```bash
nano /etc/ntp.conf
```

#### 5. Hostname

```bash
nano /etc/hostname
```

#### 6. SSH Passwordless Login

```bash
nano ~/.ssh/authorized_keys
# Paste your public key (from ~/.ssh/id_rsa.pub on your PC)
```

#### 7. LED Brightness

The gateway supports three LED modes. Set the mode in `/userdata/etc/leds.conf`:

| Mode | LAN LED | STATUS LED |
|------|---------|------------|
| `bright` | Full brightness (default) | 255 |
| `dim` | Reduced (~25%) | 60 |
| `off` | Completely off | 0 |

Switch modes without rebooting:
```bash
# All LEDs off
echo MODE=off > /userdata/etc/leds.conf
/userdata/etc/init.d/S11leds start

# Dim mode
echo MODE=dim > /userdata/etc/leds.conf
/userdata/etc/init.d/S11leds start

# Full brightness (default)
echo MODE=bright > /userdata/etc/leds.conf
/userdata/etc/init.d/S11leds start
```

The setting is applied automatically at every boot. The `S50uart_bridge` init
script (Zigbee mode) and `otbr-agent` (Thread mode) read the mode automatically
when they turn the STATUS LED on.

#### 8. Radio / UART bridge (`/userdata/etc/radio.conf`)

`flash_efr32.sh` keeps the chip-side identity (`FIRMWARE`,
`FIRMWARE_VERSION`, `FIRMWARE_BAUD`, `FIRMWARE_FLOW_CTRL`) and the
daemon-routing key (`MODE`) in sync with the firmware flashed on the
EFR32, so most users never need to touch this file. Edit it manually only to:
- change the bind address (`BRIDGE_BIND`)
- switch an OT-RCP chip between Zigbee bridge mode (cases 1 & 2) and
  Thread mode (case 3) without reflashing — see
  [`2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP/docker/README.md`](../2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP/docker/README.md#switching-radio-mode-no-efr32-reflash-needed)

| Key | Values | Default | Written by | Read by |
|-----|--------|---------|------------|---------|
| `FIRMWARE` | `ncp`, `rcp`, `otrcp`, `router` | (absent) | `flash_efr32.sh` | docs / diagnostics |
| `FIRMWARE_VERSION` | e.g. `7.5.1` (NCP, Router only) | (absent) | `flash_efr32.sh` | docs / diagnostics |
| `FIRMWARE_BAUD` | `115200`, `230400`, `460800`, `691200`, `892857` | `460800` | `flash_efr32.sh` | `S50uart_bridge`, `S70otbr` |
| `FIRMWARE_FLOW_CTRL` | `none`, `sw`, `hw` | (absent ⇒ devicetree per-board default) | `flash_efr32.sh` — app flashes (#141) | `S50uart_bridge`, `S70otbr` |
| `BOOTLOADER_VERSION` | e.g. `2.4.2` | (absent) | `flash_efr32.sh` — every flash | docs / diagnostics |
| `MODE` | `otbr` (or absent) | absent = Zigbee | `flash_efr32.sh` | `S50uart_bridge`, `S70otbr` |
| `BRIDGE_BIND` | `0.0.0.0`, `127.0.0.1` | `0.0.0.0` | (manual) | `S50uart_bridge` |

`FIRMWARE_BAUD` is the single source of truth for the EFR32 UART baud:
both ends of the link must agree, so the chip-side value (set at flash
time) is the value the host-side daemons (`S50uart_bridge`, `S70otbr`)
read. Letting `cat /userdata/etc/radio.conf` tell you what's on the chip
without an `universal-silabs-flasher probe`. Full reference + the rationale
for why there is no `FIRMWARE=bootloader` value:
[`34-Userdata/README.md`](./34-Userdata/README.md#radioconf-keys-full-reference).

`BRIDGE_BIND=127.0.0.1` restricts the Zigbee TCP bridge to loopback so it
can only be reached through an SSH tunnel — see
[`drivers/net/rtl8196e-uart-bridge/SECURITY.md`](./32-Kernel/files-6.18/drivers/net/rtl8196e-uart-bridge/SECURITY.md)
for the rationale and the tunnel recipe.

`FIRMWARE_FLOW_CTRL` is written automatically by `flash_efr32.sh` on every
application flash (#141): the value comes from the selected board's
`boards/<board>/board.env` (`BOARD_UART_FLOW` — `hw` on the Lidl reference,
`sw` on the Sengled G4, which has no RTS/CTS wiring), so the host side
always matches the flow-control mode the firmware was built with. With the
key absent (configs from before this change, never reflashed) the bridge
falls back to the board's devicetree default, while `S70otbr` assumes `hw`
— which is why the G4 previously needed the key added by hand for OT-RCP.
A manual edit is still honoured until the next app flash resets it — only
relevant when flashing an exotic image via `--firmware-file` whose flow
mode differs from the board default. A request for `hw` on a board that
does not wire RTS/CTS is clamped to `sw` by the kernel, so it can never
wedge the UART.

`FIRMWARE_BAUD` must match the baud the EFR32 firmware was built at.
**`flash_efr32.sh` handles this automatically**: when you flash e.g.
`ncp 460800`, the script writes `FIRMWARE_BAUD=460800`. Per-firmware
supported baud sets (NCP 5 values, RCP 3 POSIX-only values, OT-RCP 460800
only, Router 115200 only) are documented in
[`2-Zigbee-Radio-Silabs-EFR32/README.md`](../2-Zigbee-Radio-Silabs-EFR32/README.md#gateway-side-runtime-configuration).

Apply changes without rebooting:
```bash
/userdata/etc/init.d/S50uart_bridge restart   # Zigbee mode
/userdata/etc/init.d/S70otbr        restart   # Thread mode
```

### Connect to Zigbee2MQTT

In your Zigbee2MQTT configuration:

```yaml
serial:
  port: tcp://<LINUX_IP>:8888
```

Replace `<LINUX_IP>` with the IP assigned to your gateway (check via DHCP or serial console).

---

## Option 2: Build from Source

**For developers who want to modify and rebuild the system.**

### Prerequisites

First, set up the build environment. See [1-Build-Environment](../1-Build-Environment/README.md) for detailed instructions.

**Quick setup:**

```bash
# Using Docker (any OS)
cd ../1-Build-Environment
docker build -t lidl-gateway-builder .

# Or native Ubuntu 22.04 / WSL2
cd ../1-Build-Environment
sudo ./install_deps.sh
cd 10-lexra-toolchain && ./build_toolchain.sh && cd ..
cd 11-realtek-tools && ./build_tools.sh && cd ..
```

### Build with Docker

```bash
# From project root
docker run -it --rm -v $(pwd):/workspace lidl-gateway-builder \
    /workspace/3-Main-SoC-Realtek-RTL8196E/build_rtl8196e.sh

# Or run interactively
docker run -it --rm -v $(pwd):/workspace lidl-gateway-builder
```

### Build Natively (Ubuntu 22.04 / WSL2)

```bash
# The build scripts auto-detect the toolchain in the project directory
# Or set it manually:
# export PATH="<project>/x-tools/mips-lexra-linux-musl/bin:$PATH"

# Build rootfs components
./33-Rootfs/busybox/build_busybox.sh
./33-Rootfs/dropbear/build_dropbear.sh
./33-Rootfs/build_rootfs.sh

# Build userdata components
./34-Userdata/nano/build_nano.sh
./34-Userdata/build_userdata.sh

# Build kernel
./32-Kernel/build_kernel.sh
```

After building, flash the images as described in [Option 1](#flashing).

---

## Project Structure

| Directory | Description |
|-----------|-------------|
| [1-Build-Environment](../1-Build-Environment/README.md) | Toolchain, tools, and build setup |
| [30-Backup-Restore](./30-Backup-Restore/README.md) | Backup and restore the flash memory |
| [31-Bootloader](./31-Bootloader/README.md) | Realtek bootloader analysis |
| [32-Kernel](./32-Kernel/README.md) | Linux 6.18 kernel with patches |
| [33-Rootfs](./33-Rootfs/README.md) | Root filesystem (BusyBox, Dropbear SSH) |
| [34-Userdata](./34-Userdata/README.md) | User partition (nano, otbr-agent, boothold) |

---

## Features

- **Linux 6.18** kernel with full RTL8196E support
- **BusyBox** with 100+ applets (ash, vi, wget, etc.)
- **Dropbear** SSH server for remote access
- **nano** text editor for easy configuration
- **In-kernel UART↔TCP bridge** (`rtl8196e-uart-bridge`) to expose Zigbee UART over TCP:8888
- **JFFS2** writable userdata partition
- **NTP** time synchronization
- **Terminfo** support for proper terminal handling

---

## Technical Background

The RTL8196E is a MIPS-based SoC with a Lexra core (a MIPS variant without certain instructions like `lwl`, `lwr`, `swl`, `swr`). The stock firmware runs Linux 3.10 with proprietary Realtek SDK components.

This project provides a **modern Linux 6.18 system** built entirely from source:

- Custom toolchain supporting the Lexra architecture
- Patched kernel with full RTL8196E support
- Minimal root filesystem with essential tools
- Writable user partition for additional applications
