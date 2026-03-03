# Docker Stacks for OT-RCP Firmware

Two Docker Compose stacks for the Lidl Silvercrest Gateway running OT-RCP
firmware. Choose based on your use case:

| Stack | File | Use case |
|-------|------|----------|
| **Zigbee (zoh)** | `docker-compose-zoh.yml` | Zigbee devices via Zigbee2MQTT |
| **Thread/Matter** | `docker-compose.yml` | Matter devices via OTBR + chip-tool |

Both stacks connect to the same gateway hardware — the OT-RCP firmware supports
Zigbee (via zigbee-on-host) and Thread/Matter (via OTBR). Only run **one stack
at a time** since they share the serial port.

## Requirements

### On the Lidl Gateway

1. **EFR32MG1B flashed with OT-RCP firmware** (`ot-rcp.gbl`)
2. **serialgateway running** on port 8888, 115200 baud

### On Your Computer

- Docker and Docker Compose
- Wired Ethernet to the gateway (recommended)
- For Thread/Matter: Bluetooth adapter (BLE commissioning)

---

## Stack 1: Zigbee (zigbee-on-host)

Runs Zigbee2MQTT with the `zoh` adapter. The Zigbee stack runs on the host
(zigbee-on-host by [@Nerivec](https://github.com/Nerivec/zigbee-on-host)),
not on the EFR32.

```
Lidl Gateway                          Docker Host
┌───────────────────────┐            ┌──────────────────────────────────┐
│                       │            │                                  │
│  EFR32 ◄───► serial   │◄── TCP ──►│  Zigbee2MQTT (zoh adapter)       │
│  (RCP)      gateway   │   :8888   │  + zigbee-on-host stack          │
│             115200    │            │  Web UI at :8080                 │
│                       │            │                                  │
└───────────────────────┘            └──────────────────────────────────┘
```

### Quick Start

1. Edit `z2m/configuration.yaml` — set your gateway IP:
   ```yaml
   serial:
     port: tcp://192.168.1.X:8888
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

## Stack 2: Thread/Matter (OTBR + chip-tool)

Runs an OpenThread Border Router that forms a Thread network. Matter devices
are commissioned onto this network using `chip-tool` in Docker.

```
Matter Device (e.g. IKEA TIMMERFLOTTE)
       │  Thread 802.15.4
       ▼
┌───────────────────────┐            ┌──────────────────────────────────┐
│  EFR32 ◄───► serial   │◄── TCP ──►│  OTBR (bnutzer/otbr-tcp)         │
│  (RCP)      gateway   │   :8888   │  Web UI :8080, REST API :8081    │
│             115200    │            │                                  │
└───────────────────────┘            │  Matter Server (:5580)           │
                                     │  Home Assistant (:8123)          │
                                     └──────────────────────────────────┘
                                              ▲
                                              │ BLE (commissioning)
                                     ┌────────┴────────┐
                                     │  chip-tool       │
                                     │  (Docker, once)  │
                                     └─────────────────┘
```

### Quick Start

#### 1. Configure

Edit `docker-compose.yml`:

```yaml
environment:
  - RCP_HOST=192.168.1.X     # ← Your gateway's IP
  - OTBR_BACKBONE_IF=enp2s0  # ← Your host's Ethernet interface (ip link)
```

#### 2. Start the Stack

```bash
docker compose up -d
```

Wait ~30 seconds, then verify OTBR is connected:

```bash
docker exec otbr ot-ctl state
# Should print: "leader"
```

#### 3. Get the Thread Dataset

The Thread operational dataset is needed to commission Matter devices:

```bash
docker exec otbr ot-ctl dataset active -x
# Outputs a hex string like: 0E080000000000010000...
```

Save this value — you'll need it for commissioning.

#### 4. Commission a Matter Device

Matter devices use **BLE** for initial commissioning. The device receives Thread
network credentials over BLE, then joins the Thread network.

You need:
- The **Thread dataset** (from step 3)
- The device's **Matter setup code** (printed on the device or its packaging,
  format: `XXXXXXXXXXX`, 11 digits)

Run chip-tool in Docker with persistent storage. The node ID (first argument
after `code-thread`) is any integer you choose to identify the device — use `1`
for your first device, `2` for the second, etc.

```bash
mkdir -p /tmp/chip-tool-storage

docker run --rm --network host --privileged \
  -v /run/dbus:/run/dbus:ro \
  -v /sys:/sys \
  -v /tmp/chip-tool-storage:/tmp \
  atios/chip-tool:latest \
  pairing code-thread 1 \
  hex:<THREAD_DATASET> \
  <SETUP_CODE> \
  --bypass-attestation-verifier true
```

Replace:
- `1` — node ID (increment for each new device: 1, 2, 3...)
- `<THREAD_DATASET>` — hex string from step 3
- `<SETUP_CODE>` — 11-digit manual pairing code from the device

**Example** (IKEA TIMMERFLOTTE temperature sensor):

```bash
docker run --rm --network host --privileged \
  -v /run/dbus:/run/dbus:ro \
  -v /sys:/sys \
  -v /tmp/chip-tool-storage:/tmp \
  atios/chip-tool:latest \
  pairing code-thread 1 \
  hex:0E0800000000000100004A03...full_dataset_hex... \
  00873831438 \
  --bypass-attestation-verifier true
```

A successful commissioning prints:

```
Device commissioning completed with success
```

#### 5. Verify

Check the device joined the Thread network:

```bash
docker exec otbr ot-ctl child table
```

Read data from the device (node ID `1`, endpoint `1` for temperature,
endpoint `2` for humidity):

```bash
# Temperature (value in 1/100 °C, e.g. 2057 = 20.57°C)
docker run --rm --network host --privileged \
  -v /tmp/chip-tool-storage:/tmp \
  atios/chip-tool:latest \
  temperaturemeasurement read measured-value 1 1

# Humidity (value in 1/100 %, e.g. 5861 = 58.61%)
docker run --rm --network host --privileged \
  -v /tmp/chip-tool-storage:/tmp \
  atios/chip-tool:latest \
  relativehumiditymeasurement read measured-value 1 2
```

### Services

| Port | Service | Description |
|------|---------|-------------|
| 8080 | OTBR Web UI | Thread network management |
| 8081 | OTBR REST API | Programmatic access to Thread state |
| 5580 | Matter Server | Python Matter Server WebSocket API |
| 8123 | Home Assistant | Home automation dashboard |

### Data Persistence

| Volume | Contents |
|--------|----------|
| `otbr_data` | Thread network state and credentials |
| `matter_data` | Matter fabric and device data |
| `ha_config` | Home Assistant configuration |
| `/tmp/chip-tool-storage/` | chip-tool fabric keys and node data |

---

## Commissioning Notes

### BLE Advertising Timeout

Matter devices only advertise via BLE for a limited time after factory reset
(typically 15-30 minutes). If chip-tool reports `No matching device found`,
factory reset the device and try again immediately.

### Attestation Verification

Production Matter devices (IKEA, Eve, etc.) require `--bypass-attestation-verifier true`
because chip-tool's built-in test CA cannot verify production device certificates.
This is safe for home use — it skips the manufacturer certificate check, not the
encryption.

### Setup Code Format

The 11-digit manual pairing code is printed on the device label. You can verify
it before commissioning:

```bash
docker run --rm atios/chip-tool:latest \
  payload parse-setup-payload <11_DIGIT_CODE>
```

If the code is valid, it prints the discriminator and passcode. If not, double-check
the digits — a single wrong digit causes `Integrity check failed`.

### Factory Reset Between Attempts

If commissioning fails partway through, the device may be in an inconsistent state.
Always factory reset the device before retrying. After a successful commissioning,
the device stops BLE advertising (it's now on Thread).

### chip-tool Persistent Storage

The `-v /tmp/chip-tool-storage:/tmp` mount preserves chip-tool's fabric state
across runs. This is required to interact with commissioned devices after the
initial pairing. Without it, chip-tool loses its fabric keys when the container
exits and can no longer reach commissioned devices.

To start fresh (decommission all devices):

```bash
rm -rf /tmp/chip-tool-storage/*
```

---

## Tested Devices

| Device | Type | Protocol | Commissioning | Data Read |
|--------|------|----------|---------------|-----------|
| IKEA TIMMERFLOTTE | Temperature sensor | Matter/Thread | `code-thread` via BLE | `temperaturemeasurement read measured-value` (24.08 C) |

---

## Troubleshooting

### OTBR: "Failed to bind socket" / TREL error

Wrong backbone interface name. Check yours with `ip link` and update
`OTBR_BACKBONE_IF` in `docker-compose.yml`.

### chip-tool: "Integrity check failed"

The setup code is wrong. Verify each digit carefully. Use
`payload parse-setup-payload` to test without attempting a connection.

### chip-tool: "No matching device found" / BLE scan timeout

1. The device is not advertising — factory reset it
2. Bluetooth service not running on host — `systemctl status bluetooth`
3. Ensure `/run/dbus` is mounted in the container

### chip-tool: "Attestation Information" error (err 101)

Add `--bypass-attestation-verifier true` to the command. This is expected for
production devices.

### chip-tool: "the input device is not a TTY"

Do **not** use `-it` flags with `docker run` in non-interactive environments.
Use `--rm` without `-it`.

### OTBR shows "leader" but no children

The Thread network is formed but no devices have joined yet. Commission a device
with chip-tool (step 4 above).

---

## Commands Reference

```bash
# Start Thread/Matter stack
docker compose up -d

# Start Zigbee (zoh) stack
docker compose -f docker-compose-zoh.yml up -d

# Check OTBR state
docker exec otbr ot-ctl state
docker exec otbr ot-ctl child table
docker exec otbr ot-ctl neighbor table

# Get Thread dataset (for chip-tool commissioning)
docker exec otbr ot-ctl dataset active -x

# View logs
docker compose logs -f otbr
docker compose logs -f matter-server

# Stop
docker compose down

# Full reset (deletes Thread network and all data)
docker compose down -v
rm -rf /tmp/chip-tool-storage/*
```

## References

- [bnutzer/docker-otbr-tcp](https://github.com/bnutzer/docker-otbr-tcp) — OTBR Docker image for TCP-based RCPs
- [Discussion #47](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/47) — Thread/Matter on the Lidl gateway
- [chip-tool guide](https://project-chip.github.io/connectedhomeip-doc/development_controllers/chip-tool/chip_tool_guide.html) — Matter commissioning reference
- [zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) — Open-source Zigbee stack by Nerivec
