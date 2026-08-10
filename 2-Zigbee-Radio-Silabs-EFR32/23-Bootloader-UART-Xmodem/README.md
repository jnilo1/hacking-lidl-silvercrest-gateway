# Bootloader-UART-Xmodem

UART XMODEM bootloader for the EFR32 radio — EFR32MG1B232F256GM48 on the Lidl Silvercrest Gateway, EFR32MG13P732F512IM32 on the Sengled Smart Hub G4.

This bootloader enables firmware updates via UART using the XMODEM-CRC protocol, without requiring SWD/JTAG access.

> **Multi-board:** this bootloader also builds for other RTL8196E hubs via
> `BOARD=` (default `lidl`, #143); e.g. `BOARD=sengled-e39-g8c ./build_bootloader.sh`
> for the Sengled Smart Hub G4 (MG13 target — **validated on real hardware by
> @hlyi**, #148; prebuilt committed). Non-lidl artefacts carry a `-<board>`
> filename suffix, and `flash_efr32.sh` resolves them from the same `BOARD=`
> selector. Mind the warning below: a bad bootloader flash needs SWD to
> recover, and on the MG13 the layout differs — see the memory-map note.
> Details in [`../boards/README.md`](../boards/README.md).

## Quick Start

```bash
# Build the bootloader
./build_bootloader.sh

# Flash via J-Link (combined = first stage + main stage)
commander flash firmware/bootloader-uart-xmodem-2.4.2-combined.s37 --device EFR32MG1B232F256GM48
```

## Prerequisites

- **slc** (Silicon Labs CLI) in PATH
- **arm-none-eabi-gcc** in PATH
- **commander** in PATH
- **GECKO_SDK** environment variable set

Or use Docker from the `2-Zigbee-Radio-Silabs-EFR32` directory:

```bash
docker run -it --rm -v $(pwd)/..:/workspace rtl8196e-gateway-builder \
    /workspace/2-Zigbee-Radio-Silabs-EFR32/23-Bootloader-UART-Xmodem/build_bootloader.sh
```

## Build Process

```
1. Copy slcp + slpb from patches/
        ↓
2. slc generate
        ↓
3. Copy config headers from patches/
        ↓
4. make -Oz
        ↓
5. Post-build (commander convert/gbl create)
```

## Hardware Configuration

### UART Pinout (USART0)

| Signal | Port | Pin | Description |
|--------|------|-----|-------------|
| TX | PA0 | 0 | Transmit to RTL8196E |
| RX | PA1 | 1 | Receive from RTL8196E |

No hardware flow control (standard Simplicity Studio configuration).

### GPIO activation — hardware entry into the bootloader (per board, #148)

The bootloader normally has exactly one way in: the running application asks
for it (a system-request reset carrying a bootloader reset reason — that is
what `universal-silabs-flasher` triggers over EZSP/CPC/Spinel). A plain `nRST`
pulse is *not* one of those, so if the application is wedged, or speaks none of
those protocols (the Z3 Router), there is nothing to ask.

A board that routes an EFR32 pin to a SoC GPIO can escape that: hold the pin
through a reset and the bootloader, if it samples it at startup, comes up in
the menu regardless of what the application is doing. That check exists only
when the project includes `bootloader_gpio_activation`, so `build_bootloader.sh`
adds it — and configures the pin, active LOW — for any board whose `board.env`
sets `BOARD_BTL_ACTIVATION_PIN="<port-letter> <pin>"`.

| Board | Pin | Host side |
|---|---|---|
| `lidl` | — | No such wire exists on the PCB (see `../POST-MORTEM-bootloader-recovery.md`); the component is left out and the binary is unchanged |
| `sengled-e39-g8c` | **PB15** | RTL8196E GPIO 13, `blmode-gpios` in the devicetree; pulse it with the bridge's `blmode_pulse` |

Validated on hardware by @hlyi (#148): with GPIO activation compiled in,
`echo 1 > blmode_pulse` drops a running G4 into the Gecko Bootloader, whatever
the application is doing. `flash_efr32.sh` uses this automatically on boards
that have the pin — it enters the bootloader directly, with no probe sweep and
no cooperation from the running firmware.

### The version field is load-bearing — bump it or the upgrade is a no-op

**A bootloader `.gbl` whose version is not strictly greater than the running one
is declined in silence, after the application has already been erased.** This is
the single most surprising thing about the Gecko bootloader, and it cost us a
round trip on the G4 (#148).

The mechanism, from `btl_comm_xmodem_common.c`:

```c
if (imageProps->contents & BTL_IMAGE_CONTENT_BOOTLOADER) {
    if (imageProps->bootloaderVersion > bootload_getBootloaderVersion()) {
        bootload_commitBootloaderUpgrade(BTL_UPGRADE_LOCATION, ...);
    }
}   // no else branch
```

There is no error path. And the check runs *after* the damage: the incoming
image is staged at `BTL_UPGRADE_LOCATION` (`0x8000` on Series 1), which lives
inside application space, so `bootload_bootloaderCallback()` erases the first
application page as the first bytes arrive. A same-version reflash therefore
reports success, wipes the application, and leaves the old bootloader in place.

The version word is `major<<24 | minor<<16 | customer`. `2.4` is Silicon Labs'
own version; the third number is the **customer field**, an SDK config option
left to the integrator. It is set per board:

| Board | Version | Why |
|---|---|---|
| `lidl` | **2.4.2** | Unchanged binary — bumping it would break byte-for-byte reproducibility for nothing |
| `sengled-e39-g8c` | **2.4.3** | Its binary changed (GPIO activation), and it must be able to supersede the 2.4.2 already in the field |

**So: bump `BOARD_BTL_CUSTOMER` in that board's `board.env` whenever you change
that board's bootloader binary.** Otherwise the new image can never reach a unit
already running the old one over UART, and every attempt costs the user their
radio firmware. `flash_efr32.sh` now refuses such a flash before uploading
anything, and verifies the installed version afterwards by reading it back off
the chip.

## Output Files

After running `./build_bootloader.sh`, files are in `firmware/`:

| File | Description |
|------|-------------|
| `bootloader-uart-xmodem-X.Y.Z.s37` | Main stage bootloader |
| `bootloader-uart-xmodem-X.Y.Z-crc.s37` | Main stage with CRC |
| `bootloader-uart-xmodem-X.Y.Z-combined.s37` | First stage + Main stage (for J-Link) |
| `bootloader-uart-xmodem-X.Y.Z.gbl` | GBL image (for XMODEM/UART upload) |
| `first_stage.s37` | First stage only |

## Using the Bootloader

Once flashed, the bootloader responds to serial commands at 115200 baud:

| Command | Action |
|---------|--------|
| `1` | Start XMODEM transfer (upload new firmware) |
| `2` | Start application |

The bootloader decides where to go in `enterBootloader()` (`btl_main.c`). There
are exactly three ways in:

- **The running application asks for it** — a system-request reset carrying a
  bootloader reset reason. This is what `universal-silabs-flasher` triggers over
  EZSP / CPC / Spinel, and it is what `flash_efr32.sh` relies on by default. Note
  that an `nRST` *pin* pulse is **not** one of these: a pin reset is not a system
  request, so `nrst_pulse` reboots the radio into its application.
- **The GPIO-activation pin is held through a reset** — hardware entry, needs no
  cooperation from the application at all. Only on boards that wire the pin and
  whose bootloader was built with the component; see the section above.
- **There is no valid application** to hand over to.

______________________________________________________________________

## Understanding the 2-Stage Bootloader Architecture (Series 1)

EFR32MG1B (Gecko Series 1) devices use a **two-stage bootloader system**:

### Stage 1 – First-stage bootloader (BSL)

- Resides in main flash memory starting at address **0x0000**
- Minimal: verifies and launches Stage 2
- Cannot be updated via UART or OTA
- Can only be overwritten using **SWD and a debugger**

### Stage 2 – Main bootloader

- Resides in main flash memory starting at address **0x0800**
- Contains UART XMODEM functionality
- Can be updated in the field via `.gbl` packages

### Application

- Resides in flash memory starting at address **0x4000**
- Updated via XMODEM using `.gbl` files

### Memory Map

```
0x00000000 ┌─────────────────────────┐
           │  First Stage (2 KB)     │ ← Can only be updated via SWD
0x00000800 ├─────────────────────────┤
           │  Main Bootloader (14 KB)│ ← UART XMODEM logic
0x00004000 ├─────────────────────────┤
           │  Application            │ ← NCP-UART-HW or Router firmware
           │  (~200 KB)              │
0x0003E000 ├─────────────────────────┤
           │  NVM3 Storage (36 KB)   │ ← Network keys, tokens
0x00040000 └─────────────────────────┘
```

> **MG13 boards (e.g. the Sengled G4) use a different layout**: xG13 chips
> have a **dedicated 16 KB bootloader flash region at `0x0FE10000`** (first
> stage at `0x0FE10000`, main bootloader at `0x0FE10800`), and the
> application starts at `0x00000000` in main flash. The `BOARD=` build
> places both stages there automatically — the map above is the MG1B
> (bootloader-in-main-flash) case.

______________________________________________________________________

## Flashing the Bootloader

> **Warning**: Bootloader firmware flashing always carries some risk. If the process is interrupted or fails, the device may become unresponsive and require a J-Link/SWD debugger to recover. **Having a debugger available is strongly recommended** before attempting any bootloader update.

### Option 1: Flash via J-Link/SWD (Recommended)

The safest method. Flash the combined image (first stage + main stage):

```bash
commander flash firmware/bootloader-uart-xmodem-2.4.2-combined.s37 --device EFR32MG1B232F256GM48
```

Or flash stages separately:

```bash
# First stage (only if missing/corrupted)
commander flash firmware/first_stage.s37 --device EFR32MG1B232F256GM48

# Main stage with CRC
commander flash firmware/bootloader-uart-xmodem-2.4.2-crc.s37 --device EFR32MG1B232F256GM48
```

### Option 2: Flash via `flash_efr32.sh` (Remote, Stage 2 only)

You can update the **Stage 2 bootloader** remotely if you already have a working bootloader installed.

> **Note**: This only updates Stage 2. Stage 1 cannot be updated via UART.

From the repository root:

```bash
./flash_efr32.sh -y bootloader                    # gateway from gateway.env
./flash_efr32.sh -y -g 10.0.0.5 bootloader        # custom gateway IP
./flash_efr32.sh --help                           # full CLI reference
```

The script handles switching the in-kernel UART bridge to flash mode,
flashing the new Stage 2, and tolerates the expected `NoFirmwareError`
(the application slot is empty after a bootloader update). After a
successful bootloader flash, the chip sits in the Gecko Bootloader
indefinitely — chain a second invocation to install the application
firmware:

```bash
./flash_efr32.sh -y ncp                           # or rcp, otrcp, router
```

The script auto-detects the chip already in the bootloader (since v3.1)
and skips the running-app probe, going straight to the upload.

### Option 3: First install over a factory bootloader that has no menu (Sengled G4)

`flash_efr32.sh` drives `universal-silabs-flasher`, which speaks the Gecko
bootloader **menu** (`1` = upload, `2` = run). Sengled's factory bootloader has
no menu: once entered it starts an XMODEM receive straight away and emits `C`
once a second, so the flasher has nothing to talk to and the script cannot do
the **first** install on a stock G4. Send the image with an XMODEM client
instead. That is a one-time step — ours has a menu, so from then on
`flash_efr32.sh` handles applications and its own future updates.

This is @hlyi's procedure, validated on a factory G4 (#148). It assumes the
RTL8196E side already runs our firmware — the in-kernel UART bridge is what
carries the transfer — and `lrzsz` on the host.

```bash
# On the gateway. Stop whatever is holding the bridge port first (it accepts a
# single client), then park the bridge where the bootloader lives.
SYSFS=/sys/module/rtl8196e_uart_bridge/parameters
echo 115200 > $SYSFS/baud
echo 0 > $SYSFS/flow_control
echo 1 > $SYSFS/blmode_pulse    # hardware entry — the stock bootloader samples this pin

# On the host, from this directory's firmware/
sz -X -o --tcp-client 192.168.1.88:8888 bootloader-uart-xmodem-2.4.3-sengled-e39-g8c.gbl
```

Both bridge settings are load-bearing, and `flash_efr32.sh` sets exactly the
same pair before every Xmodem transfer. The bootloader's Xmodem path runs at
115200 with no flow control at all; and since the G4 wires no RTS/CTS, the
bridge defaults to `sw` on that board, where it strips bare `0x11`/`0x13` out of
the radio's byte stream and pauses the host→radio direction on XOFF. Neither
belongs in a raw XMODEM transfer.

Installing a bootloader erases the application — the incoming image is staged
inside application space, as described above — so the radio has no firmware
until you give it one. Chain the application flash straight after:

```bash
BOARD=sengled-e39-g8c ./flash_efr32.sh -y ncp    # or rcp, otrcp, router
```

______________________________________________________________________

## Creating Combined Images (Bootloader + Application)

To update both bootloader (stage 2) and application in one UART transfer:

```bash
commander gbl create upgrade.gbl \
    --app ncp-uart-hw.s37 \
    --bootloader bootloader-uart-xmodem-2.4.2-crc.s37
```

> **Note**: This only updates the main bootloader (stage 2), not the first stage. First stage always requires SWD access.

______________________________________________________________________

## patches/ Directory

| File | Purpose |
|------|---------|
| `bootloader-uart-xmodem.slcp` | Project config with components |
| `bootloader-uart-xmodem.slpb` | Post-build config (generates .s37, -crc.s37, -combined.s37, .gbl) |
| `btl_uart_driver_cfg.h` | UART pin configuration (USART0 PA0/PA1, no flow control) |
