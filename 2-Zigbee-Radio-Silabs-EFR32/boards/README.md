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
└── sengled-e39-g8c/board.env contributed (placeholder pending hardware validation)
```

## Usage

```bash
./build_efr32.sh ncp                 # BOARD=lidl (default)
BOARD=sengled-e39-g8c ./build_efr32.sh ncp ot-rcp
BOARD=lidl ./24-NCP-UART-HW/build_ncp.sh   # per-firmware scripts honour BOARD too
```

Scope today: **NCP** and **OT-RCP** are board-parameterised. RCP, Router and the
Gecko bootloader remain lidl-only and are skipped for non-lidl boards until their
builds learn `BOARD=`.

## What `board.env` defines

| Variable | Meaning |
|---|---|
| `BOARD_NAME` | Human-readable board name (banners only) |
| `BOARD_TARGET_DEVICE` | Exact MCU OPN passed to `slc generate --with` |
| `BOARD_UART_PERIPHERAL` / `_NO` | USART instance feeding the RTL8196E (e.g. `USART0` / `0`) |
| `BOARD_UART_TX` / `_RX` | `"<port-letter> <pin> <location>"` for each data line |
| `BOARD_UART_FLOW` | `hw` (RTS/CTS handshake) or `none` (no hardware flow) |
| `BOARD_UART_CTS` / `_RTS` | `"<port-letter> <pin> <location>"`; ignored when flow ≠ `hw` |

The build copies the firmware's reference VCOM header from its `patches/` tree,
then `lib_uart_config.sh` substitutes the board's values **in place**, changing
only the value token on each `#define` and preserving the file's formatting.
For the `lidl` board the values equal the reference, so the header — and the
resulting firmware — is byte-for-byte unchanged. The same helper drives both
the iostream header (NCP) and the uartdrv header (OT-RCP); the SDK enum names
for flow control differ between them and are supplied by each build script.

## Porting contract

Mechanism and the `lidl` reference come from upstream; a contributor supplies a
`board.env` with **values validated on real hardware** and PRs it (the model
used for the bootloader `board.h` in #128). The OPN alone is not enough — the
USART/pin routing and the flow-control wiring are board facts that only a
hardware check confirms, and untested radio firmware is an SWD-rescue risk.
Validate the built NCP/OT-RCP `.gbl` over the device before trusting it.
