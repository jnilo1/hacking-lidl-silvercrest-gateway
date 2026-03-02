# NCP-UART-HW Firmware for Lidl Silvercrest Gateway

Network Co-Processor (NCP) firmware for the EFR32MG1B232F256GM48 chip found in the Lidl Silvercrest Smart Home Gateway.

This firmware enables communication with Zigbee coordinators like **Zigbee2MQTT** and **Home Assistant ZHA** via EZSP (EmberZNet Serial Protocol).

## Features

- **EZSP v13** - EmberZNet 7.5.1 serial protocol
- **Zigbee PRO R22** - Full Zigbee 3.0 support
- **Green Power** - Support for battery-free devices
- **Source routing** - 100-entry route table for large networks
- **Up to 32 children** - Sleepy end-devices supported
- **Hardware flow control** - RTS/CTS for reliable TCP operation

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
# Select [2] NCP-UART-HW
```

The script handles everything (serialgateway restart, flash, reboot).

> **Need other formats (.s37, .hex, .bin)?** Build from source (Option 2), they will be in `build/debug/`.

---

## Option 2: Build from Source

For users who want to customize network parameters or use a different EmberZNet version.

### Prerequisites

Install Silicon Labs tools (see `1-Build-Environment/12-silabs-toolchain/`):

```bash
cd 1-Build-Environment/12-silabs-toolchain
./install_silabs.sh
```

Or use Docker (see `1-Build-Environment/` for setup):

```bash
docker run --rm -v $(pwd):/workspace lidl-gateway-builder \
    /workspace/2-Zigbee-Radio-Silabs-EFR32/24-NCP-UART-HW/build_ncp.sh
```

### Build

```bash
cd 2-Zigbee-Radio-Silabs-EFR32/24-NCP-UART-HW
./build_ncp.sh
```

### Output

```
firmware/
└── ncp-uart-hw.gbl   # For UART flashing (via universal-silabs-flasher)
```

> **Other formats (.s37, .hex, .bin)** are available in `build/debug/` after compilation. Use these for J-Link/SWD flashing or debugging.

### Clean

```bash
./build_ncp.sh clean
```

### Flash

**Via network (same as Option 1):**
```bash
./flash_efr32.sh <GATEWAY_IP>
# Select [2] NCP-UART-HW
```

**Via J-Link/SWD** (if you have physical access to the SWD pads):
```bash
commander flash firmware/ncp-uart-hw.gbl \
    --device EFR32MG1B232F256GM48
```

---

## Usage

### Architecture

```
+-------------------+    UART     +-------------------+   Ethernet   +---------------------+
|  EFR32MG1B (NCP)  |   115200    |  RTL8196E         |    TCP/IP    |  Host (x86/ARM)     |
|                   |    baud     |  (Gateway SoC)    |              |                     |
|  EmberZNet Stack  |<----------->|                   |<------------>|  Zigbee2MQTT        |
|  + EZSP Protocol  |   ttyS1     |  serialgateway    |   port 8888  |       or            |
|                   |             |  (serial->TCP)    |              |  Home Assistant ZHA |
|  HW Flow Control  |             |                   |              |                     |
+-------------------+             +-------------------+              +---------------------+
```

The RTL8196E runs `serialgateway` to bridge the EFR32's UART to TCP port 8888.
See [34-Userdata](../../3-Main-SoC-Realtek-RTL8196E/34-Userdata/) for gateway setup.

### Zigbee2MQTT Configuration

Edit `configuration.yaml`:

```yaml
serial:
  port: tcp://192.168.1.X:8888
  adapter: ember
```

### Home Assistant ZHA Configuration

Add integration with:
- **Serial port path:** `socket://192.168.1.X:8888`

> **Note:** Baudrate and flow control are handled by `serialgateway` on the gateway side, not by the client application.

---

## Customization

The build process applies patches to optimize the firmware for the Lidl Gateway. See [patches/README.md](./patches/README.md) for details.

### Network Parameters

