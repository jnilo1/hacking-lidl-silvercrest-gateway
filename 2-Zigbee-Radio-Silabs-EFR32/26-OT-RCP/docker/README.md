# Docker Stacks for OT-RCP Firmware

The OT-RCP firmware supports **3 use cases** with the same EFR32 firmware.
Each use case has its own Docker Compose file.

## Use Cases at a Glance

| # | Use case | Compose file | What runs on gateway | What runs on host (Docker) |
|---|----------|-------------|---------------------|---------------------------|
| 1 | **ZoH** (Zigbee) | `docker-compose-zoh.yml` | serialgateway | Zigbee2MQTT + Mosquitto |
| 2 | **OTBR on host** | `docker-compose-otbr-host.yml` | serialgateway | OTBR + Matter Server + HA |
| 3 | **OTBR on gateway** | `docker-compose-otbr-gateway.yml` | otbr-agent (native) | Matter Server + HA |

```
                          Use case 1: ZoH            Use case 2: OTBR host      Use case 3: OTBR gateway
                        ┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐
                        │  Zigbee2MQTT     │       │  OTBR (Docker)   │       │  Matter Server   │
         Docker host    │  + Mosquitto     │       │  Matter Server   │       │  Home Assistant  │
                        │  Web UI :8080    │       │  Home Assistant  │       │                  │
                        └───────┬──────────┘       └───────┬──────────┘       └───────┬──────────┘
                                │ TCP :8888                │ TCP :8888                │ REST :8081
                        ┌───────┴──────────┐       ┌───────┴──────────┐       ┌───────┴──────────┐
         Gateway        │  serialgateway   │       │  serialgateway   │       │  otbr-agent      │
         (RTL8196E)     │  (Zigbee mode)   │       │  (Zigbee mode)   │       │  (Thread mode)   │
                        └───────┬──────────┘       └───────┬──────────┘       └───────┬──────────┘
                                │ UART 115200              │ UART 115200              │ UART 115200
                        ┌───────┴──────────┐       ┌───────┴──────────┐       ┌───────┴──────────┐
         EFR32          │  OT-RCP          │       │  OT-RCP          │       │  OT-RCP          │
                        │  (same firmware) │       │  (same firmware) │       │  (same firmware) │
                        └──────────────────┘       └──────────────────┘       └──────────────────┘
```

**Key difference between use cases 2 and 3:** In use case 2, OTBR runs in Docker
on your PC and connects to the gateway's `serialgateway` over TCP. In use case 3
(v2.0+), OTBR runs natively on the gateway's RTL8196E CPU — no serialgateway, no
TCP bridge. The host only needs Matter Server + Home Assistant.

---

## Requirements

### On the Lidl Gateway

- **EFR32 flashed with OT-RCP firmware** (`ot-rcp.gbl`)
- **Gateway in the correct radio mode:**
  - Use cases 1 & 2: Zigbee mode (serialgateway)
  - Use case 3: Thread mode (otbr-agent)

### Switching Radio Mode (no reflash needed)

The radio mode is controlled by `/userdata/etc/radio.conf` on the gateway.
You can switch without reflashing:

```bash
# Switch to Zigbee mode (use cases 1 & 2)
ssh root@192.168.1.88 "rm -f /userdata/etc/radio.conf; reboot"

# Switch to Thread mode (use case 3)
ssh root@192.168.1.88 "echo MODE=otbr > /userdata/etc/radio.conf; reboot"
```

Alternatively, `3-Main-SoC-Realtek-RTL8196E/34-Userdata/flash_userdata.sh` sets the mode at flash time via its prompt.

### On Your Computer

- Docker and Docker Compose
- Wired Ethernet to the gateway (recommended)
- For Thread/Matter: Bluetooth adapter (BLE commissioning via HA Companion App)

---

## Use Case 1: ZoH — Zigbee (zigbee-on-host)

