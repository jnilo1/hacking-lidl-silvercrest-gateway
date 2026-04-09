# OpenThread RCP Firmware for Lidl Silvercrest Gateway

OpenThread Radio Co-Processor (RCP) firmware for the EFR32MG1B232F256GM48 chip
found in the Lidl Silvercrest Smart Home Gateway.

This firmware transforms the EFR32 into a **raw 802.15.4 radio** using the
Spinel/HDLC protocol. It is the **single firmware** shared by all 3 use cases
described below.

---

## 1. Firmware

### Hardware

| Component | Specification |
|-----------|---------------|
| Zigbee SoC | EFR32MG1B232F256GM48 |
| Flash | 256 KB (firmware uses ~100 KB) |
| RAM | 32 KB (firmware uses ~16 KB) |
| Radio | 2.4 GHz IEEE 802.15.4 |
| UART | PA0 (TX), PA1 (RX), PA4 (RTS), PA5 (CTS) @ 115200 baud |

### Flash Pre-built Firmware (recommended)

From the repository root:

```bash
./flash_efr32.sh <GATEWAY_IP>
# Select [4] OT-RCP
```

The script handles serialgateway restart, flash, and reboot.

### Build from Source

For users who want to customize the firmware or use a different SDK version.

```bash
# Install Silicon Labs tools (once)
cd 1-Build-Environment/12-silabs-toolchain && ./install_silabs.sh

# Build
cd 2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP
./build_ot_rcp.sh
```

Output: `firmware/ot-rcp.gbl` (UART flash) and `firmware/ot-rcp.s37` (J-Link/SWD).

### Technical Notes

- **UART driver:** Uses `uartdrv_usart` (low-level, DMA, async), not `iostream_usart`
  which would corrupt the binary Spinel stream with LF→CRLF conversion.
