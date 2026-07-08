# EFR32 firmware — per-board configuration (`BOARD=`)

The EFR32 firmware builds are parameterised by board, mirroring the `BOARD=`
mechanism on the RTL8196E bootloader side (`3-Main-SoC-Realtek-RTL8196E/31-Bootloader/boards/`).
A board contributes one file — `boards/<board>/board.env` — and the build
scripts read it; no script edits are needed to add a board.

```
boards/
├── README.md                 this file
├── lib_uart_config.sh        shared helper: applies BOARD_UART_* to a VCOM header
├── lidl/board.env            reference board (default)
└── sengled-e39-g8c/board.env contributed, NCP validated on G4 hardware (#130)
```

## Usage

```bash
# Build
./build_efr32.sh ncp                 # BOARD=lidl (default)
BOARD=sengled-e39-g8c ./build_efr32.sh ncp ot-rcp router
BOARD=lidl ./24-NCP-UART-HW/build_ncp.sh   # per-firmware scripts honour BOARD too

# Flash (repo root) — same BOARD= selector
./flash_efr32.sh -y ncp                          # lidl (default), nothing to set
BOARD=sengled-e39-g8c ./flash_efr32.sh -y ncp    # flashes the -<board>-suffixed GBL
```

Non-lidl artefacts keep the historical flat `firmware/` directory but carry a
`-<board>` filename suffix (e.g. `ncp-uart-hw-7.5.1-115200-sengled-e39-g8c.gbl`),
so the lidl reference firmware is never shadowed. `flash_efr32.sh` resolves that
suffixed file for a non-lidl `BOARD=` and, because it always runs against a live
gateway, **guards on `/proc/device-tree/model`**: it refuses to push a board's
radio firmware to a different board (`lidl`→"Lidl", `sengled-e39-g8c`→"Sengled"),
which also catches forgetting `BOARD=` on a non-lidl box. `--force` overrides.

Scope today: **every firmware build is board-parameterised** (build *and*
flash) — NCP and OT-RCP since #130, the Z3 Router, the Gecko bootloader and
RCP since #143. Two flow-control specifics: the bootloader consumes only the
routing subset of `board.env` (`apply_uart_routing` — its flow control is a
separate numeric knob kept at 0 for every board, because the Xmodem path
always runs flow-off), and CPC (RCP) supports only RTS/CTS or none, so a
`BOARD_UART_FLOW=sw` board is built with flow control **none** — recorded as
such in `radio.conf` at flash time, so the in-kernel bridge (the chip's flow
partner; cpcd connects to it over TCP) arms to match.

## What `board.env` defines

| Variable | Meaning |
|---|---|
| `BOARD_NAME` | Human-readable board name (banners only) |
| `BOARD_TARGET_DEVICE` | Exact MCU OPN passed to `slc generate --with` |
| `BOARD_UART_PERIPHERAL` / `_NO` | USART instance feeding the RTL8196E (e.g. `USART0` / `0`) |
| `BOARD_UART_TX` / `_RX` | `"<port-letter> <pin> <location>"` for each data line |
| `BOARD_UART_FLOW` | `hw` (RTS/CTS handshake), `sw` (software XON/XOFF), or `none`. Also recorded by `flash_efr32.sh` into `radio.conf` as `FIRMWARE_FLOW_CTRL` on every app flash (#141), so the host side follows automatically. For OT-RCP it additionally selects the UART backend: `sw` → `iostream_usart` (complete XON/XOFF), `hw`/`none` → `uartdrv_usart` (DMA — #142) |
| `BOARD_UART_CTS` / `_RTS` | `"<port-letter> <pin> <location>"`; ignored when flow ≠ `hw` |

The build copies the firmware's reference VCOM header from its `patches/` tree,
then `lib_uart_config.sh` substitutes the board's values **in place**, changing
only the value token on each `#define` and preserving the file's formatting.
For the `lidl` board the values equal the reference, so the header — and the
resulting firmware — is byte-for-byte unchanged. The same helper drives both
the iostream header (NCP) and the uartdrv header (OT-RCP); the SDK enum names
for flow control differ between them and are supplied by each build script
(`hw`→`usartHwFlowControlCtsAndRts`/`uartdrvFlowControlHw`,
`sw`→`uartFlowControlSoftware`/`uartdrvFlowControlSw`,
`none`→the respective `…None`). Software flow is a first-class SDK option, not
a patch — the generated init code keys off the same `_FLOW_CONTROL_TYPE` token.

> **G4 status (validated, #130):** `BOARD=sengled-e39-g8c` builds NCP and OT-RCP
> end-to-end (MG13 target, software flow). The NCP `.slcp` pinned the lidl MCU as
> a device component, so the build re-points it at `BOARD_TARGET_DEVICE` before
> `slc generate` (otherwise two device families link → duplicate symbols); for
> lidl that is the same string, so its build is unchanged. The G4 wires the EFR32
> UART on the **same USART/pins as Lidl** (USART0, PA0/PA1), confirmed on hardware
> by @hlyi — so the firmware is electrically correct, not just structurally. The
> **NCP** image was flashed to a real G4 and validated end-to-end (Home Assistant
> talks to the radio); a prebuilt G4 NCP `.gbl` is committed. **OT-RCP** builds
> for the G4 but its Thread path hasn't been functionally tested there yet — build
> it yourself and validate over SWD before trusting it. The **Z3 Router** likewise
> builds for the G4 (MG13 target, software flow, #143) but has not been
> hardware-validated there yet — same caveat, and no prebuilt is committed.
> The **Gecko bootloader** also builds for the G4 (#143): correct xG13 first
> stage and placement in the MG13's dedicated bootloader region at `0x0FE10000`
> were verified against the SDK prebuilts, but it has **never run on a real
> G4** — and a bad bootloader flash is an SWD-only recovery. A G4 flashed via
> `flash_efr32.sh` already has a working bootloader; only replace it with a
> debugger attached. **RCP** builds for the G4 too (#143, flow clamped to
> none — CPC has no XON/XOFF; recorded as none in `radio.conf` so the bridge
> matches), also not hardware-validated.

## Porting contract

Mechanism and the `lidl` reference come from upstream; a contributor supplies a
`board.env` with **values validated on real hardware** and PRs it (the model
used for the bootloader `board.h` in #128). The OPN alone is not enough — the
USART/pin routing and the flow-control wiring are board facts that only a
hardware check confirms, and untested radio firmware is an SWD-rescue risk.
Validate the built NCP/OT-RCP `.gbl` over the device before trusting it.
