# Changelog — Zigbee Radio / Silabs EFR32 (Lidl Silvercrest Gateway)

All notable changes to the EFR32 firmware and tooling are documented here.

---

## [1.2.1] - 2026-03-03

### 26-OT-RCP
- Docker Compose stack for Thread/Matter: OTBR + Matter Server + Home Assistant
- Docker Compose stack for Zigbee: Zigbee2MQTT with zigbee-on-host (`zoh`) adapter
- Tested Matter commissioning via chip-tool over BLE (IKEA TIMMERFLOTTE sensor)
- Documented chip-tool workflow: Thread dataset, BLE pairing, attestation bypass
- Removed erroneous 460800 baud memo (actual root cause: PCB signal integrity)
- README updated with dual-mode architecture diagrams and quick start

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

### 23-Bootloader-UART-Xmodem
- Aligned with Simplicity Studio standard project structure

### Build environment
- Updated Silabs toolchain: slc-cli 5.11, GSDK 4.5.0
- Silabs tools installed in project directory (like x-tools)

### Community contributions
- PR #55 (stream2me): static-linked serialgateway binary

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
