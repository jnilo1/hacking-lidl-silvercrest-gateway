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

The **serialgateway** tool exposes the Zigbee serial port over TCP, allowing remote hosts to communicate with the Zigbee radio.

---

## Quick Start

### Get the Project

```bash
git clone https://github.com/YOUR_USERNAME/lidl-gateway-linux.git
cd lidl-gateway-linux/3-Main-SoC-Realtek-RTL8196E
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
| Kernel | [`32-Kernel/kernel.img`](./32-Kernel/) | ~1 MB | Linux 5.10 kernel |
| Root FS | [`33-Rootfs/rootfs.bin`](./33-Rootfs/) | ~900 KB | Base system (BusyBox, Dropbear) |
| Userdata | [`34-Userdata/userdata.bin`](./34-Userdata/) | ~12 MB | Apps (nano, serialgateway) |

> **Note:** The userdata image is 12 MB because it must fill the entire JFFS2 partition to avoid filesystem errors at boot. The actual data is only ~1 MB.

### Flashing

1. Connect to the gateway via serial (38400 8N1)
2. Enter bootloader mode (press ESC during boot to get `<RealTek>` prompt)
3. Run the flash script **from the repository root**:

```bash
./flash_rtl8196e.sh              # Flash all partitions
```

To flash individual partitions, use the scripts in each subdirectory:

```bash
3-Main-SoC-Realtek-RTL8196E/32-Kernel/flash_kernel.sh
3-Main-SoC-Realtek-RTL8196E/33-Rootfs/flash_rootfs.sh
3-Main-SoC-Realtek-RTL8196E/34-Userdata/flash_userdata.sh
```

### After Flashing

| Access | Details |
|--------|---------|
| Serial console | 38400 8N1 on `/dev/ttyUSB0` |
| SSH | Port 22 (Dropbear) |
| Default user | `root` (password: `root`) |
| Zigbee bridge | TCP port 8888 (serialgateway) |

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

### Connect to Zigbee2MQTT

In your Zigbee2MQTT configuration:

```yaml
serial:
  port: tcp://<GATEWAY_IP>:8888
```

Replace `<GATEWAY_IP>` with the IP assigned to your gateway (check via DHCP or serial console).

---

## Option 2: Build from Source

**For developers who want to modify and rebuild the system.**

### Prerequisites

First, set up the build environment. See [1-Build-Environment](../1-Build-Environment/) for detailed instructions.

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
./34-Userdata/serialgateway/build_serialgateway.sh
./34-Userdata/build_userdata.sh

# Build kernel
./32-Kernel/build_kernel.sh
```

After building, flash the images as described in [Option 1](#flashing).

---

## Project Structure

| Directory | Description |
|-----------|-------------|
| [1-Build-Environment](../1-Build-Environment/) | Toolchain, tools, and build setup |
| [30-Backup-Restore](./30-Backup-Restore/) | Backup and restore the flash memory |
| [31-Bootloader](./31-Bootloader/) | Realtek bootloader analysis |
| [32-Kernel](./32-Kernel/) | Linux 5.10 kernel with patches |
| [33-Rootfs](./33-Rootfs/) | Root filesystem (BusyBox, Dropbear SSH) |
| [34-Userdata](./34-Userdata/) | User partition (nano, serialgateway) |

---

## Features

- **Linux 5.10** kernel with full RTL8196E support
- **BusyBox** with 100+ applets (ash, vi, wget, etc.)
- **Dropbear** SSH server for remote access
- **nano** text editor for easy configuration
- **serialgateway** to expose Zigbee UART over TCP
- **JFFS2** writable userdata partition
- **NTP** time synchronization
- **Terminfo** support for proper terminal handling

---

## Technical Background

The RTL8196E is a MIPS-based SoC with a Lexra core (a MIPS variant without certain instructions like `lwl`, `lwr`, `swl`, `swr`). The stock firmware runs Linux 3.10 with proprietary Realtek SDK components.

This project provides a **modern Linux 5.10 system** built entirely from source:

- Custom toolchain supporting the Lexra architecture
- Patched kernel with full RTL8196E support
- Minimal root filesystem with essential tools
- Writable user partition for additional applications
