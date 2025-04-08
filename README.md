# Hacking the Lidl Silvercrest Gateway

## Overview

The **Lidl Silvercrest Gateway** is a cheap and compact device originally
designed to control Tuya/Zigbee smart devices via the Silvercrest
ecosystem. Thanks to the pioneering work of
[Paul Banks](https://paulbanks.org/projects/lidl-zigbee/#overview), this
gateway can be repurposed into a fully open and customizable Zigbee
coordinator.

This repository expands on that work and documents how to:

- Analyze the gateway's **hardware** and **firmware**,
- Replace the original Tuya Zigbee stack with custom firmwares (NCP or
  RCP),
- Understand and modify the **embedded Linux system** based on the Realtek
  SDK,
- Interface the gateway with **open-source home automation platforms** such
  as Home Assistant or Zigbee2MQTT.

______________________________________________________________________

## Repository Structure

```text
.
├── 0-Hardware/                      # Gateway hardware description and pinout
│   └── README.md
│
├── 1-Firmwares/                    # Zigbee firmware build & flash tools
│   ├── 10-EZSP-Reference/            # Introduction to EZSP & EmberZnet
│   ├── 11-Simplicity-Studio/         # Building Zigbee firmwares with Simplicity Studio
│   ├── 12-Backup-Restore-Flash/      # Flash dump and restore methods (SWD, ESP, etc.)
│   ├── 13-Bootloader-UART-Xmodem/    # Using the Silabs/Gecko bootloader over UART
│   ├── 14-NCP-UART-HW/               # Firmware: EZSP NCP (for Zigbee2MQTT, ZHA)
│   └── 15-RCP-UART-HW/               # Firmware: multiprotocol RCP
│
├── 2-Softwares/                    # Embedded Linux software
│   ├── 21-Linux-Kernel/              # Realtek SDK Linux kernel analysis
│   ├── 22-System-Tools/              # Precompiled binaries and userland tools
│   └── 23-RCP-Daemons/               # CPC / Zigbeed daemons for RCP firmware
│
├── README.md                       # This file
└── .github/
    └── ISSUE_TEMPLATE/              # GitHub issue templates
        ├── bug_report.md
        └── feature_request.md
```

______________________________________________________________________

## Goals

This documentation is intended for tinkerers, hackers, and home automation
enthusiasts who want to:

- Repurpose the Lidl Silvercrest Gateway as a **custom Zigbee
  coordinator**,
- Understand the **hardware and embedded software** used by the device,
- Modify or replace the **Zigbee stack** and **embedded Linux firmware**,
- **Integrate** the modified gateway into DIY home automation environments
  (Home Assistant, Zigbee2MQTT, etc.).

______________________________________________________________________

## Community & Discussions

Got questions, stuck on something, or want to share your progress?\
👉 Head over to the [**Discussions**](../../discussions) tab!

Whether you're reverse engineering hardware, building Zigbee firmwares, or
tweaking the Realtek SDK, you're welcome to:

- Ask for help or get unblocked,
- Share your work-in-progress or discoveries,
- Suggest improvements or ideas for the project,
- Help others with their setups or flash attempts.

We’re building this together — jump in!

______________________________________________________________________

## Credits

This project builds upon the initial research by
[Paul Banks](https://paulbanks.org/projects/lidl-zigbee/), whose work made
this gateway hackable and to the unvaluable resources found around the Web.

______________________________________________________________________

## License

This project is open-source. See the [LICENSE](./LICENSE) file for details.

## 📚 Table of Contents

- [0-Hardware](./0-Hardware/README.md): Gateway hardware description and
  pinout
- [1-Firmwares](./1-Firmwares)
  - [10-EZSP-Reference](./1-Firmwares/10-EZSP-Reference/README.md):
    Introduction to EZSP & EmberZnet
  - [11-Simplicity-Studio](./1-Firmwares/11-Simplicity-Studio/README.md):
    Building Zigbee firmwares
  - [12-Backup-Restore-Flash](./1-Firmwares/12-Backup-Restore-Flash/README.md):
    Backup and restore methods
  - [13-Bootloader-UART-Xmodem](./1-Firmwares/13-Bootloader-UART-Xmodem/README.md):
    Bootloader via UART XMODEM
  - [14-NCP-UART-HW](./1-Firmwares/14-NCP-UART-HW/README.md): EZSP-based
    NCP firmware
  - [15-RCP-UART-HW](./1-Firmwares/15-RCP-UART-HW/README.md): Multiprotocol
    RCP firmware
- [2-Softwares](./2-Softwares)
  - [21-Linux-Kernel](./2-Softwares/21-Linux-Kernel/README.md): Kernel
    analysis and toolchain issues
  - [22-System-Tools](./2-Softwares/22-System-Tools/README.md): Precompiled
    tools and toolchain (WIP)
  - [23-RCP-Daemons](./2-Softwares/23-RCP-Daemons/README.md): CPC and
    Zigbeed daemons
- [.github/ISSUE_TEMPLATE](./.github/ISSUE_TEMPLATE): Issue and feature
  request templates
