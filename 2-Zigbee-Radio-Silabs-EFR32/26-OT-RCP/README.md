# OpenThread RCP Firmware

OpenThread Radio Co-Processor (RCP) firmware for the EFR32 radio:
EFR32MG1B232F256GM48 on the Lidl Silvercrest Smart Home Gateway
(`BOARD=lidl`, the default), EFR32MG13P732F512IM32 on the Sengled Smart Hub G4
(`BOARD=sengled-e39-g8c`). Both ship prebuilt.

This firmware transforms the EFR32 into a **raw 802.15.4 radio** using the
Spinel/HDLC protocol. It is the **single firmware** shared by all 3 use cases
described below.

> **Multi-board:** this firmware also builds for other RTL8196E hubs via `BOARD=`
> (default `lidl`); e.g. `BOARD=sengled-e39-g8c` for the Sengled Smart Hub G4,
> whose UART routing was confirmed on hardware (#130). Its prebuilt is committed
> at **230400** — the operating point @hlyi measured on that board (#134, #142),
> where 460800 overruns the host's 16-byte RX FIFO — and `flash_efr32.sh` picks
> it there by default. See [`../boards/README.md`](../boards/README.md).

---

## 1. Firmware

### Hardware

| Component | Specification |
|-----------|---------------|
| Zigbee SoC | EFR32MG1B232F256GM48 |
| Flash | 256 KB (firmware uses ~100 KB) |
| RAM | 32 KB (firmware uses ~16 KB) |
| Radio | 2.4 GHz IEEE 802.15.4 |
| UART | PA0 (TX), PA1 (RX), PA4 (RTS), PA5 (CTS) @ 460800 baud |

### Flash Pre-built Firmware (recommended)

From the repository root:

```bash
# Lidl Silvercrest (default board and default baud 460800)
./flash_efr32.sh -y otrcp                    # gateway from gateway.env
./flash_efr32.sh -y -g 10.0.0.5 otrcp        # custom IP

# Sengled Smart Hub G4: board-safe default baud 230400
./flash_efr32.sh -y --board sengled-e39-g8c -g 10.0.0.6 otrcp

./flash_efr32.sh --help                      # full CLI reference
```

The script handles everything: pulse `nRST` for a clean chip state, switch
the in-kernel UART bridge to flash mode, run the Xmodem upload, then write
**`FIRMWARE=otrcp` + `FIRMWARE_BAUD=460800` + `MODE=otbr`** to
`/userdata/etc/radio.conf` so `S70otbr` launches `otbr-agent` on next
boot — that's **use case 3** below (OTBR on gateway).

For **use case 1 (ZoH)** or **use case 2 (OTBR on host)**, drop the
`MODE=otbr` line so `S50uart_bridge` takes over instead — see
[`docker/README.md`](docker/README.md) for the per-use-case Quick Start
that includes the radio-mode switch.

> OT-RCP supports **230400 and 460800 baud** (460800 is the default and the
> otbr-agent ceiling per CHANGELOG v3.0.0; 230400 is the operating point for
> boards without RTS/CTS wiring — see discussion #134). The committed lidl
> matrix carries 460800 only; build other bauds with `build_ot_rcp.sh <BAUD>`.

> **Legacy env-var interface** (deprecated):
> `FW_CHOICE=4 CONFIRM=y ./flash_efr32.sh` still works with a deprecation
> warning. Prefer the flag form above.

#### Gateway state after flash (per use case)

The same OT-RCP firmware drives 3 use cases — what differs is what's in
`/userdata/etc/radio.conf` and which init script wakes up:

All three use cases share the same `FIRMWARE=otrcp` +
`FIRMWARE_BAUD=460800` chip-side identity (`flash_efr32.sh` writes them);
what differs is the daemon-routing keys:

| Use case | Daemon-routing keys in `radio.conf` | Init script | Runs on gateway |
|---|---|---|---|
| **3 — OTBR on gateway** (default after `-y otrcp`) | `MODE=otbr` | `S70otbr` | `otbr-agent` (native) |
| **1 — ZoH** | (no `MODE` line) | `S50uart_bridge` | bridge TCP:8888 |
| **2 — OTBR on host** | (no `MODE` line) | `S50uart_bridge` | bridge TCP:8888 |

For cases 1 and 2, switch the gateway state after the EFR32 flash — see
[`docker/README.md` "Switching Radio Mode"](docker/README.md#switching-radio-mode-no-efr32-reflash-needed). The
`FIRMWARE=otrcp` line stays the same in all three cases — it describes
the chip, not the deployment.

### Build from Source

For users who want to customize the firmware.

```bash
# Install Silicon Labs tools (once)
cd 1-Build-Environment/12-silabs-toolchain && ./install_silabs.sh

# Build
cd 2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP
./build_ot_rcp.sh                # default baud 460800
./build_ot_rcp.sh --help         # show baud options
```

Output: `firmware/ot-rcp-460800-hw-uartdrv.gbl` (UART flash) and
`firmware/ot-rcp-460800-hw-uartdrv.s37` (J-Link/SWD). The name embeds the flow
type (`hw`) and UART driver (`uartdrv`; a `sw` board builds `-sw-iostream`, #145).

### Technical Notes

- **UART driver — selected per board (#142):** boards with RTS/CTS
  (`BOARD_UART_FLOW=hw`) or no flow control build on `uartdrv_usart` (DMA,
  near-zero CPU per byte — the historical default, unchanged for Lidl);
  boards with software flow (`sw`, e.g. the Sengled G4) build on
  `iostream_usart`, the only backend whose XON/XOFF support is complete
  (watermark-driven emission + inbound honor — uartdrv's is "partial only"
  per Silabs' own docs, see discussion #134). The old concern that iostream
  corrupts the binary Spinel stream via LF→CRLF conversion was a config
  default, not a driver property — our header disables the conversion
  (`SL_IOSTREAM_USART_VCOM_CONVERT_BY_DEFAULT_LF_TO_CRLF 0`), verified with
  live spinel traffic at 460800. Force a backend for experiments with
  `UART_DRIVER=uartdrv|iostream` (forced builds get a `-<driver>` filename
  suffix and are never auto-resolved by `flash_efr32.sh`).
- **RTL8196E boot delay:** 1-second delay at startup for host UART initialization.
- **Hardware flow control:** RTS/CTS enabled in the EFR32 firmware, **and**
  enabled on the host side via `&uart-flow-control=true` in the spinel
  radio URL (`S70otbr` since v3.3.0). Without the host-side flag,
  `otbr-agent` opens `/dev/ttyS1` without `CRTSCTS`, the kernel UART
  driver does not engage `MCR_AFE`, and the RX FIFO can overrun under
  bursty Spinel traffic at 460800 — this was the root cause of #89.
- **Hardware radio acceleration:** All 802.15.4 MAC operations in hardware.
- **Baud rate: 460800 default** (aligned with OpenThread's own default).
  All bauds up to 892857 work with the in-kernel UART bridge on kernel
  6.18. Pre-built firmware uses 460800. If
  you recompile at a different baud, `flash_efr32.sh` will automatically
  detect it, send a Spinel reset-to-bootloader command, and reflash via
  the Gecko Bootloader — no J-Link/SWD needed.

---

## 2. Use Cases

All 3 use cases run the **same OT-RCP firmware** on the EFR32. They differ in
what runs on the gateway's RTL8196E main CPU and on the Docker host.

| # | Use case | Protocol | Gateway runs | Host runs (Docker) |
|---|----------|----------|-------------|---------------------|
| 1 | **ZoH** | Zigbee | in-kernel UART bridge | Zigbee2MQTT + Mosquitto |
| 2 | **OTBR on host** | Thread/Matter | in-kernel UART bridge | OTBR + Matter Server + HA |
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
│  EFR32 RCP  │◄──────► │ kernel │◄─┤  Web UI :8080            │
│  Spinel/    │ 460800  │ bridge │  └──────────────────────────┘
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
in-kernel UART bridge over TCP to reach the EFR32 radio.

```
Matter Devices                        Docker Host
       │  Thread 802.15.4           ┌──────────────────────────┐
       ▼                            │  OTBR (Docker container) │
┌─────────────┐  UART   ┌────────┐  │  REST API :8081          │
│  EFR32 RCP  │◄──────► │ serial │◄─┤  Matter Server :5580     │
│  Spinel/    │ 460800  │ gateway│  │  Home Assistant :8123    │
│  HDLC       │         │ :8888  │  │  ← Companion App (BLE)   │
└─────────────┘         └────────┘  └──────────────────────────┘
     Gateway (Zigbee mode)
```

**Gateway setup:** flash userdata in **Zigbee** mode (the in-kernel UART
bridge forwards the radio to TCP; OTBR runs on the host).
**Quick start:** see [`docker/README.md` — Use Case 2](docker/README.md#use-case-2-otbr-on-host--threadmatter-docker).
**Operating the network:** see [`OT-CTL-CHEATSHEET.md`](./OT-CTL-CHEATSHEET.md) for channel, TX power, dataset, and commissioning commands.

### Use case 3: OTBR on Gateway (v2.0+)

OTBR runs **natively on the gateway** (otbr-agent on the RTL8196E CPU).
No TCP bridge between OTBR and the radio — otbr-agent opens `/dev/ttyS1`
directly. The host only runs Matter Server + Home Assistant.

```
Matter Devices                                       Docker Host
       │  Thread 802.15.4                          ┌──────────────────┐
       ▼                                           │  Matter Server   │
┌─────────────┐  UART   ┌──────────────────┐  REST │  :5580           │
│  EFR32 RCP  │◄──────► │  otbr-agent      │◄──────┤  Home Assistant  │
│  Spinel/    │ 460800  │  (native on CPU) │ :8081 │  :8123           │
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
**Operating the network:** see [`OT-CTL-CHEATSHEET.md`](./OT-CTL-CHEATSHEET.md) — includes a section on the project-specific tmpfs/flash dataset sync done by `S70otbr`.

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

1. Verify TCP connection: `nc -zv <gateway-ip> 8888` (modes A/B) or
   check otbr-agent is running (mode C)
2. Check baud rate matches on firmware and host (460800 default for
   OT-RCP; `cat /sys/module/rtl8196e_uart_bridge/parameters/baud` on
   the gateway for modes A/B)
3. Verify hardware flow control is enabled

### HDLC Parsing Errors

1. Check baud rate mismatch between firmware and host
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
│   ├── sl_uartdrv_usart_vcom_config.h  # UART: 460800, HW flow control
│   └── sl_rail_util_pti_config.h       # PTI disabled (suppresses SDK warning)
├── docker/                      # Docker Compose stacks
│   ├── README.md                # Full setup guide (3 use cases)
│   ├── docker-compose-zoh.yml           # Use case 1: ZoH
│   ├── docker-compose-otbr-host.yml     # Use case 2: OTBR on host
│   ├── docker-compose-otbr-gateway.yml  # Use case 3: OTBR on gateway
│   ├── z2m/configuration.yaml   # Zigbee2MQTT config
│   └── mosquitto/mosquitto.conf # MQTT broker config
├── firmware/                    # Pre-built binaries
│   ├── ot-rcp.gbl               # For UART flashing
│   └── ot-rcp.s37               # For SWD flashing
└── range-testing/               # Thread mesh range-test toolset + field-test report
    ├── README.md                # Layout, install, quick start
    ├── REPORT.md                # 16-sensor home deployment results + recipes
    ├── gateway/
    │   ├── thread-range-test         # Sampling, power, channel, and orientation
    │   └── optional/
    │       ├── thread-health-monitor # Host health sampler (1 sample/min)
    │       └── home-assistant/       # Opt-in RSSI/LQI publisher + config/init files
    └── analysis/                # Developer-machine tooling (Python 3.10+)
        ├── map-ha-devices.py    # HA WS API → label/node_id/ext_mac mapping
        └── analyze-results.py   # Per-condition and per-sensor stats (stdlib only)
```

See [`range-testing/README.md`](range-testing/README.md) for the test
methodology and [`range-testing/REPORT.md`](range-testing/REPORT.md) for
field-test results — TX power, channel, gateway orientation and sensor
orientation, plus a 12 h validation soak. The same scripts let you
characterise your own deployment instead of relying on these defaults.

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
- [Discussion #47](https://github.com/jnilo1/rtl8196e-gateway/discussions/47) — Thread/Matter on the Lidl gateway

## License

Educational and personal use. Silicon Labs SDK components under their respective licenses.
