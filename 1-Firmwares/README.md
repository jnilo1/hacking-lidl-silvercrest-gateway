# Wireless Firmware Management

## Introduction

This section documents the management, backup, and customization of
wireless firmware running on the **EFR32MG1B** chip embedded in the Lidl
Silvercrest Gateway.

The objective is to safely replace the stock firmware with custom builds to
support **Zigbee2MQTT (Z2M)**, **ZHA**, or **Matter over Thread** via an
RCP interface.

______________________________________________________________________

## Repository Structure

```text
1-Firmwares/
├── 10-EZSP-Reference/            # EmberZNet and EZSP reference
├── 11-Simplicity-Studio/         # Installation and usage of Simplicity Studio V5
├── 12-Backup-Restore-Flash/      # Methods to back up and restore Zigbee firmware (HW/SWD or SW tools)
├── 13-Bootloader-UART-Xmodem/    # Flashing via UART using the Realtek bootloader
├── 14-NCP-UART-HW/               # NCP mode firmware (EZSP protocol)
├── 15-RCP-UART-HW/               # RCP mode firmware (OpenThread + CPC)
└── README.md                     # This file
```

______________________________________________________________________

## Goals

- 🔐 **Ensure firmware safety**: Learn to back up the original factory
  firmware before attempting any changes.
- ⚙️ **Upgrade firmware**: Safely flash and switch between NCP and RCP
  firmware versions.
- 🧰 **Enable development**: Set up Simplicity Studio for customizing and
  building your own firmware.

______________________________________________________________________

## Key Topics Covered

### 🔁 Backup & Restore

- Why and how to back up the Zigbee firmware (recommended before any
  flashing)
- Use of hardware tools (e.g., SWD, ESP8266) and software-based methods

### 🛠 Simplicity Studio Setup

- Installation of **Simplicity Studio V5**
- Required SDKs, compilers and steps to open, modify and build Silabs
  projects

### 🔧 Firmware Compilation

- How to compile NCP firmware (EZSP/UART) for Zigbee2MQTT or ZHA
- How to compile RCP firmware for multiprotocol Matter/Thread + Zigbee
- Where to find **precompiled binaries** for convenience

______________________________________________________________________

This section is essential for those who want to take full control of the
Zigbee module and adapt the gateway to their own smart home ecosystem.
