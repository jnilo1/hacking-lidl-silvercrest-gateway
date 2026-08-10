# Docker Stacks for OT-RCP Firmware

The OT-RCP firmware supports **3 use cases** with the same EFR32 firmware.
Each use case has its own Docker Compose file.

## Use Cases at a Glance

| # | Use case | Compose file | What runs on gateway | What runs on host (Docker) |
|---|----------|-------------|---------------------|---------------------------|
| 1 | **ZoH** (Zigbee) | `docker-compose-zoh.yml` | in-kernel UART bridge | Zigbee2MQTT + Mosquitto |
| 2 | **OTBR on host** | `docker-compose-otbr-host.yml` | in-kernel UART bridge | OTBR + Matter Server + HA |
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
         Gateway        │  rtl8196e-uart-  │       │  rtl8196e-uart-  │       │  otbr-agent      │
         (RTL8196E)     │  bridge (kernel) │       │  bridge (kernel) │       │  (Thread mode)   │
                        └───────┬──────────┘       └───────┬──────────┘       └───────┬──────────┘
                                │ UART 460800              │ UART 460800              │ UART 460800
                        ┌───────┴──────────┐       ┌───────┴──────────┐       ┌───────┴──────────┐
         EFR32          │  OT-RCP          │       │  OT-RCP          │       │  OT-RCP          │
                        │  (same firmware) │       │  (same firmware) │       │  (same firmware) │
                        └──────────────────┘       └──────────────────┘       └──────────────────┘
```

**Key difference between use cases 2 and 3:** In use case 2, OTBR runs in Docker
on your PC and connects to the gateway's in-kernel UART bridge over TCP.
In use case 3 (v2.0+), OTBR runs natively on the gateway's RTL8196E CPU
(otbr-agent opens `/dev/ttyS1` directly) — no TCP bridge needed. The host
only needs Matter Server + Home Assistant.

---

## Requirements

### On the Gateway

- **EFR32 flashed with OT-RCP firmware** (via `./flash_efr32.sh otrcp`)
- **Gateway in the correct radio mode:**
  - Use cases 1 & 2: Zigbee mode (in-kernel UART bridge)
  - Use case 3: Thread mode (otbr-agent)

### Switching Radio Mode (no EFR32 reflash needed)

The same OT-RCP firmware runs in all three use cases. What changes is the
**gateway-side `radio.conf`** state, which controls which init script
takes ownership of `/dev/ttyS1` at boot:

All three cases share the same chip-side identity in `radio.conf`
(`FIRMWARE=otrcp` + `FIRMWARE_BAUD=460800`, written by `flash_efr32.sh`);
what differs is the daemon-routing keys:

| Use case | Daemon-routing keys in `radio.conf` | Init script that wakes up |
|---|---|---|
| 1 (ZoH) | (no `MODE` line) | `S50uart_bridge` arms TCP:8888 |
| 2 (OTBR host) | (no `MODE` line) | `S50uart_bridge` arms TCP:8888 |
| 3 (OTBR gateway) | `MODE=otbr` | `S70otbr` launches otbr-agent |

`flash_efr32.sh -y otrcp` sets the **case 3** state by default
(`MODE=otbr`). To use case 1 or 2 instead, switch the gateway state
explicitly after the EFR32 flash:

```bash
# Case 1 or 2 — Zigbee bridge mode (drop MODE so S50uart_bridge wins)
ssh root@192.168.1.88 "
    sed -i '/^MODE=/d' /userdata/etc/radio.conf
    reboot
"

# Case 3 — Thread mode (this is what flash_efr32.sh -y otrcp does by default)
ssh root@192.168.1.88 "
    sed -i '/^MODE=/d' /userdata/etc/radio.conf
    echo 'MODE=otbr' >> /userdata/etc/radio.conf
    reboot
