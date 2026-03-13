# User Data Partition

This directory contains the writable user partition for the gateway.

## Overview

Unlike the root filesystem (read-only SquashFS), the userdata partition uses **JFFS2** — a writable, wear-leveling filesystem designed for flash memory.

This partition is **essential** because:

1. The rootfs `/etc` symlinks most configuration files here
2. **All init scripts** are stored here (the rootfs only contains a bootstrap)
3. User applications and customizations live here

This design allows modifying configuration and adding services without rebuilding the read-only rootfs.

## Boot Integration

The rootfs bootstrap (`/etc/init.d/rcS`) mounts this partition at `/userdata`, then executes all scripts matching `/userdata/etc/init.d/S??*` in alphanumeric order.

```
Rootfs bootstrap
  ↓
Mount /userdata (JFFS2)
  ↓
Execute init scripts:
  S05syslog      → Start system logging
  S10network     → Configure network (DHCP or static)
  S15hostname    → Set hostname, /etc/hosts
  S20time        → Sync time via NTP
  S30dropbear    → Start SSH server
  S60serialgateway → Start Zigbee bridge (if radio mode = zigbee)
  S70otbr        → Start Thread border router (if radio mode = otbr)
  S90checkpasswd → Warn if default password
```

## Partition Structure

```
/userdata/
├── etc/
│   ├── passwd          # User accounts (with password hashes)
│   ├── group           # User groups
│   ├── hostname        # Gateway hostname
│   ├── profile         # Shell profile (TERM, TERMINFO, resize)
│   ├── motd            # Message of the day
│   ├── TZ              # Timezone
│   ├── ntp.conf        # NTP server configuration
│   ├── eth0.bak        # Static IP template (for reference)
│   ├── radio.conf      # Radio mode: MODE=otbr for Thread (absent = Zigbee)
│   ├── dropbear/       # Dropbear SSH host keys (generated on first boot)
│   └── init.d/         # Init scripts (executed by rootfs bootstrap)
│       ├── S05syslog
│       ├── S10network
│       ├── S15hostname
│       ├── S20time
│       ├── S30dropbear
│       ├── S60serialgateway
│       ├── S70otbr
│       └── S90checkpasswd
├── ssh/
│   └── authorized_keys # SSH public keys for passwordless access
├── thread/             # Thread network credentials (created by otbr-agent)
└── usr/
    ├── bin/            # User applications (nano, serialgateway, otbr-agent, ot-ctl, boothold)
    └── share/
        └── terminfo/   # Terminal definitions (linux, vt100, vt102, xterm)
```

## Network Configuration

`flash_userdata.sh` asks for network configuration and radio mode at flash time.
The settings are baked into `userdata.bin` before flashing.

To change the IP after flashing, edit `/userdata/etc/eth0.conf` on the running gateway:

```bash
vi /etc/eth0.conf
```

Format:
```
IPADDR=192.168.1.88
NETMASK=255.255.255.0
GATEWAY=192.168.1.1
```

Then restart the network: `/userdata/etc/init.d/S10network restart`

`/userdata/etc/eth0.bak` is provided as a reference template.

## Radio Mode

The gateway supports two radio modes, selected at flash time:

| Mode | Config | Init script | EFR32 firmware | Use case |
|------|--------|-------------|----------------|----------|
| **Zigbee** (default) | no `radio.conf` | `S60serialgateway` | NCP or RCP+zigbeed | Zigbee2MQTT, ZHA |
| **Thread** | `MODE=otbr` | `S70otbr` | OT-RCP | Matter, Home Assistant Thread |

The mode is controlled by `/userdata/etc/radio.conf`. When set to Thread mode, `S60serialgateway` is skipped and `S70otbr` starts `otbr-agent` instead.

See `ot-br-posix/README.md` for Thread-specific documentation.

### Switching Radio Mode

To switch between modes on a running gateway:

**Thread → Zigbee:**
```bash
# 1. Stop otbr-agent
/userdata/etc/init.d/S70otbr stop

# 2. Remove radio.conf (reverts to Zigbee mode)
rm /userdata/etc/radio.conf

# 3. Reflash EFR32 with NCP firmware (from your workstation)
./flash_efr32.sh <GATEWAY_IP>
# Select [2] NCP-UART-HW

# 4. Gateway reboots — serialgateway starts automatically
```

**Zigbee → Thread:**
```bash
# 1. Stop serialgateway
/userdata/etc/init.d/S60serialgateway stop

# 2. Set radio mode to Thread
echo "MODE=otbr" > /userdata/etc/radio.conf

# 3. Reflash EFR32 with OT-RCP firmware (from your workstation)
./flash_efr32.sh <GATEWAY_IP>
# Select [3] RCP-UART-HW

# 4. Gateway reboots — otbr-agent starts automatically
```

Alternatively, reflash userdata with `flash_userdata.sh` which prompts for the radio mode.

## SSH Passwordless Access

The `/userdata/ssh/authorized_keys` file allows SSH access without a password. Add your public key to this file:

