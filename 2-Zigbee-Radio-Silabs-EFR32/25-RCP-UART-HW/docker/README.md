# Docker Stack for Lidl Silvercrest Gateway (RCP Mode)

Run a complete Zigbee stack (cpcd + zigbeed + Zigbee2MQTT) that connects to your Lidl Gateway running RCP firmware.

## What This Does

This stack turns your Lidl Silvercrest Gateway into a Zigbee coordinator compatible with Home Assistant and other home automation systems:

```
Lidl Gateway                         Docker Host
┌──────────────────────┐            ┌─────────────────────────────────────┐
│                      │            │                                     │
│  EFR32 ◄──► serial   │◄── TCP ───►│  cpcd-zigbeed ◄──► Zigbee2MQTT      │
│  (RCP)     gateway   │    :8888   │  (Zigbee stack)    (Web UI :8080)   │
│                      │            │                                     │
└──────────────────────┘            └─────────────────────────────────────┘
```

## Requirements

### On the Lidl Gateway

1. **EFR32MG1B chip flashed with RCP firmware** - see `../25-RCP-UART-HW/`
2. **serialgateway running** - exposes the UART on TCP port 8888

### On Your Computer

- Docker and Docker Compose
- Network **wire** access to the gateway (no WiFi) ideally through a direct cable connection since cpcd may cause latency issues

## Quick Start

### 1. Get Your Gateway's IP Address

Find your gateway on the network (usually `192.168.1.x`). Test connectivity:

```bash
nc -zv 192.168.1.126 8888
```

### 2. Configure the IP Address

Edit `docker-compose.yml` and change `RCP_HOST` to your gateway's IP:

```yaml
environment:
  - RCP_HOST=192.168.1.126   # ← Change this
```

### 3. Start the Stack

```bash
docker compose up -d
```

### 4. Wait for Initialization

The stack takes about 60 seconds to fully start. Check progress:

```bash
docker compose logs -f cpcd-zigbeed
```

You should see:
```
Connected to Secondary
Secondary CPC v4.4.7
zigbeed entered RUNNING state
```

### 5. Access Zigbee2MQTT

Open http://localhost:8080 in your browser.

## Files

| File | Description |
|------|-------------|
| `docker-compose.yml` | Main configuration - **edit RCP_HOST here** |
| `z2m/configuration.yaml` | Zigbee2MQTT settings (adapter, MQTT, etc.) |
| `mosquitto/mosquitto.conf` | MQTT broker configuration |
| `cpcd-zigbeed/` | Dockerfile and configs for the cpcd+zigbeed container |

## Docker Image

A pre-built image is available for both PC (amd64) and Raspberry Pi (arm64):

```
ghcr.io/jnilo1/cpcd-zigbeed:latest
```

| Tag | cpcd | EmberZNet | EZSP |
|-----|------|-----------|------|
| `latest` | 4.5.3 | 8.2.2 | v18 |
| `cpcd4.5.3-ezsp18` | 4.5.3 | 8.2.2 | v18 |

## Configuration Reference

### cpcd-zigbeed Environment Variables

Edit these in `docker-compose.yml`:

| Variable | Value | Description |
|----------|-------|-------------|
| `RCP_HOST` | `192.168.1.xxx` | **Your gateway's IP address** |
| `RCP_PORT` | `8888` | TCP port (default for serialgateway) |
| `UART_BAUDRATE` | `115200` | Must match RCP firmware baudrate |
| `ZIGBEED_DEBUG` | `0` | Debug verbosity (0=off, 1=on, 2=verbose) |

### Zigbee2MQTT Settings

The file `z2m/configuration.yaml` contains:

```yaml
serial:
  port: tcp://cpcd-zigbeed:9999
  adapter: ember

mqtt:
  server: mqtt://mosquitto:1883

frontend:
  port: 8080
```

These settings are pre-configured and should not need changes.

## Commands

```bash
# Start everything
docker compose up -d

# View logs (cpcd + zigbeed)
docker compose logs -f cpcd-zigbeed

# View logs (Zigbee2MQTT)
docker compose logs -f zigbee2mqtt

# Check health status
docker compose ps

# Restart after config change
docker compose restart cpcd-zigbeed

# Stop everything
docker compose down

# Full reset (deletes all Zigbee data!)
docker compose down -v
```

## Troubleshooting

### "Cannot reach RCP endpoint"

The container can't connect to your gateway.

1. Check the IP is correct in `docker-compose.yml`
2. Test connectivity: `nc -zv <gateway-ip> 8888`
3. Ensure `serialgateway` is running on the gateway

### "EZSP protocol version not supported"

You're using an old version of Zigbee2MQTT.

- This stack requires **Zigbee2MQTT 2.7.2 or newer** (for EZSP v18 support)

### "zigbeed entered FATAL state"

zigbeed crashed. Check logs:

```bash
docker compose logs cpcd-zigbeed | grep -i error
```

Common causes:
- Network instability (use Ethernet, not WiFi)
- Baudrate mismatch (must be 115200)

### Zigbee2MQTT shows "Coordinator failed to start"

Wait longer - the cpcd-zigbeed container must be healthy first (takes ~60s).

```bash
docker compose ps   # Check STATUS column
```

### Reset Zigbee Network

To start fresh (removes all paired devices):

```bash
docker compose down
docker volume rm docker_zigbeed_data docker_z2m_data
docker compose up -d
```

## Building Locally

To build the cpcd-zigbeed image yourself instead of using the pre-built one:

1. Edit `docker-compose.yml`:
   ```yaml
   cpcd-zigbeed:
     # image: ghcr.io/jnilo1/cpcd-zigbeed:latest
     build:
       context: ./cpcd-zigbeed
       dockerfile: Dockerfile
   ```

2. Build and run:
   ```bash
   docker compose build cpcd-zigbeed
   docker compose up -d
   ```

## Ports

| Port | Service | Description |
|------|---------|-------------|
| 8080 | Zigbee2MQTT | Web interface |
| 1883 | Mosquitto | MQTT broker |
| 9001 | Mosquitto | MQTT WebSocket |

## Data Persistence

Data is stored in Docker volumes:

| Volume | Contents |
|--------|----------|
| `zigbeed_data` | Zigbee network tokens and state |
| `z2m_data` | Zigbee2MQTT database and settings |
| `mosquitto_data` | MQTT retained messages |

To backup: `docker compose down` then copy the volumes.

To reset: `docker compose down -v` (deletes all data).