"
```

> **Why not just `rm -f radio.conf`?** Bare-removing the file leaves the
> bridge at its compile-time default (115200), which doesn't match the
> OT-RCP firmware's 460800 baud — Z2M's `zoh` adapter and the OTBR-host
> docker would then talk to the chip at the wrong speed and fail
> silently. Keep `FIRMWARE_BAUD=460800` (written by `flash_efr32.sh`)
> in place; only `MODE` switches between use cases.

Alternatively, `3-Main-SoC-Realtek-RTL8196E/34-Userdata/flash_userdata.sh`
sets the mode at flash time via its prompt — useful for a fresh userdata
install.

### On Your Computer

- Docker and Docker Compose
- Wired Ethernet to the gateway (recommended)
- For Thread/Matter: **no** Bluetooth adapter on this machine — commissioning uses
  the phone's Bluetooth through the HA Companion App, and the Matter Server
  container is not given a radio (see the note below)

---

## Matter Server — matter.js, and what that changes for you

Use cases 2 and 3 run **`ghcr.io/matter-js/matterjs-server`** (matter.js), the same
code Home Assistant ships as its "Matter Server" add-on. It replaces
`python-matter-server`, which is frozen at 8.1.2. Same WebSocket API on
`:5580/ws`, plus a **web dashboard on `:5580/`** the Python one did not have.

Two consequences if you are coming from an earlier release of this repo:

- **The fabric does not carry over by default.** Both compose files mount a new
  volume (`matterjs_data`) and leave the old one (`matter_data`) declared but
  unmounted, so that rolling back is just restoring the previous image and volume
  names. Starting on the empty volume means **every Matter device has to be
  re-commissioned**. To keep the existing fabric instead, copy the volume over
  before the first start — the recipe is at the top of
  `docker-compose-otbr-gateway.yml`. The storage format is upgraded on first run,
  and that upgrade is one way.
- **No Bluetooth in the container.** The service is unprivileged (uid 1000), with
  no `/run/dbus` mount and no `privileged`/apparmor exception. That costs nothing
  here because commissioning goes through the Companion App on your phone. If you
  do want the server itself to drive BLE, the environment variables and mount are
  documented as a comment in both compose files.
- **The API is bound to loopback.** `:5580` is the fabric's control plane — list,
  commission, decommission, command — and it takes no credentials; the dashboard on
  `:5580/` drives the same API. Under `network_mode: host` the server binds every
  interface by default, which hands that control plane to the whole LAN, so both
  files set `LISTEN_ADDRESS=127.0.0.1`. Home Assistant sits in the same file on the
  same host and reaches it over loopback, so nothing is lost. Two consequences: the
  dashboard opens only from the Docker host (or through
  `ssh -L 5580:127.0.0.1:5580 <host>`), and **if you move Home Assistant to another
  machine you must relax this** — the symptom is the Matter integration failing to
  connect. Matter/Thread traffic is unaffected either way: devices are reached over
  IPv6/mDNS and OTBR, never through this port.

> **Our volume choice differs from upstream's advice, on purpose.** Upstream tells
> you to point the new server at the *same* data directory and let it migrate in
> place, and the migration FAQ is explicit that you then cannot revert. We keep the
> old volume untouched instead: you trade the fabric (re-commissioning) for a
> rollback that does not depend on having taken a backup first. Copy the volume
> over if you prefer upstream's trade.

Background on the rewrite:

- [The Matter upgrade you've been waiting for](https://www.home-assistant.io/blog/2026/06/23/the-matter-upgrade-youve-been-waiting-for/)
  — Home Assistant's announcement (2026-06-23)
- [Matter Server migration FAQ](https://github.com/home-assistant/addons/blob/master/matter_server/MIGRATION_FAQ.md)
  — what changes, what migrates, why it is one way
- [matterjs-server `docs/docker.md`](https://github.com/matter-js/matterjs-server/blob/main/docs/docker.md)
  — the self-hosted Docker reference: uid 1000, BLE via D-Bus, migration from Python
- [python-matter-server](https://github.com/matter-js/python-matter-server) — archived
  2026-06-23, final version 8.1.2

---

## Use Case 1: ZoH — Zigbee (zigbee-on-host)

Runs Zigbee2MQTT with the `zoh` adapter. The Zigbee stack runs on the host
([zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) by
[@Nerivec](https://github.com/Nerivec)), not on the EFR32.

### Quick Start

1. **Flash OT-RCP** firmware on the EFR32:
   ```bash
   ./flash_efr32.sh -y otrcp                    # gateway from gateway.env
   # or: ./flash_efr32.sh -y -g 10.0.0.5 otrcp  # custom IP
   ```

2. **Switch gateway to Zigbee bridge mode** (the script set MODE=otbr by
   default; case 1 just needs that line dropped so `S50uart_bridge` wins):
   ```bash
   ssh root@192.168.1.88 "
       sed -i '/^MODE=/d' /userdata/etc/radio.conf
       reboot
   "
   ```

3. **Edit `z2m/configuration.yaml`** — set your gateway IP:
   ```yaml
   serial:
     port: tcp://192.168.1.88:8888
     adapter: zoh
   ```

4. **Start the docker stack**:
   ```bash
   docker compose -f docker-compose-zoh.yml up -d
   ```

5. **Open** http://localhost:8080

### Files

| File | Description |
|------|-------------|
| `docker-compose-zoh.yml` | Mosquitto + Zigbee2MQTT |
| `z2m/configuration.yaml` | Z2M config — **edit gateway IP here** |
| `mosquitto/mosquitto.conf` | MQTT broker (anonymous, ports 1883/9001) |
| `.env` (gitignored) | `RCP_HOST` for the OTBR stack, written by `flash_userdata.sh` |

---

## Use Case 2: OTBR on Host — Thread/Matter (Docker)

OTBR runs in Docker on your PC, connecting to the gateway's in-kernel
UART↔TCP bridge over TCP. The full stack (OTBR + Matter Server + HA)
runs on the host.

### Quick Start

#### 1. Flash OT-RCP firmware on the EFR32

```bash
./flash_efr32.sh -y otrcp                    # gateway from gateway.env
# or: ./flash_efr32.sh -y -g 10.0.0.5 otrcp  # custom IP
```

#### 2. Switch gateway to Zigbee bridge mode

The script set `MODE=otbr` by default (case 3); case 2 just needs that
line dropped so `S50uart_bridge` arms TCP:8888 and OTBR-in-docker can
reach the EFR32:

```bash
ssh root@192.168.1.88 "
    sed -i '/^MODE=/d' /userdata/etc/radio.conf
    reboot
