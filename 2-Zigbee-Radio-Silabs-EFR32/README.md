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

## Contents

| Directory | Description |
|-----------|-------------|
| [20-EZSP-Reference](./20-EZSP-Reference/README.md) | Introduction to EZSP protocol and EmberZNet stack |
| [21-Simplicity-Studio](./21-Simplicity-Studio/README.md) | Build your own firmware with Silabs IDE |
| [22-Backup-Flash-Restore](./22-Backup-Flash-Restore/README.md) | Backup, flash, and restore the Zigbee chip firmware |
| [23-Bootloader-UART-Xmodem](./23-Bootloader-UART-Xmodem/README.md) | Flash firmware via UART using Gecko bootloader |
| [24-NCP-UART-HW](./24-NCP-UART-HW/README.md) | NCP firmware for Zigbee2MQTT and ZHA |
| [25-RCP-UART-HW](./25-RCP-UART-HW/README.md) | RCP firmware with cpcd + zigbeed for multiprotocol support |
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
- Native multiprotocol support (Zigbee + Thread simultaneously)
- Proprietary but well-supported by Silicon Labs

### OpenThread RCP with zigbee-on-host (26-OT-RCP)

- Standard OpenThread RCP firmware
- Works with [zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) (fully open-source)
- Integrated in Zigbee2MQTT 2.x as the `zoh` adapter
- Simpler setup, community-driven development

## Firmware: Router (SoC)

- Standalone Zigbee 3.0 router, no host required
- Extends your Zigbee mesh network coverage
- Auto-joins open networks via network steering
- Transforms the gateway into a dedicated range extender
