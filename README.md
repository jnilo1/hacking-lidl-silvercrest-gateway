# Hacking the Lidl Silvercrest Gateway

> **If you find this project useful, please consider giving it a star!** It helps others discover it and motivates continued development.
>
> Questions? Use [Discussions](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions). Found a bug? Open an [Issue](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/issues).

## What Can You Do With This?

The **Lidl Silvercrest Zigbee Gateway** (~15 EUR) is normally locked to the Tuya cloud.
This project replaces the firmware and turns it into a **fully local, open Zigbee coordinator**:

- **Zigbee2MQTT / ZHA** — pair and control any Zigbee device, no cloud required
- **Home Assistant** — use it as your Zigbee coordinator, connected over the network
- **OpenThread** — use the radio as a Thread Border Router (with otbr-agent)
- **SSH access** — full Linux shell on the gateway (BusyBox + Dropbear)
- **Zigbee router** — turn the gateway into a standalone Zigbee 3.0 router to extend your mesh
- **OTA firmware updates** — flash the Zigbee radio over the network, no SWD needed

The gateway has two chips: a **Realtek RTL8196E** running Linux, and a **Silabs EFR32MG1B**
Zigbee/Thread radio connected via UART. This project provides firmware for both.

______________________________________________________________________

## Quick Start

### What You Need

- A Lidl Silvercrest Zigbee Gateway
- USB-to-serial adapter (3.3V, 38400 8N1) — for the initial flash only
- Ethernet connection to the gateway

### Step 1: Clone and Flash the Linux System

```bash
git clone https://github.com/jnilo1/hacking-lidl-silvercrest-gateway.git
cd hacking-lidl-silvercrest-gateway
./flash_install_rtl8196e.sh
```

The script builds a complete 16 MiB flash image, detects the gateway (with
automatic boothold if custom firmware is running), uploads it via TFTP, and
flashes it. With the V2 bootloader, everything is automatic. For older
bootloaders (Tuya/V1.2), it guides you through the FLW command on the serial
console.

See [35-Migration](./3-Main-SoC-Realtek-RTL8196E/35-Migration/) for details.

### Step 2: Flash the Zigbee Radio

Once the gateway is running (SSH access on port 22):

```bash
./flash_efr32.sh <GATEWAY_IP>
```

Select the firmware for your use case:

| Choice | Firmware | Use with |
|--------|----------|----------|
| **NCP-UART-HW** | EmberZNet 7.5.1 (EZSP) | zigbee2mqtt, ZHA — simplest setup |
| **RCP-UART-HW** | Multi-PAN RCP | zigbee2mqtt via cpcd + zigbeed |
| **OT-RCP** | OpenThread RCP | otbr-agent (Thread Border Router) |

### Step 3: Connect Zigbee2MQTT

In your zigbee2mqtt `configuration.yaml`:

```yaml
serial:
  port: tcp://<GATEWAY_IP>:8888
  adapter: ember
```

Open the web UI at `http://localhost:8080` and start pairing devices.

______________________________________________________________________

## Repository Structure

| Directory | Contents |
|-----------|----------|
| [0-Hardware](./0-Hardware/) | PCB photos, pinout, chip specs |
| [1-Build-Environment](./1-Build-Environment/) | Toolchains (Lexra MIPS + ARM GCC + Silabs slc-cli) |
| [2-Zigbee-Radio-Silabs-EFR32](./2-Zigbee-Radio-Silabs-EFR32/) | EFR32 firmware: bootloader, NCP, RCP, OT-RCP, router |
| [3-Main-SoC-Realtek-RTL8196E](./3-Main-SoC-Realtek-RTL8196E/) | Linux system: bootloader, kernel, rootfs, userdata |

### Scripts

**Install, backup & flash** (repository root):