Edit `patches/apply_config.sh` to modify. For a complete guide, see the [Zigbee Network Sizing Guide](https://github.com/jnilo1/slc-projects/blob/main/ncp-uart-hw/ZIGBEE_NETWORK_SIZING_GUIDE.md).

| Parameter | Default | Range | RAM/Entry |
|-----------|---------|-------|-----------|
| `EMBER_MAX_END_DEVICE_CHILDREN` | 32 | 0-64 | ~40 bytes |
| `EMBER_PACKET_BUFFER_COUNT` | 255 | 20-255 | ~36 bytes |
| `EMBER_SOURCE_ROUTE_TABLE_SIZE` | 100 | 2-255 | ~12 bytes |
| `EMBER_BINDING_TABLE_SIZE` | 32 | 1-127 | ~20 bytes |
| `EMBER_ADDRESS_TABLE_SIZE` | 12 | 1-256 | ~16 bytes |
| `EMBER_NEIGHBOR_TABLE_SIZE` | 26 | 16/26 | ~32 bytes |
| `EMBER_KEY_TABLE_SIZE` | 12 | 1-127 | ~32 bytes |

### Network Size Presets

| Preset | Devices | Children | Buffers | Routes | Bindings |
|--------|---------|----------|---------|--------|----------|
| **Small** | <20 | 10 | 75 | 20 | 10 |
| **Medium** | 20-50 | 20 | 150 | 50 | 20 |
| **Large** (default) | 50-100 | 32 | 255 | 100 | 32 |
| **Very Large** | 100-150 | 48 | 255 | 150 | 48 |

> **Warning**: The EFR32MG1B has only 32KB RAM. Current configuration uses ~27KB. Increasing parameters beyond presets may cause instability.

---

## Technical Details

### Memory Usage

| Resource | Used | Available |
|----------|------|-----------|
| Flash | ~200 KB (78%) | 256 KB |
| RAM | ~24 KB (75%) | 32 KB |
| NVM3 | 36 KB | Network data storage |

### Optimizations Applied

To fit in 256KB flash, the following were removed:

| Component | Savings | Reason |
|-----------|---------|--------|
| Debug print | ~12 KB | No debug output needed |
| ZLL / touchlink | ~4 KB | Not used |
| Virtual UART | ~1 KB | Not needed |
| PTI (Packet Trace) | ~2 KB | No debug probe |

### Features

- **RTL8196E Boot Delay:** 1-second delay for host UART initialization
- **Hardware Flow Control:** RTS/CTS required for reliable TCP operation
- **NVM3 Storage:** 36KB for network credentials and tokens

---

## Troubleshooting

### No response from NCP

1. Verify TCP connection: `nc -zv <gateway-ip> 8888`
2. Check baud rate matches (115200) on firmware and serialgateway
3. Verify hardware flow control is enabled on serialgateway

### EZSP communication errors

1. Ensure Z2M/ZHA is configured for `ember` adapter
2. Check for EZSP version mismatch (this firmware is EZSP v13)
3. Restart serialgateway with hardware flow control: `serialgateway` (not `-f`)

### Device won't pair

1. Enable permit join in Z2M/ZHA
2. Factory reset the device
3. Move device closer to coordinator for initial pairing

---

## Files

```
24-NCP-UART-HW/
├── build_ncp.sh                 # Build script
├── README.md                    # This file
├── firmware/                    # Pre-built firmware files
│   ├── ncp-uart-hw-7.5.1.gbl
└── patches/
    ├── README.md                # Patch documentation
    ├── apply_config.sh          # Configuration script
    ├── ncp-uart-hw.slcp         # Project config
    ├── main.c                   # Entry point (1s delay)
    └── sl_*.h                   # Configuration headers
```

---

## Related Projects

- `25-RCP-UART-HW/` - RCP firmware (CPC protocol, for cpcd + zigbeed)
- `26-OT-RCP/` - OpenThread RCP (for zigbee-on-host)
- `27-Router/` - Autonomous Zigbee router (no host needed)

## References

- [EZSP Protocol Reference (UG100)](https://www.silabs.com/documents/public/user-guides/ug100-ezsp-reference-guide.pdf)
- [EmberZNet NCP Guide (UG115)](https://www.silabs.com/documents/public/user-guides/ug115-ncp-user-guide.pdf)
- [AN1233: Zigbee Stack Configuration](https://www.silabs.com/documents/public/application-notes/an1233-zigbee-stack-config.pdf)

## License

Educational and personal use. Silicon Labs SDK components under their respective licenses.