```bash
# On your workstation, copy your public key
cat ~/.ssh/id_rsa.pub

# Add it to authorized_keys on the gateway
echo "ssh-rsa AAAA... user@host" >> /userdata/ssh/authorized_keys
```

Dropbear is configured to read this file, enabling secure key-based authentication.

## Contents

| Directory/File | Description |
|----------------|-------------|
| `skeleton/` | Base structure for the user partition |
| `nano/` | GNU nano text editor build |
| `serialgateway/` | Zigbee serial gateway build |
| `ot-br-posix/` | OpenThread Border Router build |
| `build_userdata.sh` | Script to assemble and package the partition |

## Building

```bash
# Build nano (optional)
cd nano && ./build_nano.sh && cd ..

# Build serialgateway
cd serialgateway && ./build_serialgateway.sh && cd ..

# Build otbr-agent (optional, for Thread mode)
cd ot-br-posix && ./build_otbr.sh && cd ..

# Assemble and package userdata
./build_userdata.sh
```

## Output

- `userdata.bin` — Flashable JFFS2 image with Realtek header (~12 MB)

## Included Applications

### nano

Lightweight text editor for editing configuration files directly on the gateway.

**Terminal support:** nano requires terminal capability definitions (terminfo) to display correctly. The `profile` sets up `TERMINFO` to point to `/userdata/usr/share/terminfo/` which includes definitions for common terminal types:

| Terminal | Use case |
|----------|----------|
| `linux` | Direct console access |
| `vt100` | Basic serial terminal |
| `vt102` | Minicom, PuTTY (VT102 mode) |
| `xterm` | SSH from modern terminals |

If your terminal emulator uses a different type, you can add the corresponding terminfo file to `/userdata/usr/share/terminfo/<first-letter>/<name>`.

**Terminal size:** The `profile` automatically runs `resize` at login to detect the terminal dimensions. This ensures nano and other curses applications display at the correct size.

### serialgateway

A lightweight serial-to-TCP bridge that exposes the Zigbee UART (`/dev/ttyS1`) over the network. This allows Zigbee2MQTT, Home Assistant ZHA, or other Zigbee coordinators to communicate with the Silabs EFR32 radio remotely.

**Default configuration:**
- Listens on TCP port **8888**
- Connects to `/dev/ttyS1` at **115200** baud
- Single client mode (new connection closes the previous one)

**Options:**
| Option | Description |
|--------|-------------|
| `-p <port>` | TCP port to listen on (default: 8888) |
| `-d <device>` | Serial device (default: /dev/ttyS1) |
| `-b <baud>` | Baud rate (default: 115200) |
| `-f` | Disable hardware flow control (default: enabled) |
| `-D` | Stay in foreground (don't daemonize) |
| `-q` | Quiet mode (suppress info messages) |
| `-v` | Show version and exit |
| `-h` | Show help |

**Usage with Zigbee2MQTT:**
```yaml
serial:
  port: tcp://<GATEWAY_IP>:8888
```

**Usage with Home Assistant ZHA:**
```
socket://<GATEWAY_IP>:8888
```

## Adding Custom terminfo

To add support for additional terminal types:

1. On a Linux system with the desired terminfo, locate the file:
   ```bash
   find /usr/share/terminfo /lib/terminfo -name "myterm"
   ```

2. Copy it to the gateway:
   ```bash
   cat /lib/terminfo/m/myterm | ssh root@<GATEWAY_IP> "cat > /userdata/usr/share/terminfo/m/myterm"
   ```

3. Set the terminal type:
   ```bash
   export TERM=myterm
   ```

## Adding Your Own Applications

Cross-compiling applications for the gateway is straightforward. Use the existing `build_*.sh` scripts as templates:

1. **Cross-compile** your application using the toolchain:
   ```bash
   # From project root:
   export PATH="$(pwd)/x-tools/mips-lexra-linux-musl/bin:$PATH"
   export CC=mips-lexra-linux-musl-gcc
   ./configure --host=mips-linux
   make
   ```

2. **Strip** the binary to reduce size:
   ```bash
   mips-lexra-linux-musl-strip myapp
   ```

3. **Transfer** to the gateway via SSH:
   ```bash
   cat myapp | ssh root@<GATEWAY_IP> "cat > /userdata/usr/bin/myapp"
   ssh root@<GATEWAY_IP> "chmod +x /userdata/usr/bin/myapp"
   ```

The application is immediately available — no reboot required.

## Adding Custom Init Scripts

To add a new service that starts at boot:

1. Create a script in `/userdata/etc/init.d/` with a name like `S70myservice`
2. Make it executable: `chmod +x S70myservice`
3. The script should accept `start`, `stop`, and optionally `restart` arguments

Example:
```bash
#!/bin/sh
case "$1" in
start)
    echo "Starting myservice..."
    /userdata/usr/bin/myservice &
    ;;
stop)
    echo "Stopping myservice..."
    killall myservice
    ;;
restart)
    $0 stop
    $0 start
    ;;
esac
```

The number prefix (S70) determines execution order — lower numbers run first.

## Mount Point

The userdata partition is mounted at `/userdata` by the rootfs bootstrap. The rootfs `/etc` symlinks point here, making this partition the source of truth for all configuration.
