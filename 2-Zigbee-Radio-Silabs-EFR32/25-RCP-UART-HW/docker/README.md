# Docker Stacks for RCP Firmware (EmberZNet 8.2.2)

The RCP firmware has one working use case on the Lidl Silvercrest gateway.
A second one (concurrent Zigbee + Thread) was originally sketched but is
not achievable on this hardware — see [`cpcd-zigbeed-otbr/README.md`](./cpcd-zigbeed-otbr/README.md).

## Use Cases at a Glance

| # | Use case | Compose file | EFR32 firmware | Status |
|---|----------|-------------|----------------|--------|
| 1 | **Zigbee** (EmberZNet 8.2.2) | `docker-compose-zigbee.yml` | `rcp-uart-802154.gbl` | Tested, stable |
| 2 | **Multipan** (Zigbee + Thread) | — | — | ❌ Not achievable on EFR32MG1B ([why](./cpcd-zigbeed-otbr/README.md)) |

```
                          Use case 1: Zigbee
                        ┌──────────────────────┐
                        │  Zigbee2MQTT         │
         Docker host    │  + Mosquitto         │
                        │  Web UI :8080        │
                        └───────┬──────────────┘
                                │
                        ┌───────┴──────────────┐
                        │  cpcd-zigbeed        │
                        │  ├── cpcd            │
                        │  └── zigbeed (IID=1) │
                        └───────┬──────────────┘
                                │ TCP :8888
                        ┌───────┴──────────────┐
         Gateway        │  rtl8196e-uart-      │
         (RTL8196E)     │  bridge (kernel)     │
                        └───────┬──────────────┘
                                │ UART 460800
                        ┌───────┴──────────────┐
         EFR32          │  RCP (single-PAN)    │
                        └──────────────────────┘
```

For Matter-over-Thread on this gateway, reflash the EFR32 with the standalone
OT-RCP firmware (`../../26-OT-RCP/firmware/ot-rcp.gbl`) and use the Thread
Border Router compose at `../../26-OT-RCP/docker/docker-compose-otbr-host.yml`.

---

## Requirements

### On the Lidl Gateway

- **EFR32 flashed with RCP firmware** (`rcp-uart-802154.gbl`)
- **Gateway running kernel 6.18 or newer** with the in-kernel UART bridge
  (`rtl8196e-uart-bridge`) armed on TCP:8888 (automatic via `S50uart_bridge`
  at boot)

### On Your Computer

- Docker and Docker Compose
- Wired Ethernet to the gateway (recommended — cpcd is latency-sensitive)

---

## Use Case 1: Zigbee — EmberZNet 8.2.2

Runs Zigbee2MQTT with the `ember` adapter. The Zigbee stack (zigbeed,
EmberZNet 8.2.2 / EZSP v18) runs in a Docker container that connects to
the gateway's in-kernel UART bridge over TCP. Inside the container, `cpcd`
uses its native `bus_type: TCP` to dial the bridge on `TCP:8888` directly —
no `socat` PTY shim (see [`cpcd/README.md`](../cpcd/README.md)).

### Quick Start

1. Edit `docker-compose-zigbee.yml` — set your gateway IP:
   ```yaml
   environment:
     - RCP_HOST=192.168.1.88
   ```

2. Start:
   ```bash
   docker compose -f docker-compose-zigbee.yml up -d
   ```

3. Wait ~60 seconds for the stack to initialize. Check:
   ```bash
   docker compose -f docker-compose-zigbee.yml logs -f cpcd-zigbeed
   # should show: "Connected to Secondary", "Secondary CPC vX.Y.Z"
   ```

4. Open http://localhost:8080

### Files

| File | Description |
|------|-------------|
| `docker-compose-zigbee.yml` | Mosquitto + cpcd-zigbeed + Zigbee2MQTT |
| `z2m/configuration.yaml` | Z2M config (adapter, MQTT) |
| `mosquitto/mosquitto.conf` | MQTT broker (anonymous, ports 1883/9001) |
| `cpcd-zigbeed/` | Dockerfile and configs for the cpcd+zigbeed container |

### Pre-built Image

```
ghcr.io/jnilo1/cpcd-zigbeed:latest
```

| Tag | cpcd | EmberZNet | EZSP |
|-----|------|-----------|------|
| `latest` | 4.5.3 | 8.2.2 | v18 |
| `cpcd4.5.3-ezsp18` | 4.5.3 | 8.2.2 | v18 |

### Services

| Port | Service |
|------|---------|
| 8080 | Zigbee2MQTT Web UI |
| 1883 | Mosquitto MQTT |
| 9001 | Mosquitto WebSocket |

---

## Use Case 2: Multipan — not supported on this hardware

Historical POC to run Zigbee + Thread concurrently off a single multi-PAN
RCP. Not achievable on the gateway's EFR32MG1B (Series 1). See
[`cpcd-zigbeed-otbr/README.md`](./cpcd-zigbeed-otbr/README.md) for the
full explanation and what to do instead.

---

## Commands Reference

```bash
# Zigbee stack
docker compose -f docker-compose-zigbee.yml up -d
docker compose -f docker-compose-zigbee.yml down
docker compose -f docker-compose-zigbee.yml logs -f cpcd-zigbeed

# Full reset (deletes all Zigbee data, Z2M database)
docker compose -f docker-compose-zigbee.yml down -v
```

## Troubleshooting

### "Cannot reach RCP endpoint"

1. Check the IP is correct in the compose file
2. Test connectivity: `nc -zv <gateway-ip> 8888`
3. Check the in-kernel UART bridge is armed on the gateway:
   `cat /sys/module/rtl8196e_uart_bridge/parameters/armed` → `1`

### "EZSP protocol version not supported"

Requires **Zigbee2MQTT 2.7.2 or newer** (for EZSP v18 support).

### "zigbeed entered FATAL state"

Common causes: network instability (use Ethernet, not WiFi), or baudrate
mismatch (must match RCP firmware, default 460800).

---

## References

- [cpc-daemon (Silabs)](https://github.com/SiliconLabs/cpc-daemon)
- [zigbeed / EmberZNet](https://github.com/SiliconLabs/simplicity_sdk)
- [Forum HACF thread](https://forum.hacf.fr/t/passerelle-lidl-silvercrest-firmware-open-source-zigbee-thread-pour-home-assistant/77310)
