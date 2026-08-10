# RTL8196E Gateway — Open Linux Firmware

> 📢 **Renamed project:** formerly `hacking-lidl-silvercrest-gateway` — the
> same project, now covering the Sengled G4 and other RTL8196E gateways. Old
> GitHub links redirect automatically; the documentation now lives at the
> **[project documentation site](https://jnilo1.github.io/rtl8196e-gateway/)**.
>
> ⭐ **Is this project useful to you? Please consider
> [giving it a GitHub star](https://github.com/jnilo1/rtl8196e-gateway).** It
> helps others discover the project and motivates continued development.
>
> 💬 Questions and setup help: **[Discussions](https://github.com/jnilo1/rtl8196e-gateway/discussions)** ·
> Reproducible bug: **[open an Issue](https://github.com/jnilo1/rtl8196e-gateway/issues)**

Replace the cloud firmware on a supported smart-home gateway with a small,
fully local Linux system. The gateway can then serve as a Zigbee coordinator,
a Thread Border Router, or a standalone Zigbee router.

Supported boards include the **Lidl Silvercrest / Tuya gateway** and the
**Sengled Smart Hub G4 (E39-G8C)**. Pre-built images are included; rebuilding
from source is optional.

> **First installation requires hardware access.** A stock Lidl/Tuya gateway
> must be opened and connected to a **3.3 V USB-to-UART adapter**. The serial
> connection is normally needed only once. Later upgrades use Ethernet and SSH.

## Start here

Choose the path that describes your gateway now:

| Your situation | Read this |
| --- | --- |
| Stock Lidl/Silvercrest gateway with Tuya firmware | **[First installation](./docs/getting-started.md)** |
| Stock Sengled Smart Hub G4 | [Sengled hardware notes](./0-Hardware/sengled-e39-g8c/README.md), then [first installation](./docs/getting-started.md) |
| Gateway already running this project | **[Upgrade guide](./docs/upgrading.md)** |
| Unsure which Zigbee or Thread firmware to use | **[Choose a radio mode](./docs/radio-options.md)** |
| Something is not working | **[Troubleshooting](./docs/troubleshooting.md)** |
| Want to modify or rebuild the firmware | [Developer path](#for-developers) |

If this is your first embedded-Linux project, follow the first-installation
guide in order. It explains the physical connection, backup, serial terminal,
network setup, flashing, and post-install checks. Experienced users can use the
short checklist at the top of that page.

## What the project provides

- **Local Zigbee coordinator** for Zigbee2MQTT or ZHA, with no vendor cloud
- **Thread Border Router** with `otbr-agent` running on the gateway
- **Modern host-side Zigbee stack** using RCP, `cpcd`, and `zigbeed`
- **Standalone Zigbee router** to extend an existing mesh
- **SSH access** to BusyBox Linux with persistent configuration
- **Network updates** for both the Linux system and the EFR32 radio
- **Pre-built firmware** plus reproducible build recipes

For most people who want to use Zigbee2MQTT or ZHA, the recommended setup is
the **NCP firmware**. It exposes the radio at:

```text
tcp://<gateway-ip>:8888
```

See [Choose a radio mode](./docs/radio-options.md) before selecting RCP,
OpenThread, or router firmware.

## What the first installation involves

A gateway contains two independent processors:

```text
Home Assistant / Zigbee2MQTT
             |
          Ethernet
             |
  RTL8196E running Linux
             |
           UART1
             |
  EFR32 Zigbee/Thread radio
```

The installation therefore has two firmware stages:

1. Prepare the host, network choice, SSH key, hostname, and timezone.
2. Back up the original 16 MiB flash.
3. Open the gateway and connect the RTL8196E serial console.
4. Flash the Linux system through the Realtek bootloader and TFTP; only its
   network mode is selected at this stage.
5. Boot Linux, change the default password, install the SSH key and settings.
6. Flash the EFR32 radio over the network for your chosen use case;
   `flash_efr32.sh` generates the matching radio configuration automatically.

The [first-installation guide](./docs/getting-started.md) includes the existing
PCB photo, the J1 pinout, safe UART wiring, and the complete command sequence.

## Supported hardware

| Board | `BOARD` value | Default kernel | Notes |
| --- | --- | --- | --- |
| Lidl Silvercrest / Tuya reference board | `lidl` | Linux 6.18 | Default; do not set `BOARD` |
| Sengled Smart Hub G4 (E39-G8C) | `sengled-e39-g8c` | Linux 6.18 | Board-specific bootloader, kernel, and radio images |

Linux 7.1 is also available as an alternate kernel line. New users should keep
the production default, Linux 6.18. Board and kernel choices are explained in
the [install and upgrade reference](./3-Main-SoC-Realtek-RTL8196E/35-Migration/README.md).

Other RTL8196E gateways can be ported through devicetree and per-board build
data. Start with the [board-porting documentation](./2-Zigbee-Radio-Silabs-EFR32/boards/README.md)
and the component-specific developer guides.

## After installation

The normal administration surface is SSH on port 22. The fresh image uses
`root` / `root`; change that password immediately:

```bash
ssh root@<gateway-ip>
passwd
```

Then continue with [Using and maintaining the gateway](./docs/using-the-gateway.md)
for SSH keys, network settings, backups, LEDs, radio state, and recovery.

The Zigbee bridge on TCP port 8888 has no application-level authentication.
Keep it on a trusted LAN or bind it to loopback and use an SSH tunnel; see the
[UART bridge security guide](./3-Main-SoC-Realtek-RTL8196E/32-Kernel/files-6.18/drivers/net/rtl8196e-uart-bridge/SECURITY.md).

## Documentation map

### User guides

- [First installation](./docs/getting-started.md)
- [Choose a radio mode](./docs/radio-options.md)
- [Upgrade an existing installation](./docs/upgrading.md)
- [Use and maintain the gateway](./docs/using-the-gateway.md)
- [Troubleshooting](./docs/troubleshooting.md)

### Hardware and firmware reference

- [Hardware, case, PCB, and serial header](./0-Hardware/README.md)
- [Backup and restore](./3-Main-SoC-Realtek-RTL8196E/30-Backup-Restore/README.md)
- [EFR32 radio firmware](./2-Zigbee-Radio-Silabs-EFR32/README.md)
- [RTL8196E Linux system](./3-Main-SoC-Realtek-RTL8196E/README.md)

## For developers

Normal installation uses pre-built files and needs only a few host packages.
Do not install the complete toolchain unless you intend to rebuild firmware.

- [Build environment](./1-Build-Environment/README.md) — Docker or native Ubuntu/WSL2
- [RTL8196E bootloader](./3-Main-SoC-Realtek-RTL8196E/31-Bootloader/README.md)
- [Linux kernel](./3-Main-SoC-Realtek-RTL8196E/32-Kernel/README.md)
- [Root filesystem](./3-Main-SoC-Realtek-RTL8196E/33-Rootfs/README.md)
- [Persistent userdata](./3-Main-SoC-Realtek-RTL8196E/34-Userdata/README.md)
- [Silabs EFR32 firmware](./2-Zigbee-Radio-Silabs-EFR32/README.md)

## Credits and license

This project builds on the initial research by
[Paul Banks](https://paulbanks.org/projects/lidl-zigbee/). It is released under
the [MIT License](https://github.com/jnilo1/rtl8196e-gateway/blob/main/LICENSE).
