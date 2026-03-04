# OpenThread RCP Firmware for Lidl Silvercrest Gateway

OpenThread Radio Co-Processor (RCP) firmware for the EFR32MG1B232F256GM48 chip found in the Lidl Silvercrest Smart Home Gateway.

This firmware transforms the gateway into an **OpenThread RCP** that works with **zigbee-on-host** (for Zigbee) or **Thread/Matter** networks.

## Features

- **OpenThread RCP** - Spinel/HDLC protocol over UART
- **zigbee-on-host compatible** - Works with Zigbee2MQTT 2.x `zoh` adapter
- **Thread/Matter ready** - Can be used for Thread border routers
- **Hardware radio acceleration** - All MAC operations in hardware
- **Minimal footprint** - ~100KB flash, ~16KB RAM

## About zigbee-on-host

This firmware works with [**zigbee-on-host**](https://github.com/Nerivec/zigbee-on-host), an open-source Zigbee stack developed by [@Nerivec](https://github.com/Nerivec).

Unlike proprietary solutions like Silicon Labs' zigbeed, zigbee-on-host is:
- **Fully open-source** - transparent, auditable, community-driven
- **Integrated in Zigbee2MQTT 2.x** as the `zoh` adapter
- **Actively developed** - contributions welcome!

> **Note:** zigbee-on-host is still under active development. Check the
> [GitHub repository](https://github.com/Nerivec/zigbee-on-host) for the latest
> updates, known issues, and to report bugs.

## Hardware

| Component | Specification |
|-----------|---------------|
| Zigbee SoC | EFR32MG1B232F256GM48 |
| Flash | 256KB |
| RAM | 32KB |
| Radio | 2.4GHz IEEE 802.15.4 |
| UART | PA0 (TX), PA1 (RX), PA4 (RTS), PA5 (CTS) @ 115200 baud |

---

## Option 1: Flash Pre-built Firmware (Recommended)

Pre-built firmware is available in the `firmware/` directory. From the repository root:

```bash
./flash_efr32.sh <GATEWAY_IP>
# Select [4] OT-RCP
```

The script handles everything (serialgateway restart, flash, reboot).

---

## Option 2: Build from Source

For users who want to customize the firmware or use a different SDK version.

### Prerequisites

Install Silicon Labs tools (see `1-Build-Environment/12-silabs-toolchain/`):

```bash
cd 1-Build-Environment/12-silabs-toolchain
./install_silabs.sh
```

This installs:
- `slc-cli` - Silicon Labs Configurator
- `arm-none-eabi-gcc` - ARM GCC toolchain
- `commander` - Simplicity Commander
- Gecko SDK with OpenThread

### Build

```bash
cd 2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP
./build_ot_rcp.sh
```

### Output

```
firmware/
├── ot-rcp.gbl   # For UART/Xmodem flashing
└── ot-rcp.s37   # For J-Link/SWD flashing
```

### Flash

**Via network (same as Option 1):**
```bash
./flash_efr32.sh <GATEWAY_IP>
# Select [4] OT-RCP
```

**Via J-Link/SWD** (if you have physical access to the SWD pads):
```bash
commander flash firmware/ot-rcp.s37 \
    --device EFR32MG1B232F256GM48
```

---

## Usage

### Architecture

The OT-RCP firmware supports two modes via separate Docker stacks:

**Zigbee** — Zigbee2MQTT with zigbee-on-host adapter:

```
Zigbee Devices                        Docker Host
       │  802.15.4                   ┌──────────────────────────┐
       ▼                             │  Zigbee2MQTT (zoh)       │
┌─────────────┐  UART   ┌────────┐  │  + zigbee-on-host stack  │
│  EFR32 RCP  │◄──────►│ serial  │◄─┤  Web UI :8080            │
│  Spinel/    │ 115200  │ gateway │  └──────────────────────────┘
│  HDLC       │         │ :8888   │
└─────────────┘         └────────┘
```

**Thread/Matter** — OTBR + Home Assistant + Companion App:

```
Matter Devices                        Docker Host
       │  Thread 802.15.4            ┌──────────────────────────┐
       ▼                             │  OTBR (border router)    │
┌─────────────┐  UART   ┌────────┐  │  REST API :8081          │
│  EFR32 RCP  │◄──────►│ serial  │◄─┤  Matter Server :5580     │
│  Spinel/    │ 115200  │ gateway │  │  Home Assistant :8123    │
│  HDLC       │         │ :8888   │  │  ← Companion App (BLE)  │
└─────────────┘         └────────┘  └──────────────────────────┘
```

The RTL8196E runs `serialgateway` to bridge the EFR32's UART to TCP port 8888.
See [34-Userdata](../../3-Main-SoC-Realtek-RTL8196E/34-Userdata/) for gateway setup.

### Docker Stacks

Pre-configured Docker Compose files are in [`docker/`](docker/README.md):

| Stack | Command | Use case |
|-------|---------|----------|
| Zigbee (zoh) | `docker compose -f docker-compose-zoh.yml up -d` | Zigbee2MQTT |
| Thread/Matter | `docker compose up -d` | OTBR + Home Assistant + Matter |

See [`docker/README.md`](docker/README.md) for full setup instructions
(IPv6 forwarding, HA integrations, Companion App commissioning, chip-tool alternative).

### Tested Devices

| Device | Protocol | Stack | Status |
|--------|----------|-------|--------|
| Xiaomi LYWSD03MMC | Zigbee | zoh | OK |
| IKEA TIMMERFLOTTE | Matter/Thread | OTBR + HA Companion App | OK (22.8 °C, 54.69 %) |

---

## Technical Details

### Memory Usage

| Resource | Used | Available |
|----------|------|-----------|
| Flash | ~100 KB | 256 KB |
| RAM | ~16 KB | 32 KB |

### UART Driver: uartdrv (not iostream)

OpenThread uses `uartdrv_usart` directly for Spinel/HDLC communication — **not** the `iostream_usart` component.

The distinction matters:

| Driver | Level | Usage |
|--------|-------|-------|
| `uartdrv_usart` | Low-level HAL, DMA, async | Spinel/HDLC binary protocol ← **this project** |
| `iostream_usart` | High-level stdio/printf abstraction (built on uartdrv) | Debug console, CLI, logs |

`iostream` adds text-oriented processing (LF→CRLF conversion, buffering) that would corrupt a binary Spinel stream. The OpenThread platform layer (`otSysProcessDrivers`) calls `uartdrv` APIs directly.

### Features

- **RTL8196E Boot Delay:** 1-second delay for host UART initialization
- **Hardware Flow Control:** RTS/CTS required for reliable TCP operation
- **Hardware Radio Acceleration:** All MAC operations in hardware

---

## Troubleshooting

### No response from RCP

1. Verify TCP connection: `nc -zv <gateway-ip> 8888`
2. Check baud rate matches (115200) on firmware and serialgateway
3. Verify hardware flow control is enabled

### HDLC Parsing Errors

1. Ensure baud rate is 115200 (not higher)
2. Check for Zigbee device flooding (remove battery from problematic devices)
3. Verify hardware flow control is enabled

### Device Won't Pair

1. Factory reset the device (hold button while inserting battery)
2. Ensure permit join is enabled in Z2M

---

## Files

```
26-OT-RCP/
├── build_ot_rcp.sh              # Build script
├── README.md                    # This file
├── patches/
│   ├── ot-rcp.slcp              # Project config (based on SDK sample)
│   ├── ot-rcp.slcp.sdk-original # Original SDK sample for reference
│   ├── main.c                   # Entry point (RTL8196E boot delay)
│   ├── app.c / app.h            # OT instance init + hardware watchdog
│   ├── sl_uartdrv_usart_vcom_config.h  # UART: 115200, HW flow control
│   └── sl_rail_util_pti_config.h       # PTI disabled (suppresses SDK warning)
├── docker/                      # Docker Compose stacks
│   ├── README.md                # Setup guide (Zigbee + Thread/Matter)
│   ├── docker-compose.yml       # Thread/Matter: OTBR + Matter Server + HA
│   ├── docker-compose-zoh.yml   # Zigbee: Mosquitto + Zigbee2MQTT (zoh)
│   ├── z2m/configuration.yaml   # Zigbee2MQTT config
│   └── mosquitto/mosquitto.conf # MQTT broker config
└── firmware/                    # Output (generated)
    ├── ot-rcp.gbl               # For UART flashing
    └── ot-rcp.s37               # For SWD flashing
```

---

## Related Projects

- `24-NCP-UART-HW/` - NCP firmware (EZSP protocol)
- `25-RCP-UART-HW/` - RCP firmware (CPC protocol, for cpcd + zigbeed)
- `27-Router/` - Autonomous Zigbee router (no host needed)

## References

- [zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) - Open-source Zigbee stack by Nerivec
- [Zigbee2MQTT](https://www.zigbee2mqtt.io/)
- [OpenThread RCP](https://openthread.io/platforms/co-processor)
- [bnutzer/docker-otbr-tcp](https://github.com/bnutzer/docker-otbr-tcp) - OTBR Docker image for TCP-based RCPs
- [Home Assistant Matter integration](https://www.home-assistant.io/integrations/matter/) - Official Matter documentation
- [Discussion #47](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/47) - Thread/Matter on the Lidl gateway

## License

Educational and personal use. Silicon Labs SDK components under their respective licenses.