- **RTL8196E boot delay:** 1-second delay at startup for host UART initialization.
- **Hardware flow control:** RTS/CTS enabled, required for reliable operation over TCP.
- **Hardware radio acceleration:** All 802.15.4 MAC operations in hardware.
- **Baud rate: 115200 recommended.** Only **115200** and **230400** are
  reliable on this gateway (460800+ causes UART overruns — see
  [25-RCP-UART-HW](../25-RCP-UART-HW/README.md#baudrate-and-network-considerations)).
  All pre-built firmware uses 115200 to match the Gecko Bootloader. If you
  recompile at 230400, `flash_efr32.sh` will automatically detect it, send a
  Spinel reset-to-bootloader command, and reflash via the Gecko Bootloader —
  no J-Link/SWD needed.

---

## 2. Use Cases

All 3 use cases run the **same OT-RCP firmware** on the EFR32. They differ in
what runs on the gateway's RTL8196E main CPU and on the Docker host.

| # | Use case | Protocol | Gateway runs | Host runs (Docker) |
|---|----------|----------|-------------|---------------------|
| 1 | **ZoH** | Zigbee | serialgateway | Zigbee2MQTT + Mosquitto |
| 2 | **OTBR on host** | Thread/Matter | serialgateway | OTBR + Matter Server + HA |
| 3 | **OTBR on gateway** | Thread/Matter | otbr-agent (native) | Matter Server + HA |

### Use case 1: ZoH (Zigbee on Host)

The Zigbee stack ([zigbee-on-host](https://github.com/Nerivec/zigbee-on-host)
by [@Nerivec](https://github.com/Nerivec)) runs on the host via Zigbee2MQTT's
`zoh` adapter. The gateway only bridges UART to TCP.

```
Zigbee Devices                        Docker Host
       │  802.15.4                  ┌──────────────────────────┐
       ▼                            │  Zigbee2MQTT (zoh)       │
┌─────────────┐  UART   ┌────────┐  │  + zigbee-on-host stack  │
│  EFR32 RCP  │◄──────► │ serial │◄─┤  Web UI :8080            │
│  Spinel/    │ 115200  │ gateway│  └──────────────────────────┘
│  HDLC       │         │ :8888  │
└─────────────┘         └────────┘
     Gateway (Zigbee mode)
```

**Gateway setup:** flash userdata in **Zigbee** mode.
**Quick start:** see [`docker/README.md` — Use Case 1](docker/README.md#use-case-1-zoh--zigbee-zigbee-on-host).

> zigbee-on-host is open-source, integrated in Zigbee2MQTT 2.x, and under
> active development. See the [GitHub repo](https://github.com/Nerivec/zigbee-on-host).

### Use case 2: OTBR on Host

OTBR runs in a Docker container on the host PC. It connects to the gateway's
`serialgateway` over TCP to reach the EFR32 radio.

```
Matter Devices                        Docker Host
       │  Thread 802.15.4           ┌──────────────────────────┐
       ▼                            │  OTBR (Docker container) │
┌─────────────┐  UART   ┌────────┐  │  REST API :8081          │
│  EFR32 RCP  │◄──────► │ serial │◄─┤  Matter Server :5580     │
│  Spinel/    │ 115200  │ gateway│  │  Home Assistant :8123    │
│  HDLC       │         │ :8888  │  │  ← Companion App (BLE)   │
└─────────────┘         └────────┘  └──────────────────────────┘
     Gateway (Zigbee mode)
```

**Gateway setup:** flash userdata in **Zigbee** mode (serialgateway bridges
the radio to TCP; OTBR runs on the host).
**Quick start:** see [`docker/README.md` — Use Case 2](docker/README.md#use-case-2-otbr-on-host--threadmatter-docker).

### Use case 3: OTBR on Gateway (v2.0+)

OTBR runs **natively on the gateway** (otbr-agent on the RTL8196E CPU).
No serialgateway, no TCP bridge between OTBR and the radio. The host only
runs Matter Server + Home Assistant.

```
Matter Devices                                       Docker Host
       │  Thread 802.15.4                          ┌──────────────────┐
       ▼                                           │  Matter Server   │
┌─────────────┐  UART   ┌──────────────────┐  REST │  :5580           │
│  EFR32 RCP  │◄──────► │  otbr-agent      │◄──────┤  Home Assistant  │
│  Spinel/    │ 115200  │  (native on CPU) │ :8081 │  :8123           │
│  HDLC       │         │  REST API :8081  │       │  ← Companion App │
└─────────────┘         └──────────────────┘       └──────────────────┘
     Gateway (Thread mode)
```

**Gateway setup:** flash userdata in **Thread** mode.

**Advantages over use case 2:**
- Lower latency — OTBR talks directly to the EFR32 via UART
- Simpler — no OTBR Docker container to manage
- Self-contained — Thread mesh stays up even without the host

This is the **recommended setup** for Thread/Matter since v2.0.
**Quick start:** see [`docker/README.md` — Use Case 3](docker/README.md#use-case-3-otbr-on-gateway--threadmatter-native-v20).

---

## 3. Docker Stacks

Pre-configured Docker Compose files are in [`docker/`](docker/README.md):

| # | Use case | Compose file | Command |
|---|----------|-------------|---------|
| 1 | ZoH | `docker-compose-zoh.yml` | `docker compose -f docker-compose-zoh.yml up -d` |
| 2 | OTBR on host | `docker-compose-otbr-host.yml` | `docker compose -f docker-compose-otbr-host.yml up -d` |
| 3 | OTBR on gateway | `docker-compose-otbr-gateway.yml` | `docker compose -f docker-compose-otbr-gateway.yml up -d` |

See [`docker/README.md`](docker/README.md) for full setup instructions:
IPv6 forwarding, HA integrations, Companion App commissioning, chip-tool
alternative, and troubleshooting.

---

## 4. Tested Devices

| Device | Protocol | Use case | Status |
|--------|----------|----------|--------|
| Xiaomi LYWSD03MMC | Zigbee | 1 (ZoH) | OK |
| IKEA TIMMERFLOTTE temp/hmd sensor | Matter/Thread | 2 (OTBR host) | OK |
| IKEA TIMMERFLOTTE temp/hmd sensor | Matter/Thread | 3 (OTBR gateway) | OK |
| IKEA BILRESA dual button | Matter/Thread | 3 (OTBR gateway) | OK |
| IKEA MYGGSPRAY wrlss mtn sensor | Matter/Thread | 3 (OTBR gateway) | OK |

---

## Troubleshooting

### No response from RCP

1. Verify TCP connection: `nc -zv <gateway-ip> 8888`
2. Check baud rate matches (115200) on firmware and serialgateway
3. Verify hardware flow control is enabled

### HDLC Parsing Errors

1. Ensure baud rate is 115200 (not higher)
2. Check for device flooding (remove battery from problematic devices)
3. Verify hardware flow control is enabled

---

## Files

```
26-OT-RCP/
├── build_ot_rcp.sh              # Build script
├── README.md                    # This file
├── THREAD-MATTER-PRIMER.md      # Educational guide: Thread vs Zigbee vs Matter
├── patches/
│   ├── ot-rcp.slcp              # Project config (based on SDK sample)
│   ├── main.c                   # Entry point (RTL8196E boot delay)
│   ├── app.c / app.h            # OT instance init + hardware watchdog
│   ├── sl_uartdrv_usart_vcom_config.h  # UART: 115200, HW flow control
│   └── sl_rail_util_pti_config.h       # PTI disabled (suppresses SDK warning)
├── docker/                      # Docker Compose stacks
│   ├── README.md                # Full setup guide (3 use cases)
│   ├── docker-compose-zoh.yml           # Use case 1: ZoH
│   ├── docker-compose-otbr-host.yml     # Use case 2: OTBR on host
│   ├── docker-compose-otbr-gateway.yml  # Use case 3: OTBR on gateway
│   ├── z2m/configuration.yaml   # Zigbee2MQTT config
│   └── mosquitto/mosquitto.conf # MQTT broker config
└── firmware/                    # Pre-built binaries
    ├── ot-rcp.gbl               # For UART flashing
    └── ot-rcp.s37               # For SWD flashing
```

---

## Related Projects

- `24-NCP-UART-HW/` — NCP firmware (EZSP protocol)
- `25-RCP-UART-HW/` — RCP firmware (CPC protocol, for cpcd + zigbeed)
- `27-Router/` — Autonomous Zigbee router (no host needed)
- `3-Main-SoC.../34-Userdata/` — Gateway firmware with native OTBR (v2.0+)

## References

- [zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) — Open-source Zigbee stack by Nerivec
- [Zigbee2MQTT](https://www.zigbee2mqtt.io/)
- [OpenThread RCP](https://openthread.io/platforms/co-processor)
- [bnutzer/docker-otbr-tcp](https://github.com/bnutzer/docker-otbr-tcp) — OTBR Docker image for TCP-based RCPs
- [Home Assistant Matter integration](https://www.home-assistant.io/integrations/matter/)
- [Discussion #47](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/47) — Thread/Matter on the Lidl gateway

## License

Educational and personal use. Silicon Labs SDK components under their respective licenses.
