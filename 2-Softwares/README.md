### RTL8196E Gateway – Software Stack Documentation

This document describes the software environment of a custom Zigbee gateway
based on the Realtek RTL8196E SoC, modified to serve as a TCP-to-UART
bridge for a Silicon Labs EFR32 Zigbee module.

______________________________________________________________________

## 🧠 Operating System

- **Linux Kernel**: 3.10.90
- Build date: April 28, 2020
- Compiler: GCC 4.6.4 (Realtek RSDK-4.6.4 Build 2080)
- Target architecture: MIPS32 (Lexra RLX4181), big-endian

______________________________________________________________________

## 🧰 Toolchain & Libraries

- **Toolchain**: Realtek RSDK 4.6.4
- **libc**: uClibc 0.9.33
- **BusyBox**: v1.13.4 (compiled on 2020-04-28)

These components form the foundation of a minimal Linux userland, with
BusyBox handling init, shell, and all base utilities.

______________________________________________________________________

## 📂 Filesystem Layout

The flash is divided into several MTD partitions (total size: **0x1000000**
= **16 MiB**):

| Device    | Name       | Size (hex) | Size (dec) | Description                       |
| --------- | ---------- | ---------- | ---------- | --------------------------------- |
| /dev/mtd0 | boot+cfg   | 0x0020000  | 131072     | Bootloader and configuration      |
| /dev/mtd1 | linux      | 0x01e0000  | 1966080    | Kernel image                      |
| /dev/mtd2 | rootfs     | 0x0200000  | 2097152    | SquashFS, read-only               |
| /dev/mtd3 | tuya-label | 0x0020000  | 131072     | Metadata (currently empty)        |
| /dev/mtd4 | jffs2-fs   | 0x0be0000  | 12451840   | Persistent data, writable (JFFS2) |

Mount layout includes:

- `/` → SquashFS root
- `/tuya` → JFFS2 overlay for writable storage
- `/dev` → tmpfs
- `/var` → ramfs

**Note**: The `tuya-label` partition is useless in our configuration. It
was likely reserved for Tuya-specific metadata (e.g. device ID, cloud
keys), but is not used in this hacked version of the gateway.

Also note: the total of all partition sizes adds up precisely to
**0x1000000 (16 MiB)**, which matches the capacity of the onboard SPI flash
(GD25Q127 identified by linux as GD25Q128).

______________________________________________________________________

## 🔌 Zigbee Bridge Functionality

### Hardware:

- The TuYa TYZS4A chip is hiding a Silicon Labs **EFR32MG1B232F256GM48**
  Zigbee SoC connected via **UART0** to the RTL8196E's **UART1**
  (`/dev/ttyS1`).

- The EFR32 is flashed with a **NCP-UART-HW** firmware.

  - This firmware implements the **EZSP protocol** (Ember Zigbee Serial
    Protocol), a binary, frame-based API developed by Silicon Labs.
  - EZSP allows a host processor (e.g. Linux) to control a Zigbee Network
    Co-Processor (NCP) like the EFR32 over a serial connection.
  - EZSP is the serial interface to **EmberZNet**, Silicon Labs' full
    Zigbee PRO stack.

#### EmberZNet vs EZSP — Key Differences:

- **EmberZNet** is the complete Zigbee stack running directly on Silicon
  Labs chips (like EFR32). It includes:

  - IEEE 802.15.4 PHY and MAC layers
  - Zigbee network layer (routing, mesh management)
  - Zigbee application layer (clusters, endpoints, command handling)
  - Can run in two modes:
    - **NCP (Network Co-Processor)**: Stack runs on the chip, controlled
      via EZSP
    - **SoC (System-on-Chip)**: Entire application and stack run on the
      chip

- **EZSP** is a serial protocol designed to let an external host control a
  chip running EmberZNet in NCP mode. It provides commands for:

  - Network formation and joining
  - Message sending and receiving
  - Cluster and endpoint management
  - Security and Zigbee stack control
  - In **NCP mode**, the chip runs the full Zigbee stack and EZSP exposes
    its control interface
  - In **RCP (Radio Co-Processor)** mode (used with Thread/OpenThread),
    only the radio MAC/PHY runs on the chip, and the Zigbee stack runs on
    the host.

- Different versions of the **EmberZNet** protocol have been used:

  - **EmberZNet 6.5.0.0** uses **EZSP V7** and is provided in the original
    Lidl/Silvercrest gateway
  - **EmberZNet 6.7.8.0** uses **EZSP V8** and is provided in the "hacked"
    version originally proposed by Paul Banks.
    [The firmware](https://github.com/grobasoz/zigbee-firmware/raw/master/EFR32%20Series%201/EFR32MG1B-256k/NCP/NCP_UHW_MG1B232_678_PA0-PA1-PB11_PA5-PA4.gbl)
    was provided by Gary Robas.
  - **EmberZNet 7.4.x.0** uses **EZSP V13** and is made
    [available in this site](../gateway_firmware/NCP-UART-HW) from Silabs
    Gecko 4.4.x libraries and Simplicity Studio.

### Software:

- The RTL8196E system acts as a **TCP-to-UART bridge**, exposing
  `/dev/ttyS1` over the network.
- Two bridging solutions are available:
  - `serialgateway`: a lightweight custom daemon installed on the device
  - `ser2net`: a standard serial-to-network tool with support for multiple
    modes (raw, telnet, RFC2217)

### Usage:

- From a remote host, clients such as **Zigbee2MQTT** or **Home Assistant
  (ZHA)** can connect using TCP:

```yaml
# Zigbee2MQTT configuration.yaml
serial:
  port: tcp://192.168.1.x:8888
  # Note: adapter is ezsp (no more supported) for EmberZNet for 6.x up to 7.3 versions. and ember starting with Emberznet 7.4
  adapter: ember
```

- Either `serialgateway` (or `ser2net`) can be used to serve the UART over
  TCP port 8888.

Example `serialgateway` command:

```sh
/tuya/serialgateway &
```
