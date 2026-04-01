# Changelog — Zigbee Radio / Silabs EFR32 (Lidl Silvercrest Gateway)

All notable changes to the EFR32 firmware and tooling are documented here.

---

## [2.1.3] - 2026-04-01

### 26-OT-RCP (OTBR on gateway)
- **IPv6 mDNS fix (`accept_ra=2`)**: `S70otbr` enabled IPv6 forwarding
  which silently disabled Router Advertisement processing. The gateway
  never acquired a GUA via SLAAC, so mDNS only announced the IPv4
  address. Fixed: set `accept_ra=2` on eth0 after enabling forwarding. (#77)
- **Channel Manager enabled**: `otbr-agent` now built with
  `OT_CHANNEL_MANAGER` and `OT_CHANNEL_MONITOR` (+14 KB). Enables
  `ot-ctl channel manager` for graceful channel changes across the
  Thread mesh. Channel change also works from the HA Thread UI.
- **HA REST API compatibility**: `build_otbr.sh` patches ot-br-posix
  REST API JSON keys from camelCase back to PascalCase at build time.
  Fixes "Failed to call OTBR API" in Home Assistant's Thread integration
  (`python-otbr-api` < 2.9.0 expects PascalCase).

---

## [2.1.1] - 2026-03-22

### flash_efr32.sh
- **Auto-reinstall USF on patch change**: `flash_efr32.sh` now stores the
  md5 hash of the applied `silabs-flasher-probe-methods.patch` in the venv.
  On next launch, if the patch has changed, the venv is removed and USF is
  reinstalled with the new patch automatically.

---

## [2.1.0] - 2026-03-21

### 24-NCP-UART-HW
- **Docker Compose stack**: new `docker/` directory with Mosquitto + Zigbee2MQTT
  (ember adapter) + Home Assistant. Self-contained for NCP users.

### flash_efr32.sh
- **OTBR support**: stops otbr-agent, cpcd, zigbeed before starting serialgateway
  in flash mode — no longer requires manual daemon management.
- **Remove 460800 baud**: gateway UART unreliable at 460800 (see 25-RCP-UART-HW).
  Removed from baud rate recovery scan and USF probe patch. Saves ~30s on flash.

### silabs-flasher-probe-methods.patch
- Drop all 460800 entries (EZSP, SPINEL, CPC). Add EZSP@230400, SPINEL@115200,
  SPINEL@230400.

### 22-Backup-Flash-Restore
- MEMO-universal-silabs-flasher.md: document 460800 removal rationale.

---

## [2.0.0] - 2026-03-11

### 26-OT-RCP
- **3 use cases, 1 firmware:** ZoH (Zigbee on Host), OTBR on host (Docker),
  OTBR on gateway (native) — all use the same OT-RCP firmware
- 3 Docker Compose stacks: `docker-compose-zoh.yml`, `docker-compose-otbr-host.yml`,
  `docker-compose-otbr-gateway.yml`
- Radio mode switching support in Docker compose files
- Thread network formation guide (use case 3: OTBR on gateway)
- Tested devices: IKEA TIMMERFLOTTE, BILRESA, MYGGSPRAY (all Matter/Thread)
- README restructured around the 3 use cases with architecture diagrams

### 22-Backup-Flash-Restore
- Technical memo: [MEMO-universal-silabs-flasher.md](22-Backup-Flash-Restore/MEMO-universal-silabs-flasher.md)
  — how USF works over TCP, baud rate mismatch problem, recovery mechanism

### flash_efr32.sh
- **Auto-recovery from non-standard baud rates:** when firmware runs at 230400
  or 460800 (e.g., after a custom build), the script scans baud rates, lets USF
  detect and enter the Gecko Bootloader, restarts serialgateway at 115200, and
  flashes. Tested with Spinel (OT-RCP) and EZSP (NCP).
- Patches USF probe methods at install time (`silabs-flasher-probe-methods.patch`)
  to add SPINEL@115200, SPINEL@230400, EZSP@230400
- SSH `-n` flag prevents stdin conflicts when piping firmware selection
- Default gateway IP: 192.168.1.88 (replaces placeholder throughout docs)

### Documentation
- IP placeholders replaced with default 192.168.1.88 across all Docker and Z2M configs

---

## [1.2.1] - 2026-03-05

### 26-OT-RCP
- Docker Compose stack for Thread/Matter: OTBR + Matter Server + Home Assistant
- Docker Compose stack for Zigbee: Zigbee2MQTT with zigbee-on-host (`zoh`) adapter
- Matter commissioning via HA Companion App (replaces chip-tool)
- Documented full setup: IPv6 forwarding, OTBR integration, Thread credentials sync
- Thread/Matter primer for Zigbee users (`THREAD-MATTER-PRIMER.md`)
- Tested: IKEA TIMMERFLOTTE (22.8 °C, 54.69 %, battery 100 %)
- Removed erroneous 460800 baud memo (actual root cause: PCB signal integrity)

### Build environment
- Unified build scripts: `build_rtl8196e.sh` (bootloader + kernel + rootfs + userdata), `build_efr32.sh` (all 5 firmware)
- Fixed Docker builds: GLIBC mismatch, lzma conflict, tool path detection
- All 9 build scripts work both in Docker and natively
- `nano` and `serialgateway` binaries now committed to skeleton for fresh clones

---

## [1.2.0] - 2026-03-02

### flash_efr32.sh (new — repository root)
- OTA flash script for EFR32 via SSH + universal-silabs-flasher
- Firmware selection menu: bootloader, NCP-UART-HW, RCP-UART-HW, OT-RCP, Z3-Router
- Bootloader flash automatically chains application firmware
- SSH retry (3 attempts, ConnectTimeout=10) for unreliable networks
- Progress bar visible for normal firmware flash
- Prerequisite checks: python3, python3-venv

### 23-Bootloader-UART-Xmodem
- Pre-built UART Xmodem firmware v2.4.2

### 26-OT-RCP
- Rebuilt firmware with PTI warning fix and Spinel bootloader reset support
- Removed orphan iostream config; clarified uartdrv vs iostream usage in README

### Documentation
- All firmware READMEs (23, 24, 25, 26, 27) updated: flash instructions now reference `flash_efr32.sh`
- Set `JAVA_TOOL_OPTIONS` in all build scripts so slc finds the trusted SDK

---

## [1.1.0] - 2026-01-25

### Build environment
- Updated Silabs toolchain: slc-cli 5.11, GSDK 4.5.0
- Silabs tools installed in project directory (like x-tools)

### 23-Bootloader-UART-Xmodem
- Aligned with Simplicity Studio standard project structure

### 25-RCP-UART-HW (new)
- Pre-built RCP firmware (CPC Protocol v5, GSDK 4.5.0)
- `rcp-stack` systemd service manager for cpcd + zigbeed chain
- zigbeed build scripts for EmberZNet 7.5.1 and 8.2.2
- Docker stack: cpcd-zigbeed + Zigbee2MQTT (amd64/arm64), based on Nerivec pre-built binaries
- cpcd/zigbeed build: fixed interactive prompts, dropped unused deps, added `--local`/`--deb` flags
- rcp-stack: fixed crash on empty env file, unbound variable on first run, symlink cleanup race

### 26-OT-RCP (new)
- OpenThread RCP firmware for zigbee-on-host (Z2M `zoh` adapter)
- Fixed flow control configuration for serialgateway compatibility

### 27-Router (new)
- Zigbee 3.0 Router SoC firmware with auto-join and network steering
- Mini-CLI: `bootloader reboot`, `network status/leave/steer`, `version`, `info`, `help`
- ZCL Basic Cluster: LidlRouter model, Silvercrest manufacturer, SW Build ID 1.0.0

---

## [1.0.0] - 2025-12-18

Initial release.

### 22-Backup-Flash-Restore
- Documentation for backing up and restoring the EFR32 via universal-silabs-flasher

### 23-Bootloader-UART-Xmodem
- Build script for Gecko UART Xmodem bootloader

### 24-NCP-UART-HW
- Pre-built NCP firmware v7.5.1 (EZSP v13, EmberZNet 7.5.1)
- Build script and patch system for customization