"
```

#### 3. Enable IPv6 Forwarding on the Host

OTBR runs on the host in this use case — the host needs IPv6 forwarding to
route Thread traffic between the mesh and the local network.

```bash
sudo sysctl -w net.ipv6.conf.all.forwarding=1
# Permanent:
echo "net.ipv6.conf.all.forwarding=1" | sudo tee /etc/sysctl.d/99-thread.conf
```

#### 4. Configure

`RCP_HOST` normally needs no editing: `flash_userdata.sh` writes the address it
installed into a `.env` file in this directory, which Docker Compose reads
automatically. Check it, or set it yourself:

```bash
cat .env                        # RCP_HOST=<your gateway>
echo "RCP_HOST=192.168.1.88" > .env
```

`.env` is gitignored. The backbone interface still has to be set by hand in
`docker-compose-otbr-host.yml`:

```yaml
environment:
  - OTBR_BACKBONE_IF=enp2s0   # ← Your host's Ethernet interface (ip link)
```

#### 5. Start

```bash
docker compose -f docker-compose-otbr-host.yml up -d
```

#### 6. Configure Home Assistant

Open http://localhost:8123, create your account, then add integrations
(**Settings → Devices & Services → Add Integration**):

1. **Open Thread Border Router** — URL: `http://localhost:8081`
2. **Thread** — auto-detected after adding OTBR
3. **Matter** — auto-detects on `localhost:5580` (or manual: `ws://localhost:5580/ws`)

