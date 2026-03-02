# RCP 802.15.4 Firmware with cpcd + zigbeed

Radio Co-Processor (RCP) firmware for the EFR32MG1B232F256GM48 chip found in the Lidl Silvercrest Smart Home Gateway.

This firmware transforms the gateway's Zigbee chip into a **Radio Co-Processor** that runs the Zigbee stack on an external Linux host (your PC, Raspberry Pi, or server) instead of the limited RTL8196E.

## About RCP Architecture

Unlike standalone firmware (like the Router), an RCP delegates the entire Zigbee protocol stack to a host computer. The EFR32 only handles the radio PHY/MAC layer and communicates with the host via the **CPC Protocol** (Co-Processor Communication).

```
+-------------------+    UART     +-------------------+   Ethernet   +---------------------+
|  EFR32MG1B (RCP)  |   115200    |  RTL8196E         |    TCP/IP    |  Host (x86/ARM)     |
|                   |    baud     |  (Gateway SoC)    |              |                     |
|  802.15.4 PHY/MAC |<----------->|                   |<------------>|  cpcd               |
|  + CPC Protocol   |   ttyS1     |  serialgateway    |   port 8888  |    |                |
|                   |             |  (serial->TCP)    |              |    v                |
|  CPC Protocol v5  |             |                   |              |  zigbeed            |
|  HW Flow Control  |             |                   |              |  (Zigbee stack)     |
|                   |             |                   |              |    |                |
+-------------------+             +-------------------+              |    v                |
                                                                     |  Zigbee2MQTT        |
                                                                     +---------------------+
```

**Why use RCP instead of NCP?**

| Aspect | NCP (24-NCP-UART-HW) | RCP (this firmware) |
|--------|----------------------|---------------------|
| Stack location | On EFR32 (limited RAM) | On host (unlimited resources) |
| Protocol | EZSP (binary) | CPC (multiplexed) |
| Multiprotocol | No | Yes (Zigbee + Thread) |
| Stack updates | Requires reflash | Just update zigbeed |
| Network size | Limited by EFR32 RAM | Host memory is the limit |

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
# Select [3] RCP-UART-HW
```

The script handles everything (serialgateway restart, flash, reboot).

Then continue to [Host Software Setup](#host-software-setup) to configure cpcd and zigbeed on your host machine.

---

## Option 2: Build from Source

For users who want to modify the CPC configuration, change baudrate, or use a different SDK version.

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
- Gecko SDK with EmberZNet

### Build

```bash
cd 2-Zigbee-Radio-Silabs-EFR32/25-RCP-UART-HW
./build_rcp.sh
```

### Output

```
firmware/
└── rcp-uart-802154.gbl   # For UART/Xmodem flashing
```

### Customization

Edit `patches/rcp-uart-802154.slcp` for SDK configuration, or `patches/sl_cpc_drv_uart_usart_vcom_config.h` for UART settings (pins, baudrate).

### Flash

**Via network (same as Option 1):**
```bash
./flash_efr32.sh <GATEWAY_IP>
# Select [3] RCP-UART-HW
```

**Via J-Link/SWD** (if you have physical access to the SWD pads):
```bash
commander flash firmware/rcp-uart-802154.gbl \
    --device EFR32MG1B232F256GM48
```

> For a detailed explanation of how `universal-silabs-flasher` works (firmware detection, bootloader entry, the `-f` flag, troubleshooting), see [22-Backup-Flash-Restore](../22-Backup-Flash-Restore/).

---

## Host Software Setup

After flashing the RCP firmware, you need to configure the host software chain.

### Required Components

| Component | Version | Source | Description |
|-----------|---------|--------|-------------|
| cpcd | v4.5.3 | [SiliconLabs/cpc-daemon](https://github.com/SiliconLabs/cpc-daemon) | CPC daemon |
| zigbeed | EmberZNet 8.2.2 | Simplicity SDK 2025.6.2 | Zigbee stack daemon (recommended) |
| zigbeed | EmberZNet 7.5.1 | Gecko SDK 4.5.0 | Zigbee stack daemon (legacy) |

### Build Instructions

See subdirectories for detailed build instructions:
- `cpcd/` - CPC daemon (for host)
- `zigbeed-8.2.2/` - zigbeed EmberZNet 8.2.2 (recommended)
- `zigbeed-7.5.1/` - zigbeed EmberZNet 7.5.1 (legacy)
- `rcp-stack/` - Systemd service manager for the complete chain
- `cpcd-rtl8196e/` - Cross-compile cpcd for gateway (experimental)

### Quick Start with Docker (Recommended)

A pre-built Docker image is available for **PC (amd64)** and **Raspberry Pi (arm64)**:

```bash
# Pull the image
docker pull ghcr.io/jnilo1/cpcd-zigbeed:latest

# Or use the full stack with Zigbee2MQTT
cd docker/
# Edit docker-compose.yml: set RCP_HOST to your gateway's IP
docker compose up -d
```

See `docker/README.md` for detailed instructions.

| Image | cpcd | EmberZNet | EZSP | Architectures |
|-------|------|-----------|------|---------------|
| `ghcr.io/jnilo1/cpcd-zigbeed:latest` | 4.5.3 | 8.2.2 | v18 | amd64, arm64 |

### Quick Start with rcp-stack (Native)

The `rcp-stack` tool manages the entire cpcd + zigbeed chain natively (without Docker):

```bash
# Start the stack
rcp-stack up

# Check status
rcp-stack status

# Stop the stack
rcp-stack down