| Script | Description |
|--------|-------------|
| [`flash_install_rtl8196e.sh`](./flash_install_rtl8196e.sh) | **Install custom firmware** — builds fullflash.bin, uploads via TFTP, auto-flashes (V2) or guides FLW (older bootloaders) |
| [`build_fullflash.sh`](./build_fullflash.sh) | Build a complete 16 MiB flash image from all 4 partitions |
| [`backup_gateway.sh`](./backup_gateway.sh) | Back up the full flash — auto-detects gateway state (SSH or bootloader) |
| [`restore_gateway.sh`](./restore_gateway.sh) | Restore a fullflash.bin backup — guides through TFTP + FLW |
| [`flash_rtl8196e.sh`](./flash_rtl8196e.sh) | Flash individual partitions via TFTP (for developers) |
| [`flash_efr32.sh`](./flash_efr32.sh) | Flash the Zigbee/Thread radio over SSH (OTA via universal-silabs-flasher) |

**Per-component build & flash** (in subdirectories):

| Script | Description |
|--------|-------------|
| [`31-Bootloader/build_bootloader.sh`](./3-Main-SoC-Realtek-RTL8196E/31-Bootloader/build_bootloader.sh) | Build the RTL8196E bootloader |
| [`31-Bootloader/flash_bootloader.sh`](./3-Main-SoC-Realtek-RTL8196E/31-Bootloader/flash_bootloader.sh) | Flash bootloader only (TFTP) |
| [`32-Kernel/build_kernel.sh`](./3-Main-SoC-Realtek-RTL8196E/32-Kernel/build_kernel.sh) | Build the Linux kernel |
| [`32-Kernel/flash_kernel.sh`](./3-Main-SoC-Realtek-RTL8196E/32-Kernel/flash_kernel.sh) | Flash kernel only (TFTP) |
| [`33-Rootfs/build_rootfs.sh`](./3-Main-SoC-Realtek-RTL8196E/33-Rootfs/build_rootfs.sh) | Build the root filesystem |
| [`33-Rootfs/flash_rootfs.sh`](./3-Main-SoC-Realtek-RTL8196E/33-Rootfs/flash_rootfs.sh) | Flash rootfs only (TFTP) |
| [`34-Userdata/build_userdata.sh`](./3-Main-SoC-Realtek-RTL8196E/34-Userdata/build_userdata.sh) | Build the JFFS2 userdata partition |
| [`34-Userdata/flash_userdata.sh`](./3-Main-SoC-Realtek-RTL8196E/34-Userdata/flash_userdata.sh) | Flash userdata only (TFTP) |
| [`remote_flash.sh`](./3-Main-SoC-Realtek-RTL8196E/remote_flash.sh) | Remote flash via SSH (boothold + TFTP, no serial needed) |

**Backup utilities** (in `30-Backup-Restore/`):

| Script | Description |
|--------|-------------|
| [`split_flash.sh`](./3-Main-SoC-Realtek-RTL8196E/30-Backup-Restore/split_flash.sh) | Split a 16 MB full flash into individual partition files |
| [`restore_mtd_via_ssh.sh`](./3-Main-SoC-Realtek-RTL8196E/30-Backup-Restore/scripts/restore_mtd_via_ssh.sh) | Restore partitions via SSH (original Tuya firmware only) |

## Building from Source

Pre-built images are included in the repository. If you want to customize:

**Native (Ubuntu 22.04 / WSL2):**

```bash
cd 1-Build-Environment && sudo ./install_deps.sh
```

**Docker (any OS):**

```bash
cd 1-Build-Environment && docker build -t lidl-gateway-builder .
docker run -it --rm -v $(pwd)/..:/workspace lidl-gateway-builder
```

Then build and flash:

```bash
# Build the Linux system
cd 3-Main-SoC-Realtek-RTL8196E/32-Kernel && ./build_kernel.sh
cd ../33-Rootfs && ./build_rootfs.sh
cd ../.. && ./flash_install_rtl8196e.sh

# Build and flash a Zigbee firmware
cd 2-Zigbee-Radio-Silabs-EFR32/24-NCP-UART-HW && ./build_ncp.sh
cd ../.. && ./flash_efr32.sh <GATEWAY_IP>
```

See [1-Build-Environment](./1-Build-Environment/) for details.

______________________________________________________________________

## Credits

This project builds upon the initial research by [Paul Banks](https://paulbanks.org/projects/lidl-zigbee/).
No need to crack the root password — access to the Realtek bootloader prompt
(serial console, press ESC on power-on) is all you need to flash the gateway.

## License

MIT License — See [LICENSE](./LICENSE) for details.