#### 7. Set Thread Network as Preferred

**Settings → Devices & Services → Thread → Configure** → select your network →
**"Use as preferred network"**.

### Services

| Port | Service |
|------|---------|
| 8080 | OTBR Web UI |
| 8081 | OTBR REST API |
| 5580 | Matter Server — WebSocket API on `/ws`, web dashboard on `/` (loopback only) |
| 8123 | Home Assistant |

---

## Use Case 3: OTBR on Gateway — Thread/Matter (native, v2.0+)

OTBR runs **natively on the gateway** (otbr-agent on the RTL8196E CPU).
No Docker OTBR container, and no TCP bridge between OTBR and the radio —
otbr-agent opens `/dev/ttyS1` directly. The host only runs Matter Server +
Home Assistant.

This is the recommended setup for Thread/Matter since v2.0.

### Quick Start

#### 1. Flash OT-RCP firmware on the EFR32 (auto-sets Thread mode)

The simplest path — `flash_efr32.sh -y otrcp` flashes the firmware AND
writes `MODE=otbr` + `FIRMWARE_BAUD=460800` to `radio.conf` so `S70otbr`
launches `otbr-agent` on next boot:

```bash
./flash_efr32.sh -y otrcp                    # gateway from gateway.env
# or: ./flash_efr32.sh -y -g 10.0.0.5 otrcp  # custom IP
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
| Host | 5580 | Matter Server — WebSocket API on `/ws`, web dashboard on `/` (loopback only) |
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
   URL (use case 2: `http://localhost:8081`, use case 3: `http://<LINUX_IP>:8081`)
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
| Matter integration cannot connect, HA on another machine | `LISTEN_ADDRESS=127.0.0.1` binds the API to loopback — set it to a reachable address, or drop it |
| Matter dashboard unreachable from another PC | Same cause, by design — browse from the Docker host or `ssh -L 5580:127.0.0.1:5580 <host>` |
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
# NOTE: -v removes EVERY volume the file declares, including the unmounted legacy
# matter_data — the rollback to python-matter-server. To keep that one, stop
# without -v and delete only the volumes you mean to lose (otbr_data exists in the
# use-case-2 file only):
#   docker compose -f <compose-file> down
#   docker volume ls | grep matter        # volumes carry the project name as prefix
#   docker volume rm <project>_matterjs_data <project>_ha_config
docker compose -f <compose-file> down -v
```

## References

- [bnutzer/docker-otbr-tcp](https://github.com/bnutzer/docker-otbr-tcp) — OTBR Docker image for TCP-based RCPs
- [zigbee-on-host](https://github.com/Nerivec/zigbee-on-host) — Open-source Zigbee stack by Nerivec
- [Home Assistant Matter integration](https://www.home-assistant.io/integrations/matter/)
- [matterjs-server](https://github.com/matter-js/matterjs-server) — Matter Server (matter.js); replaces [python-matter-server](https://github.com/matter-js/python-matter-server), archived at 8.1.2
- [matterjs-server `docs/docker.md`](https://github.com/matter-js/matterjs-server/blob/main/docs/docker.md) — self-hosted Docker reference (uid 1000, BLE via D-Bus, migration)
- [Matter Server migration FAQ](https://github.com/home-assistant/addons/blob/master/matter_server/MIGRATION_FAQ.md) + [HA announcement](https://www.home-assistant.io/blog/2026/06/23/the-matter-upgrade-youve-been-waiting-for/) — the Python → matter.js rewrite
- [chip-tool guide](https://project-chip.github.io/connectedhomeip-doc/development_controllers/chip-tool/chip_tool_guide.html)
- [Discussion #47](https://github.com/jnilo1/rtl8196e-gateway/discussions/47) — Thread/Matter on the Lidl gateway