# Troubleshoot
rcp-stack doctor
```

### Zigbee2MQTT Configuration

With rcp-stack (recommended):
```yaml
serial:
  port: /tmp/ttyZ2M
  adapter: ember
```

---

## Baudrate and Network Considerations

### Baudrate Options

| Baudrate | Status | Notes |
|----------|--------|-------|
| **115200** | **Default** | Conservative, reliable |
| 230400 | Supported | Tested, works reliably |
| 460800+ | **Not supported** | Causes UART overruns |

### Network Size vs Baudrate

| Liaison | Throughput |
|---------|------------|
| 802.15.4 radio | ~25 KB/s |
| UART 115200 | ~11 KB/s |
| UART 230400 | ~23 KB/s |

At 115200, the UART is ~2x slower than the Zigbee radio. Practical impact:

| Network size | 115200 | 230400 |
|--------------|--------|--------|
| < 50 devices | OK | OK |
| 50-100 devices | OK* | Recommended |
| > 100 devices | May bottleneck | Recommended |

*OK for normal use; possible latency during traffic spikes (OTA updates, large groups).

For most home installations, 115200 is sufficient.

### Why 460800+ Doesn't Work

The RTL8196E UART has hardware limitations:
- **16-byte FIFO** (16550A standard) with RX trigger at 8 bytes
- At 460800 baud, the CPU has only **170 µs** to respond before overrun
- `serialgateway` runs in userspace, adding context switch latency

Check UART errors on the gateway:
```bash
cat /proc/tty/driver/serial
# fe:xxx = framing errors, oe:xxx = overrun errors
```

### Changing Baudrate

To use 230400:
1. Edit `patches/sl_cpc_drv_uart_usart_vcom_config.h`
2. Edit `patches/rcp-uart-802154.slcp`
3. Rebuild firmware and flash
4. Update `serialgateway -b 230400` on gateway
5. Update `cpcd.conf` with `uart_device_baud: 230400`

---

## TCP Stability Requirements

The CPC protocol is sensitive to network conditions. For reliable operation:

| Requirement | Why |
|-------------|-----|
| **Hardware flow control** | Prevents buffer overruns |
| **Direct Ethernet** | Minimizes latency and jitter |
| **No WiFi bridges** | WiFi adds unpredictable latency |
| **Avoid congested switches** | Packet delays cause CPC timeouts |

**Recommended:** Connect the gateway directly to the host with an Ethernet cable.

---

## Troubleshooting

### Flashing Issues

| Problem | Solution |
|---------|----------|
| No response from RCP | Verify TCP: `nc -zv <gateway-ip> 8888` |
| Xmodem timeout | Close all SSH sessions, use `-f` flag |
| Wrong firmware flashed | Reflash - the bootloader is always preserved |

### cpcd Connection Issues

| Problem | Solution |
|---------|----------|
| cpcd won't connect | Check `tcp_client_address` in cpcd.conf |
| CPC version mismatch | Use GSDK 4.5.0 for CPC Protocol v5 |
| Frequent disconnects | Use direct Ethernet, check for WiFi bridges |

### zigbeed Issues

| Problem | Solution |
|---------|----------|
| zigbeed won't start | Check cpcd is running: `rcp-stack status` |
| Stack version mismatch | Rebuild zigbeed with matching SDK version |

---

## Memory Usage

| Resource | Used | Available |
|----------|------|-----------|
| Flash | ~116 KB | 256 KB |
| RAM | ~22 KB | 32 KB |

---

## Features

- **RTL8196E Boot Delay:** 1-second delay for host UART initialization
- **Hardware Flow Control:** RTS/CTS required for reliable TCP operation
- **CPC Security Disabled:** Saves ~45KB flash (not needed for local network)
- **Multiprotocol Ready:** Can run Zigbee + OpenThread simultaneously

---

## Project Structure

```
25-RCP-UART-HW/
├── build_rcp.sh                 # RCP firmware build script
├── README.md                    # This file
├── patches/                     # RCP firmware patches
│   ├── rcp-uart-802154.slcp                 # Project config
│   ├── main.c                               # Entry point (1s delay)
│   ├── sl_cpc_drv_uart_usart_vcom_config.h  # UART pins
│   └── sl_cpc_security_config.h             # CPC security disabled
├── firmware/                    # Output (rcp-uart-802154.gbl)
├── cpcd/                        # CPC daemon build scripts
├── zigbeed-7.5.1/               # zigbeed EmberZNet 7.5.1 (legacy)
├── zigbeed-8.2.2/               # zigbeed EmberZNet 8.2.2 (recommended)
├── docker/                      # Docker stack (cpcd + zigbeed + Z2M)
└── rcp-stack/                   # Systemd service manager
    ├── bin/rcp-stack            # Main script
    ├── scripts/                 # Helper scripts
    ├── systemd/user/            # Service units
    └── examples/                # Config examples
```

---

## Related Projects

- `24-NCP-UART-HW/` - NCP firmware (simpler, stack on EFR32)
- `27-Router/` - Router firmware (autonomous, no host needed)

## References

- [CPC Daemon](https://github.com/SiliconLabs/cpc-daemon)
- [AN1333: Multiprotocol RCP](https://www.silabs.com/documents/public/application-notes/an1333-concurrent-protocols-with-802-15-4-rcp.pdf)
- [serialgateway](../../3-Main-SoC-Realtek-RTL8196E/34-Userdata/serialgateway/)

## License

Educational and personal use. Silicon Labs SDK components under their respective licenses.