Runs Zigbee2MQTT with the `zoh` adapter. The Zigbee stack runs on the host
([zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) by
[@Nerivec](https://github.com/Nerivec)), not on the EFR32.

### Quick Start

1. Edit `z2m/configuration.yaml` — set your gateway IP:
   ```yaml
   serial:
     port: tcp://192.168.1.88:8888
     adapter: zoh
   ```

2. Start:
   ```bash
   docker compose -f docker-compose-zoh.yml up -d
   ```

3. Open http://localhost:8080

### Files

| File | Description |
|------|-------------|
| `docker-compose-zoh.yml` | Mosquitto + Zigbee2MQTT |
| `z2m/configuration.yaml` | Z2M config — **edit gateway IP here** |
| `mosquitto/mosquitto.conf` | MQTT broker (anonymous, ports 1883/9001) |

---

## Use Case 2: OTBR on Host — Thread/Matter (Docker)

OTBR runs in Docker on your PC, connecting to the gateway's `serialgateway`
over TCP. The full stack (OTBR + Matter Server + HA) runs on the host.

### Quick Start

#### 1. Enable IPv6 Forwarding on the Host

OTBR runs on the host in this use case — the host needs IPv6 forwarding to
route Thread traffic between the mesh and the local network.

```bash
sudo sysctl -w net.ipv6.conf.all.forwarding=1
# Permanent:
echo "net.ipv6.conf.all.forwarding=1" | sudo tee /etc/sysctl.d/99-thread.conf
```

#### 2. Configure

Edit `docker-compose-otbr-host.yml`:
```yaml
environment:
  - RCP_HOST=192.168.1.88     # ← Your gateway's IP
  - OTBR_BACKBONE_IF=enp2s0  # ← Your host's Ethernet interface (ip link)
```

#### 3. Start

```bash
docker compose -f docker-compose-otbr-host.yml up -d
```

#### 4. Configure Home Assistant

Open http://localhost:8123, create your account, then add integrations
(**Settings → Devices & Services → Add Integration**):

1. **Open Thread Border Router** — URL: `http://localhost:8081`
2. **Thread** — auto-detected after adding OTBR
3. **Matter** — auto-detects on `localhost:5580` (or manual: `ws://localhost:5580/ws`)

#### 5. Set Thread Network as Preferred

**Settings → Devices & Services → Thread → Configure** → select your network →
**"Use as preferred network"**.

### Services

| Port | Service |
|------|---------|
| 8080 | OTBR Web UI |
| 8081 | OTBR REST API |
| 5580 | Matter Server |
| 8123 | Home Assistant |

---

## Use Case 3: OTBR on Gateway — Thread/Matter (native, v2.0+)

OTBR runs **natively on the gateway** (otbr-agent on the RTL8196E CPU).
No Docker OTBR container, no serialgateway, no TCP bridge between OTBR and
the radio. The host only runs Matter Server + Home Assistant.

This is the recommended setup for Thread/Matter since v2.0.

### Quick Start

#### 1. Flash the Gateway in Thread Mode

```bash
# Flash userdata — select "Thread" radio mode
cd 3-Main-SoC-Realtek-RTL8196E/34-Userdata
RADIO_MODE=thread CONFIRM=y ./flash_userdata.sh
```

Verify OTBR is running:
```bash
curl -s http://192.168.1.88:8081/node | python3 -m json.tool
```

#### 2. Form the Thread Network (first time only)

> **If you use Home Assistant**, skip this step — HA creates the Thread network
> automatically when you add the OTBR integration (step 4). Just proceed to
> step 3.

For standalone use (no HA), initialize the network manually:

```bash
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl dataset init new"
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl dataset commit active"
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl ifconfig up"
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl thread start"
```

Verify:
```bash
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl state"
# Should print "leader" after a few seconds
```

> The dataset is persisted in `/userdata/thread/`. After a reboot, OTBR
> auto-attaches to the saved network — this step is only needed once.

#### 3. Start Matter Server and Home Assistant

```bash
docker compose -f docker-compose-otbr-gateway.yml up -d
```

> **Note:** IPv6 forwarding is handled by the gateway's `S70otbr` init script.
> No need to configure it on the host — the host does not do border routing.

#### 4. Configure Home Assistant

Open http://localhost:8123, create your account, then add integrations:

1. **Open Thread Border Router** — URL: `http://192.168.1.88:8081`
   (the gateway's IP, **not** localhost — OTBR runs on the gateway)
2. **Thread** — auto-detected after adding OTBR
3. **Matter** — auto-detects on `localhost:5580`

#### 5. Set Thread Network as Preferred

Same as use case 2: **Settings → Devices & Services → Thread → Configure**.

### Services

| Where | Port | Service |
|-------|------|---------|
| Gateway | 8081 | OTBR REST API |
| Host | 5580 | Matter Server |
| Host | 8123 | Home Assistant |

### Advantages over Use Case 2

- **Lower latency** — OTBR talks directly to the EFR32 via UART, no TCP bridge
- **Simpler** — no OTBR Docker container to manage, no `network_mode: host` issues
- **Self-contained** — gateway works even without the host running (Thread mesh stays up)
- **Flash wear protection** — settings run from tmpfs, synced to flash only when
  the Thread dataset changes (see `S70otbr` init script)

---

## Commissioning a Matter Device (Use Cases 2 & 3)

### Prerequisites (Home Assistant)

Before commissioning, verify in **Settings → Devices & Services**:

1. **Open Thread Border Router** integration — pointing to the correct OTBR
   URL (use case 2: `http://localhost:8081`, use case 3: `http://<GATEWAY_IP>:8081`)
2. **Thread** integration — auto-detected after adding OTBR; your network
   should appear as **"Preferred network"** (click Configure to set it)
3. **Matter** integration — auto-detected or `ws://localhost:5580/ws`

### Via Home Assistant Companion App (recommended)

1. Install **"Home Assistant"** from the Play Store
2. Connect to your HA instance: `http://<HOST_IP>:8123`
3. Phone must be on **2.4 GHz WiFi** (same subnet as the gateway) with
   **Bluetooth enabled**
4. **Sync Thread credentials** (required after every Thread network change):
   Settings → Companion App → Troubleshooting → Sync Thread credentials
5. Put the Matter device in **pairing mode** (factory reset if needed)
6. **Commission:**
   Settings → Devices & Services → Add Device → Add Matter device
7. Scan the QR code or enter the 11-digit pairing code
8. The app connects via BLE, transfers Thread credentials, device joins the mesh

### Via chip-tool (CLI alternative)

```bash
# Get the Thread dataset
# Use case 2:
docker exec otbr ot-ctl dataset active -x
# Use case 3:
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl dataset active -x"

# Commission
mkdir -p /tmp/chip-tool-storage
docker run --rm --network host --privileged \
  -v /run/dbus:/run/dbus:ro \
  -v /sys:/sys \
  -v /tmp/chip-tool-storage:/tmp \
  atios/chip-tool:latest \
  pairing code-thread <NODE_ID> \
  hex:<THREAD_DATASET> \
  <SETUP_CODE> \
  --bypass-attestation-verifier true
```

`--bypass-attestation-verifier true` is needed for production devices (IKEA, Eve, etc.)
— it skips the manufacturer certificate check (safe for home use).

---

## Commissioning Troubleshooting

| Problem | Solution |
|---------|----------|
| "Your device requires a Thread border router" | Sync Thread credentials in Companion App |
| "Checking connectivity" hangs | Enable IPv6 forwarding on the host |
| Device not found / BLE scan timeout | Factory reset the device, check Bluetooth is on |
| OTBR shows "leader" but no children | No devices commissioned yet — add one |
| Matter integration shows "offline" | Check Matter Server container: `docker compose logs matter-server` |
| OTBR: "Failed to bind socket" | Wrong backbone interface — check `ip link` |
| BLE advertising timeout | Matter devices advertise 15-30 min after reset — act quickly |
| "Use as preferred network" not shown | Restart Home Assistant after forming/changing the Thread network |
| Commissioning fails after switching use case | Sync Thread credentials in Companion App — the app caches credentials from the previous Thread network |

---

## Tested Devices

| Device | Protocol | Stack | Status |
|--------|----------|-------|--------|
| Xiaomi LYWSD03MMC | Zigbee | ZoH (use case 1) | OK |
| IKEA TIMMERFLOTTE temp/hmd sensor | Matter/Thread | OTBR on host (use case 2) | OK |
| IKEA TIMMERFLOTTE temp/hmd sensor | Matter/Thread | OTBR on gateway (use case 3) | OK |
| IKEA MYGGBET door/window sensor | Matter/Thread | OTBR on gateway (use case 3) | OK |
| IKEA BILRESA dual button | Matter/Thread | OTBR on gateway (use case 3) | OK |
| IKEA MYGGSPRAY wrlss mtn sensor | Matter/Thread | OTBR on gateway (use case 3) | OK |

---

## Commands Reference

```bash
# Use case 1: Zigbee (zoh)
docker compose -f docker-compose-zoh.yml up -d
docker compose -f docker-compose-zoh.yml down

# Use case 2: OTBR on host
docker compose -f docker-compose-otbr-host.yml up -d
docker compose -f docker-compose-otbr-host.yml down
docker exec otbr ot-ctl state
docker exec otbr ot-ctl child table

# Use case 3: OTBR on gateway
docker compose -f docker-compose-otbr-gateway.yml up -d
docker compose -f docker-compose-otbr-gateway.yml down
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl state"
ssh root@192.168.1.88 "/userdata/usr/bin/ot-ctl child table"
curl -s http://192.168.1.88:8081/node | python3 -m json.tool

# View logs (any stack)
docker compose -f <compose-file> logs -f

# Full reset (deletes all data — Thread network, Matter fabric, HA config)
docker compose -f <compose-file> down -v
```

## References

- [bnutzer/docker-otbr-tcp](https://github.com/bnutzer/docker-otbr-tcp) — OTBR Docker image for TCP-based RCPs
- [zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) — Open-source Zigbee stack by Nerivec
- [Home Assistant Matter integration](https://www.home-assistant.io/integrations/matter/)
- [python-matter-server](https://github.com/matter-js/python-matter-server) — Matter Server (migrated to matter-js org)
- [chip-tool guide](https://project-chip.github.io/connectedhomeip-doc/development_controllers/chip-tool/chip_tool_guide.html)
- [Discussion #47](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/47) — Thread/Matter on the Lidl gateway
