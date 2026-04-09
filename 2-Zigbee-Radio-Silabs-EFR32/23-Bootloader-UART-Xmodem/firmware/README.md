# Bootloader Firmware Files

Built firmware files for EFR32MG1B232F256GM48 (Lidl Silvercrest Gateway).

## Downloads (pre-built v2.4.2)

- [`bootloader-uart-xmodem-2.4.2-combined.s37`](bootloader-uart-xmodem-2.4.2-combined.s37) — Stage 1 + Stage 2 combined (J-Link, full install)
- [`bootloader-uart-xmodem-2.4.2.s37`](bootloader-uart-xmodem-2.4.2.s37) — Stage 2 only (J-Link, Silabs format)
- [`bootloader-uart-xmodem-2.4.2.gbl`](bootloader-uart-xmodem-2.4.2.gbl) — Stage 2 in GBL (XMODEM upload)

## File formats

| File | Content | Flash Address | Usage |
|------|---------|---------------|-------|
| `first_stage.s37` | Stage 1 (BSL) | 0x0000-0x07FF | J-Link only |
| `bootloader-uart-xmodem-X.Y.Z.s37` | Stage 2 (Main) | 0x0800-0x3FFF | J-Link (Silabs format) |
| `bootloader-uart-xmodem-X.Y.Z.gbl` | Stage 2 in GBL | - | XMODEM upload |
| `bootloader-uart-xmodem-X.Y.Z.hex` | Stage 2 | 0x0800-0x3FFF | J-Link (Intel HEX format) |
| `bootloader-uart-xmodem-X.Y.Z.bin` | Stage 2 raw binary | - | Other programmers |

## When to Use Each File

### Stage 1 (`first_stage.s37`)
- **Required**: Only via J-Link/SWD
- **When**: Fresh chip, corrupted Stage 1, or full chip erase
- **Note**: Normally flashed once and never updated

### Stage 2 (`bootloader-uart-xmodem-X.Y.Z.s37`)
- **Method**: J-Link/SWD
- **When**: Initial setup or Stage 1 already present

### Stage 2 GBL (`bootloader-uart-xmodem-X.Y.Z.gbl`)
- **Method**: XMODEM over UART
- **When**: Updating bootloader remotely (Stage 1 must be working)
- **Requires**: Existing working bootloader to receive the update

## Flash Commands

### Full bootloader installation (J-Link)
```bash
# Flash both stages
commander flash first_stage.s37 --device EFR32MG1B232F256GM48
commander flash bootloader-uart-xmodem-2.4.2.s37 --device EFR32MG1B232F256GM48
```

### Stage 2 update only (J-Link)
```bash
commander flash bootloader-uart-xmodem-2.4.2.s37 --device EFR32MG1B232F256GM48
```

### Stage 2 update via XMODEM (remote)
```bash
# Requires working Stage 1 bootloader
# Enter bootloader mode, then send .gbl via XMODEM
```

## Memory Map

```
0x00000000 ┌─────────────────────────┐
           │  Stage 1 (2 KB)         │ ← first_stage.s37
0x00000800 ├─────────────────────────┤
           │  Stage 2 (14 KB)        │ ← bootloader-uart-xmodem-X.Y.Z.s37
0x00004000 ├─────────────────────────┤
           │  Application            │ ← NCP or Router firmware
           │                         │
0x00040000 └─────────────────────────┘
```
