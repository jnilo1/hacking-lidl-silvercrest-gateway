# Host Software

This directory provides documentation, configuration guidelines, and usage instructions for software components designed to run on the host system interacting with Lidl Silvercrest gateways equipped with Silicon Labs wireless module. These components facilitate communication and management functionalities for protocols such as Zigbee, Thread, and Matter, leveraging the gateway hardware equipped with Silicon Labs RCP firmware.

## Components Overview

### cpcd (Co-Processor Communication Daemon)

`cpcd` manages low-level communication with Silicon Labs Radio Co-Processor (RCP) firmware. It abstracts UART hardware interface, providing a standardized API for higher-layer applications managing Zigbee or Thread protocols. **Note:** It does not communicate with NCP firmware.

- [Detailed documentation](./cpcd/README.md)

### zigbeed (Zigbee Daemon)

`zigbeed` provides comprehensive Zigbee network management capabilities.in our setup `zigbeed` communicates indirectly via `cpcd` with the RCP firmware.

- [Detailed documentation](./zigbeed/README.md)

TO BE COMPLETED

### otbr (OpenThread Border Router)

`otbr` enables Thread networking by operating the OpenThread Border Router software on the host system. It provides IPv6 connectivity and network management for Thread devices, interfacing exclusively with RCP firmware through `cpcd`.

### chip-tool

`chip-tool` is a command-line utility provided by the Matter SDK. It is used primarily for commissioning, configuring, controlling, and testing devices compatible with the Matter protocol. It supports interaction over Thread, Wi-Fi, and Ethernet, allowing effective management of Matter-enabled networks and devices.

TO BE COMPLETED

## Directory Structure

Each software component resides in its dedicated subdirectory containing further detailed documentation, installation guides, usage examples, and troubleshooting information:

```
host_software
├── README.md
├── cpcd
│   └── README.md
├── zigbeed
│   └── README.md
```

Explore each subdirectory for more specific instructions and information tailored to your host environment.

