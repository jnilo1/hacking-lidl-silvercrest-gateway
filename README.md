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

The gateway must be in bootloader mode (serial console, press ESC on power-on).

```bash
git clone https://github.com/jnilo1/hacking-lidl-silvercrest-gateway.git
cd hacking-lidl-silvercrest-gateway
./flash_rtl8196e.sh
```

The script flashes bootloader, kernel, rootfs and userdata via TFTP, and asks
for the network configuration (static IP or DHCP).
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

Root-level scripts:

| Script | Description |
|--------|-------------|
| `flash_rtl8196e.sh` | Flash the Linux system via TFTP (bootloader mode required) |
| `flash_efr32.sh` | Flash the Zigbee radio over the network via SSH |

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
cd ../.. && ./flash_rtl8196e.sh

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
