# Hacking the Lidl Silvercrest Gateway

> **If you find this project useful, please consider [giving it a star](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway)!** It helps others discover it and motivates continued development.
>
> **Documentation site:** https://jnilo1.github.io/hacking-lidl-silvercrest-gateway/ — full project docs with search and navigation.
>
> Questions? Use [Discussions](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions). Found a bug? Open an [Issue](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/issues).

## What Can You Do With This?

The **Lidl Silvercrest Zigbee Gateway** is normally locked to the Tuya cloud.
This project replaces the firmware and turns it into a **fully local, open smart home hub** — Zigbee coordinator, Thread Border Router, or Zigbee router:

- **Zigbee coordinator** — use with Zigbee2MQTT or ZHA to pair and control any Zigbee device, no cloud
- **Modern Zigbee stacks on a Series-1 chip** — run **EmberZNet 8.2** host-side
  (cpcd + zigbeed), or hand the whole stack to Zigbee2MQTT's **ZigBee-on-Host**
  (`zoh`) adapter — you are not stuck at the chip's last on-chip NCP release (7.5.1)
- **Thread Border Router** — run otbr-agent natively on the gateway, compatible with Home Assistant
- **Zigbee router** — extend your Zigbee mesh with a standalone 3.0 router
- **SSH access** — full Linux shell on the gateway (BusyBox + Dropbear)
- **OTA firmware updates** — flash the Zigbee/Thread radio over the network, no SWD needed

The gateway has two chips: a **Realtek RTL8196E** running Linux, and a **Silabs EFR32MG1B**
Zigbee/Thread radio connected via UART. This project provides firmware for both.

