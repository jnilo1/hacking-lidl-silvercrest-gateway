# Zigbee Radio — Silabs EFR32MG1B

This section covers the **Zigbee coprocessor** embedded in the gateway: a Silabs EFR32MG1B chip running dedicated wireless firmware.

## Overview

The EFR32MG1B handles all Zigbee radio communication. The stock firmware uses the Tuya protocol, but it can be replaced with open-source alternatives to work with **Zigbee2MQTT**, **ZHA**, or **Matter/Thread**.

## Build All Firmware

```bash
# Using Docker (from 1-Build-Environment/)
docker run -it --rm -v $(pwd)/..:/workspace lidl-gateway-builder \
    /workspace/2-Zigbee-Radio-Silabs-EFR32/build_efr32.sh

# Or native
./build_efr32.sh              # Build all 5 firmware variants
./build_efr32.sh ncp rcp      # Build specific targets
./build_efr32.sh --help       # Show available targets
```

> **Per-board builds:** the NCP and OT-RCP firmwares take a `BOARD=` parameter
> (default `lidl`). For the **Sengled Smart Hub G4** use `BOARD=sengled-e39-g8c` —
> its NCP is validated on real G4 hardware (#130) and ships **prebuilt**, so a G4
> user can flash it directly (`BOARD=sengled-e39-g8c ./flash_efr32.sh -y ncp`); G4
> OT-RCP builds but isn't Thread-validated yet, so build it yourself. See
> [`boards/README.md`](./boards/README.md) for the supported boards and the
> porting contract. RCP, Router and the bootloader are lidl-only for now.
> `flash_efr32.sh` honours the same `BOARD=` (a Lidl user sets nothing) and refuses
> a board mismatch against the gateway's devicetree model.

## Contents

| Directory | Description |
|-----------|-------------|
| [20-EZSP-Reference](./20-EZSP-Reference/README.md) | Introduction to EZSP protocol and EmberZNet stack |
| [21-Simplicity-Studio](./21-Simplicity-Studio/README.md) | Build your own firmware with Silabs IDE |
| [22-Backup-Flash-Restore](./22-Backup-Flash-Restore/README.md) | Backup, flash, and restore the Zigbee chip firmware |
| [23-Bootloader-UART-Xmodem](./23-Bootloader-UART-Xmodem/README.md) | Flash firmware via UART using Gecko bootloader |
| [24-NCP-UART-HW](./24-NCP-UART-HW/README.md) | NCP firmware for Zigbee2MQTT and ZHA |
| [25-RCP-UART-HW](./25-RCP-UART-HW/README.md) | RCP firmware: EmberZNet 8.2.2 / EZSP v18 via host-side `zigbeed` |
| [26-OT-RCP](./26-OT-RCP/README.md) | OpenThread RCP firmware for zigbee-on-host or Thread/Matter |
| [27-Router](./27-Router/README.md) | Zigbee 3.0 Router SoC firmware to extend mesh network |

## Firmware: NCP (Network Co-Processor)

- The Zigbee stack runs on the EFR32
- Simple setup: just flash and connect to Zigbee2MQTT or ZHA
- Recommended for most users who want a Zigbee coordinator

## Firmware: RCP (Radio Co-Processor)

Two RCP options are available:

### RCP with cpcd + zigbeed (25-RCP-UART-HW)

- Uses Silicon Labs' CPC protocol (Co-Processor Communication)
- Runs with cpcd + zigbeed on the host
- Modern stack on Series 1 hardware: **EmberZNet 8.2.2 / EZSP v18** (zigbeed runs host-side, so the EFR32MG1B is no longer the bottleneck)
- Single-stack only — Zigbee+Thread concurrently is not supported on this gateway (Series 1 has no Concurrent Multiprotocol; reflash with OT-RCP for Thread/Matter)

### OpenThread RCP (26-OT-RCP)

- Standard OpenThread RCP firmware (Spinel/HDLC, fully open-source)
- **One firmware, three use cases:**
  - **ZoH** — Zigbee on host via [zigbee-on-host](https://github.com/Nerivec/zigbee-on-host), integrated in Zigbee2MQTT 2.x as the `zoh` adapter
  - **OTBR on host** — Thread / Matter-over-Thread, OTBR running on an external PC/Pi
  - **OTBR on gateway** — Thread / Matter-over-Thread, OTBR running natively on the RTL8196E
- Same `.gbl`, you switch use case by changing what runs host-side — no EFR32 reflash

## Firmware: Router (SoC)

- Standalone Zigbee 3.0 router, no host required
- Extends your Zigbee mesh network coverage
- Auto-joins open networks via network steering
- Transforms the gateway into a dedicated range extender

## Gateway-side runtime configuration

Flashing the EFR32 is only **half** of the configuration — the
**RTL8196E side** also needs to know which firmware is on the chip
and at what baud, so the right init script wakes up at boot:

```
EFR32 firmware (.gbl)        radio.conf daemon-routing keys   init script        What runs
                              on RTL8196E                      starts at boot     on /dev/ttyS1
─────────────────────────    ──────────────────────────────   ───────────────   ────────────────
NCP                          FIRMWARE_BAUD=<B>                S50uart_bridge    bridge TCP:8888
RCP                          FIRMWARE_BAUD=<B>                S50uart_bridge    bridge TCP:8888
OT-RCP (case 3, default)     FIRMWARE_BAUD=<B> + MODE=otbr    S70otbr           otbr-agent (native)
OT-RCP (cases 1 & 2)         FIRMWARE_BAUD=<B> (no MODE)      S50uart_bridge    bridge TCP:8888
Router                       FIRMWARE_BAUD=115200             S50uart_bridge    bridge TCP:8888
```

The repo-root `flash_efr32.sh` writes the right `radio.conf` keys
**automatically** after a successful flash — for OT-RCP it picks **case 3**
(otbr-agent on gateway) by default, and you switch to cases 1/2 by
editing `radio.conf` after the flash (see
[`26-OT-RCP/docker/README.md`](./26-OT-RCP/docker/README.md#switching-radio-mode-no-efr32-reflash-needed)).

The script also writes informational keys describing the chip-side
identity (`FIRMWARE`, `FIRMWARE_VERSION`) so a `cat /userdata/etc/radio.conf`
tells you exactly what's on the chip without an
`universal-silabs-flasher probe`. See
[`3-Main-SoC-Realtek-RTL8196E/34-Userdata/README.md`](../3-Main-SoC-Realtek-RTL8196E/34-Userdata/README.md#radioconf-keys-full-reference)
for the full key reference.

For all other firmwares, no manual `radio.conf` edit is needed — the
flash script's choice is the only choice.

`radio.conf` is documented in
[`3-Main-SoC.../34-Userdata/`](../3-Main-SoC-Realtek-RTL8196E/34-Userdata/);
the keys are:

| Key | Read by | Purpose |
|---|---|---|
| `MODE=otbr` | `S50uart_bridge`, `S70otbr` | Switches ttyS1 ownership: present → `S70otbr` runs `otbr-agent`; absent → `S50uart_bridge` arms the TCP bridge |
| `FIRMWARE_BAUD=<baud>` | `S50uart_bridge`, `S70otbr` | UART baud both daemons open `/dev/ttyS1` at — single source of truth, set by `flash_efr32.sh` (default 460800 if absent) |
