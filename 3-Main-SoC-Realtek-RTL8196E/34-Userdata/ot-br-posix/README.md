# OpenThread Border Router (POSIX) for RTL8196E

Cross-compilation of [ot-br-posix](https://github.com/openthread/ot-br-posix) for Realtek RTL8196E (Lexra MIPS) with musl libc.

## Status

Tested on the Lidl Silvercrest Zigbee gateway (RTL8196E + EFR32MG21) with
an IKEA TIMMERFLOTTE Thread sensor commissioned via Home Assistant Companion App.

The gateway runs as Thread Border Router leader with ~20 MB free RAM (out of 32 MB).

## Prerequisites

### 1. EFR32 with OT-RCP firmware

The Silabs EFR32 radio must be flashed with the OpenThread RCP firmware
(see `../../2-Zigbee-Radio-Silabs-EFR32/25-RCP-UART-HW/`).

### 2. Kernel with IPv6 and IEEE 802.15.4

The stock kernel does not include IPv6. You must rebuild with the unified config
`../32-Kernel/config-5.10.246-realtek.txt` which includes:

```
CONFIG_IPV6=y                    # IPv6 networking stack
CONFIG_IPV6_ROUTER_PREF=y        # Router preference
CONFIG_IPV6_MULTIPLE_TABLES=y    # Multiple routing tables
CONFIG_TUN=y                     # TUN/TAP device (for wpan0)
CONFIG_IEEE802154=y              # IEEE 802.15.4 support
CONFIG_FILE_LOCKING=y            # Required by otbr-agent settings
```

Note: Netfilter is **not** required — the RTL8196E ethernet driver is incompatible
with it, and `otbr-agent` is built with `OT_FIREWALL=OFF`.

### 3. BusyBox with IPv6 and `ip` command

The BusyBox build must include:

```
CONFIG_FEATURE_IPV6=y           # Core IPv6 support
CONFIG_PING6=y                  # ping6 command
CONFIG_IP=y                     # ip command
CONFIG_IPADDR=y                 # ip addr
CONFIG_IPLINK=y                 # ip link
CONFIG_IPROUTE=y                # ip route
CONFIG_IPNEIGH=y                # ip neigh
```

## Architecture

```
                      Local Network (WiFi/Ethernet)
              Matter Controllers (Google Home, Apple Home...)
                              |
                              | IPv4/IPv6
                              |
    +---------------------------------------------------------+
    |                    RTL8196E Gateway                      |
    |                                                         |
    |  +----------+                          +-----------+    |
    |  |   eth0   |<----- IPv6 routing ----->|   wpan0   |    |
    |  | Ethernet |                          | (TUN/TAP) |    |
    |  +----------+                          +-----+-----+    |
    |       |                                      |          |
    |       |            +--------------+          |          |
    |       +----------->|  otbr-agent  |<---------+          |
    |                    |  - Border Agent                    |
    |                    |  - mDNS/DNS-SD                     |
    |                    |  - REST API (:8081)                |
    |                    |  - IPv6 Router                     |
    |                    +-------+------+                     |
    |                            | Spinel/HDLC (UART)         |
    |                    +-------+------+                     |
    |                    |  Silabs RCP  |                     |
    |                    |  (EFR32)     |                     |
    |                    +-------+------+                     |
    +---------------------------------------------------------+
                                 | 802.15.4 radio
                                 v
    +---------------------------------------------------------+
    |                   Thread Network (mesh)                  |
    |    +---------+    +---------+    +---------+            |
    |    | Matter  |    | Matter  |    | Matter  |            |
    |    | Device  |    | Device  |    | Device  |            |
    |    +---------+    +---------+    +---------+            |
    +---------------------------------------------------------+
```

## Features

### Enabled

| Feature | CMake Option | Description |
|---------|--------------|-------------|
| Border Agent | `OTBR_BORDER_AGENT=ON` | Thread commissioning (Matter/HomeKit compatible) |
| mDNS/DNS-SD | `OTBR_MDNS=openthread` | Built-in implementation (no Avahi needed) |
| SRP Advertising Proxy | (auto) | Service Registration Protocol proxy |
| DNS-SD Discovery Proxy | (auto) | DNS-based service discovery |
| Border Routing | `OTBR_BORDER_ROUTING=ON` | IPv6 routing between Thread and infrastructure |
| REST API | `OTBR_REST=ON` | HTTP API on port 8081 (used by Home Assistant) |
| Commissioner | `OT_COMMISSIONER=ON` | Required by REST API |

### Disabled

| Feature | CMake Option | Reason |
|---------|--------------|--------|
| Firewall | `OT_FIREWALL=OFF` | No netfilter/ipset on RTL8196E |
| D-Bus | `OTBR_DBUS=OFF` | No D-Bus on embedded target |
| Web UI | `OTBR_WEB=OFF` | Reduces binary size |
| Backbone Router | `OTBR_BACKBONE_ROUTER=OFF` | Advanced feature, not needed |
| TREL | `OTBR_TREL=OFF` | Thread Radio Encapsulation Link |
| NAT64 | `OTBR_NAT64=OFF` | Requires TAYGA |
| DNS Upstream | `OTBR_DNS_UPSTREAM_QUERY=OFF` | Advanced feature |

## Build Notes

### Socket path override

The rootfs is read-only (squashfs) with no `/run` directory. The build overrides
the default socket path via compiler flag:

```
-DOPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME='"/tmp/openthread-%s"'
```

This places the Unix socket and lock file in `/tmp/` instead of `/run/`.

### Circular library dependencies

Static linking requires `--start-group`/`--end-group` to resolve circular
dependencies between `openthread-ftd` and `openthread-posix`. The CMake
toolchain file overrides the link command to handle this automatically.

## Building

```bash
./build_otbr.sh
```

Produces statically linked binaries:
- `otbr-agent` (~4.3 MB stripped)
- `ot-ctl` (~57 KB stripped)

## Installing

The binaries are included in the userdata skeleton at `skeleton/usr/bin/`.
They are deployed automatically when building and flashing userdata.

For manual installation via SSH:

```bash
# Replace GATEWAY_IP with your gateway's IP address
cat build/src/agent/otbr-agent | ssh root@GATEWAY_IP:8888 'cat > /userdata/usr/bin/otbr-agent && chmod +x /userdata/usr/bin/otbr-agent'
cat build/third_party/openthread/repo/src/posix/ot-ctl | ssh root@GATEWAY_IP:8888 'cat > /userdata/usr/bin/ot-ctl && chmod +x /userdata/usr/bin/ot-ctl'
```

## Radio Mode Selection

The gateway supports both Zigbee and Thread via `/userdata/etc/radio.conf`:

- **Zigbee** (default): no `radio.conf` file, `S60serialgateway` starts
- **Thread**: `radio.conf` contains `MODE=otbr`, `S70otbr` starts, `S60serialgateway` is skipped

The mode is selected at flash time via `flash_userdata.sh`.

## Usage

### Running otbr-agent

The init script `S70otbr` starts otbr-agent automatically at boot (when in Thread mode):

```bash
# UART-connected RCP on /dev/ttyS1 at 115200 baud
otbr-agent -I wpan0 -B eth0 \
    --rest-listen-address ::0 --rest-listen-port 8081 \
    --vendor-name "Lidl" --model-name "Silvercrest" \
    spinel+hdlc+uart:///dev/ttyS1?uart-baudrate=115200
```

### Using ot-ctl

```bash
# Connect to running otbr-agent
ot-ctl

# Example commands:
> state           # leader, router, child, disabled...
> dataset active  # Active Thread dataset
> ipaddr          # IPv6 addresses
> child table     # Connected Thread devices
> srp server      # SRP server status
```

### Thread dataset persistence

Thread network credentials are stored in `/userdata/thread/` and survive reboots.
On restart, `otbr-agent` automatically re-attaches to the saved network (`--auto-attach=1` default).

Note: reflashing userdata erases the Thread dataset — devices will need to be re-commissioned.

## Directory Structure

```
ot-br-posix/
├── build_otbr.sh          # Build script
├── README.md              # This file
├── ot-br-posix/           # Cloned source repository (created by script)
└── build/                 # CMake build directory (created by script)
    ├── toolchain-mips-lexra.cmake
    ├── src/agent/otbr-agent
    └── third_party/openthread/repo/src/posix/ot-ctl
```

## References

- [OpenThread Border Router](https://openthread.io/guides/border-router)
- [ot-br-posix GitHub](https://github.com/openthread/ot-br-posix)
- [Thread Specification](https://www.threadgroup.org/)
- [Matter Protocol](https://csa-iot.org/all-solutions/matter/)

## License

ot-br-posix is licensed under BSD-3-Clause.
