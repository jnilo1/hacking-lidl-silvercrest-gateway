# Per-board bootloader configuration

One directory per board, each containing a single `board.h`. Select the
board at build time:

```sh
BOARD=lidl ./build_bootloader.sh        # default
BOARD=<your-board> ./build_bootloader.sh
```

`lidl` is the in-tree reference: building it reproduces the committed
`boot.bin` bit-for-bit (`md5sum` must match — the bootloader build is
deterministic, see `../CLAUDE.md` if you are a maintainer, or just trust
the check below).

## What a board.h must define

| Macro | Meaning |
|---|---|
| `BOARD_DRAM_BANNER` | DRAM size string for the stage-2 banner (`"32MB"`, `"64MB"`) |
| `BOARD_DRAM_TOP_KSEG1` | KSEG1 address one past the last DRAM byte (`0xA2000000` for 32 MiB, `0xA4000000` for 64 MiB) |
| `BOARD_DDR_REG_1004` | DDR controller value written to `0xB8001004` by stage-1 |
| `BOARD_DDR_REG_1008` | DDR controller value written to `0xB8001008` by stage-1 |

The DDR values are written by `btcode/start.S` **before any DRAM
access** and nothing overwrites them later — they are the entire DRAM
configuration. They are named by register address because the historical
macro names were swapped vs the usual DCR/DTR convention; always go by
the address.

`BOARD_DRAM_TOP_KSEG1` also places the **boothold flag page** at
`top - 0x2000` (the page the `boothold` tool and the watchdog panic
record use from Linux). It must match the `boothold` reserved-memory
node of the board's kernel DTS — the kernel/userspace side resolves the
page from the device tree at runtime, the bootloader from this constant
at build time. If they disagree, `boothold && reboot` silently stops
working on that board.

## Adding a board

1. Copy `lidl/` to `boards/<your-board>/` and edit the four values.
2. Build with `BOARD=<your-board>` and flash **over serial first** — a
   wrong DDR value bricks the board until serial recovery (`FLW` from
   a RAM-loaded image). Do not distribute a board image that has not
   booted on real hardware.
3. Make sure your kernel DTS relocates `boothold@...` to
   `BOARD_DRAM_TOP_KSEG1 - 0x2000` (physical), keeping the `boothold:`
   label.

## Verifying the reference build

```sh
BOARD=lidl ./build_bootloader.sh
md5sum boot.bin   # must equal the committed boot.bin
```
