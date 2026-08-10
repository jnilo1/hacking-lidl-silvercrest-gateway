# Experimental RCP with Bluetooth HCI

This directory contains a **research prototype**, not a supported radio mode.
It builds Silicon Labs' `rcp-uart-802154-blehci` sample: an 802.15.4 RCP plus
a Bluetooth controller exposed as HCI over CPC endpoint 14.

The intended host chain is:

```text
EFR32 → cpcd → cpc-hci-bridge → hciattach → BlueZ
```

Zigbee or Thread and Bluetooth then share one time-sliced 2.4 GHz radio and one
CPC UART link.

## Status and limitations

- Nobody has validated this firmware on real gateway hardware.
- No pre-built image is shipped.
- It does not fit on the Lidl EFR32MG1B (256 KiB flash / 31 KiB RAM).
- It builds for the Sengled G4's EFR32MG13 (512 KiB / 64 KiB), but fitting in
  memory does not prove that the complete radio and host chain works.
- The Sengled G4 has no RTS/CTS wiring. CPC cannot use XON/XOFF, so Bluetooth
  traffic can overrun the RTL8196E UART RX FIFO.
- Bluetooth scanning consumes airtime otherwise available to Zigbee or Thread.
- Silicon Labs marks the HCI-over-CPC component as experimental.

Use this only if you are prepared to recover the EFR32 over SWD and debug the
host-side CPC/BlueZ integration.

## Build for Sengled

From `25-RCP-UART-HW/`:

```bash
BOARD=sengled-e39-g8c ./experimental/rcp-ble-hci/build.sh
BOARD=sengled-e39-g8c ./experimental/rcp-ble-hci/build.sh 230400
```

The default is deliberately 115200. The output is written to the normal RCP
`firmware/` directory, but remains untracked and is not selected automatically
by `flash_efr32.sh`.

## Flash the explicitly selected image

From the repository root, using the exact filename printed by the build:

```bash
BOARD=sengled-e39-g8c ./flash_efr32.sh \
  -g <gateway-ip> \
  --firmware-file 2-Zigbee-Radio-Silabs-EFR32/25-RCP-UART-HW/firmware/<blehci-image>.gbl \
  rcp 115200
```

The final `rcp 115200` arguments are required: they tell the flasher which
runtime configuration to write to `/userdata/etc/radio.conf`. Match the baud to
the image you built.

Before testing Bluetooth traffic, install and run the
[UART overrun monitor](../../../../3-Main-SoC-Realtek-RTL8196E/32-Kernel/tools/README.md)
on the gateway.