And not only this gateway: the RTL8196E sits in many cheap Zigbee hubs of the
same era, and since v3.10.0 everything board-specific (pins, wiring, memory
size) lives in the device tree, with per-board kernel builds
(`BOARD=<board> ./build_kernel.sh`) and a documented add-a-board recipe. If
you own another RTL8196E-based gateway, porting this firmware is a recipe,
not a fork — a community port to the **Sengled Smart Hub G4** is in progress
([#119](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/119)).

______________________________________________________________________

## Quick Start

### What You Need

- A Lidl Silvercrest Zigbee Gateway
- USB-to-serial adapter (3.3V, 38400 8N1) — for the initial flash only
- Ethernet connection to the gateway
- **SSH access to the gateway** (only for upgrades and `flash_efr32.sh`):
  - **SSH key** (recommended): copy your public key once with
    `ssh-copy-id root@<LINUX_IP>` and every script call after that runs
    silently.
  - **Encrypted key** without `ssh-agent`, or **root password** only: works
    too. The first SSH call in each script prompts you once
    (passphrase or password); subsequent commands ride the same multiplexed
    channel — no re-prompting.
  - **Non-interactive (CI / automation) with password only**: set
    `SSH_PASSWORD=<root password>` in the environment. The scripts use
    `sshpass` to feed the password to the first ssh call (so install
    `sshpass` in that case: `sudo apt install sshpass`); subsequent calls
    ride the multiplexed channel, no further input needed.

  The default password on a fresh install is `root` — change it as soon as
  the gateway boots. `S90checkpasswd` will warn at every login until you do.

### Step 1: Clone and Flash the Linux System

```bash
git clone https://github.com/jnilo1/hacking-lidl-silvercrest-gateway.git
cd hacking-lidl-silvercrest-gateway

# First flash — gateway must be in bootloader mode (<RealTek> prompt via serial ESC):
./flash_install_rtl8196e.sh

# Upgrade — gateway running Linux (saves config automatically):
./flash_install_rtl8196e.sh 192.168.1.88

# Fully automated upgrade (firmware >= v2.0.0, no prompts):
./flash_install_rtl8196e.sh -y 192.168.1.88
```

The script builds a complete 16 MiB flash image and uploads it via TFTP.

> **Board & kernel (advanced):** the defaults install the **Lidl** board with the **6.18**
> kernel. For another combination, prefix any command with `BOARD=` and/or `KERNEL=` — e.g.
> `KERNEL=7.1 ./flash_install_rtl8196e.sh 192.168.1.88` or
> `BOARD=sengled-e39-g8c ./flash_install_rtl8196e.sh`. `BOARD` ∈ {`lidl`, `sengled-e39-g8c`},
> `KERNEL` ∈ {`6.18`, `7.1`}. These same two variables work on every flash/build script.

- **First flash** (no argument): the gateway must already be in bootloader mode
  (serial console + ESC on power-on). User config cannot be saved — you will be
  prompted for network and radio settings.
- **Upgrade** (with `LINUX_IP`): connects via SSH, saves user config (network,
  password, SSH keys, radio mode), triggers boothold + reboot, then flashes.
  On firmware >= v2.0.0, the `-y` flag enables fully unattended operation.
- For older bootloaders (Tuya/V1.2), the script guides you through the FLW
  command on the serial console.

See [35-Migration](./3-Main-SoC-Realtek-RTL8196E/35-Migration/README.md) for details.

### Step 2: Flash the Zigbee Radio

Once the gateway is running (SSH access on port 22):

```bash
./flash_efr32.sh -y ncp                    # default IP 192.168.1.88
./flash_efr32.sh -y ncp 460800             # NCP at 460800 baud
./flash_efr32.sh -y -g 10.0.0.5 otrcp      # custom IP, OT-RCP
BOARD=sengled-e39-g8c ./flash_efr32.sh -y ncp   # Sengled Smart Hub G4 (Lidl users set nothing)
./flash_efr32.sh --help                    # full CLI reference
```

Pick the firmware for your use case (alias = `bootloader`, `ncp`, `rcp`,
`otrcp`, `router` — numeric `1`-`5` also accepted):

| Choice | Firmware | Use with |
|--------|----------|----------|
| **NCP-UART-HW** | EmberZNet 7.5.1 (EZSP) | zigbee2mqtt, ZHA — simplest setup |
| **RCP-UART-HW** | 802.15.4 RCP (CPC) | zigbee2mqtt with **EmberZNet 8.2** running host-side (cpcd + zigbeed) — the newest Zigbee stack on this Series-1 chip |
| **OT-RCP** | OpenThread RCP | otbr-agent (Thread Border Router), or zigbee2mqtt's **ZigBee-on-Host** (`zoh` adapter) |

### Step 3: Connect Zigbee2MQTT

In your zigbee2mqtt `configuration.yaml`:

```yaml
serial:
  port: tcp://<LINUX_IP>:8888
  adapter: ember
```

Open the web UI at `http://localhost:8080` and start pairing devices.

______________________________________________________________________

## Repository Structure

| Directory | Contents |
|-----------|----------|
| [0-Hardware](./0-Hardware/README.md) | PCB photos, pinout, chip specs |
| [1-Build-Environment](./1-Build-Environment/README.md) | Toolchains (Lexra MIPS + ARM GCC + Silabs slc-cli) |
| [2-Zigbee-Radio-Silabs-EFR32](./2-Zigbee-Radio-Silabs-EFR32/README.md) | EFR32 firmware: bootloader, NCP, RCP, OT-RCP, router |
| [3-Main-SoC-Realtek-RTL8196E](./3-Main-SoC-Realtek-RTL8196E/README.md) | Linux system: bootloader, kernel, rootfs, userdata |

### Scripts

**Install, backup & flash** (repository root):

| Script | Description |
|--------|-------------|
| [`flash_install_rtl8196e.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/flash_install_rtl8196e.sh) | **Install custom firmware** — first flash (no arg, bootloader mode) or upgrade (`LINUX_IP`, saves config). `-y` for unattended upgrade (>= v2.0.0) |
| [`build_fullflash.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/build_fullflash.sh) | Build a complete 16 MiB flash image from all 4 partitions |
| [`backup_gateway.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/backup_gateway.sh) | Back up the full flash — auto-detects gateway state (SSH or bootloader) |
| [`restore_gateway.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/restore_gateway.sh) | Restore a fullflash.bin backup — guides through TFTP + FLW |
| [`flash_efr32.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/flash_efr32.sh) | Flash the Zigbee/Thread radio over SSH (OTA via universal-silabs-flasher) |

**Per-component build & flash** (in `3-Main-SoC-Realtek-RTL8196E/`):

| Script | Description |
|--------|-------------|
| [`31-Bootloader/build_bootloader.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/31-Bootloader/build_bootloader.sh) | Build the RTL8196E bootloader |
| [`31-Bootloader/flash_bootloader.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/31-Bootloader/flash_bootloader.sh) | Flash bootloader only — gateway must be in bootloader mode |
| [`32-Kernel/build_kernel.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/32-Kernel/build_kernel.sh) | Build the Linux kernel |
| [`32-Kernel/flash_kernel.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/32-Kernel/flash_kernel.sh) | Flash kernel only — gateway must be in bootloader mode |
| [`33-Rootfs/build_rootfs.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/33-Rootfs/build_rootfs.sh) | Build the root filesystem |
| [`33-Rootfs/flash_rootfs.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/33-Rootfs/flash_rootfs.sh) | Flash rootfs only — gateway must be in bootloader mode |
| [`34-Userdata/build_userdata.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/34-Userdata/build_userdata.sh) | Build the JFFS2 userdata partition |
| [`34-Userdata/flash_userdata.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/34-Userdata/flash_userdata.sh) | Flash userdata only — gateway must be in bootloader mode |
| [`flash_remote.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/flash_remote.sh) | SSH into running gateway, boothold, then flash one partition (no serial needed). For userdata, preserves user config (network, password, SSH keys, etc.) |

> **`flash_remote.sh` vs individual `flash_*.sh`**: The individual scripts require the gateway
> to already be in bootloader mode. `flash_remote.sh` automates the full cycle: SSH → boothold
> → wait for bootloader → flash. Use `flash_remote.sh` during development for one-command
> partition updates; use the individual scripts when you are already at the `<RealTek>` prompt.

**Backup utilities** (in `30-Backup-Restore/`):

| Script | Description |
|--------|-------------|
| [`split_flash.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/30-Backup-Restore/split_flash.sh) | Split a 16 MB full flash into individual partition files |
| [`restore_mtd_via_ssh.sh`](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/30-Backup-Restore/scripts/restore_mtd_via_ssh.sh) | Restore partitions via SSH (original Tuya firmware only) |

## Building from Source

Pre-built images are included in the repository. If you want to customize:

**Native (Ubuntu 22.04 / WSL2):**

```bash
cd 1-Build-Environment && sudo ./install_deps.sh
```

**Docker (any OS):**

```bash
cd 1-Build-Environment && docker build -t lidl-gateway-builder .
docker run -it --rm -v $(pwd)/..:/workspace lidl-gateway-builder
```

Then build and flash:

```bash
# Build the Linux system
cd 3-Main-SoC-Realtek-RTL8196E/32-Kernel && ./build_kernel.sh
cd ../33-Rootfs && ./build_rootfs.sh
cd ../.. && ./flash_install_rtl8196e.sh <LINUX_IP>

# Build and flash a Zigbee firmware
cd 2-Zigbee-Radio-Silabs-EFR32/24-NCP-UART-HW && ./build_ncp.sh 460800
cd ../.. && ./flash_efr32.sh -y -g <LINUX_IP> ncp 460800
```

See [1-Build-Environment](./1-Build-Environment/README.md) for details.

______________________________________________________________________

## Troubleshooting

### EFR32 Zigbee/Thread radio unresponsive

If you are seeing repeated `HandleRcpTimeout()` / `Failed to communicate
with RCP` errors in `otbr-agent` logs after ~1h of operation at 460800
baud (issue
[#89](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/issues/89))
on **v3.1.x or v3.2.x**, upgrade to **v3.3.0+** — the root cause was that
`S70otbr` did not enable hardware UART flow control on the spinel link;
without it, the RX FIFO could overrun under bursty Spinel traffic. v3.3.0
adds `&uart-flow-control=true` to the spinel radio URL (plus kernel-side
defensive layers), eliminating the failure mode.

If the radio chip is stuck (Z2M / ZHA / OTBR can no longer talk to it, but
Linux / SSH on the gateway are fine), three escalating recovery surfaces are
available — try them in order:

1. **Long-press the front-panel button (5 seconds)** — the gateway's case
   button (the one Tuya used for app pairing) is wired up by `S40button` to
   pulse the EFR32's `nRST` line. The status LED blinks during the hold
   for visual feedback. Releases the EFR32 from any stuck state and
   restarts the radio daemon. **No SSH or network needed.**
2. **`ssh root@<gw> recover_efr32`** — same effect, scriptable, useful
   when the network works but the radio doesn't.
3. **`ssh root@<gw> reboot`** — full SoC reboot. Resets the EFR32 too as
   a side-effect (the SoC's pin-mux register defaults briefly assert the
   radio's `nRST`). Use this if recovery surfaces 1 and 2 don't bring the
   radio back, or if you need a Linux-side reset anyway.

If none of these work, the radio firmware itself is unrecoverable from
software (e.g. user flashed a non-Zigbee firmware that doesn't speak any
known protocol). Power-cycle the gateway, then reflash via
`flash_efr32.sh`. The full design rationale, why this is the architecture,
and what would need to change for a more aggressive recovery story are
documented in
[2-Zigbee-Radio-Silabs-EFR32/POST-MORTEM-bootloader-recovery.md](./2-Zigbee-Radio-Silabs-EFR32/POST-MORTEM-bootloader-recovery.md).

______________________________________________________________________

## Credits

This project builds upon the initial research by [Paul Banks](https://paulbanks.org/projects/lidl-zigbee/).
No need to crack the root password — access to the Realtek bootloader prompt
(serial console, press ESC on power-on) is all you need to flash the gateway.

## License

MIT License — See [LICENSE](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/blob/main/LICENSE) for details.
