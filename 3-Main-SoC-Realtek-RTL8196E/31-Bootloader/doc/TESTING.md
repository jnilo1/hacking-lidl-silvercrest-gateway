# RTL8196E Bootloader Testing Guide

## Overview

The bootloader build produces two binaries:

| File                | Description                              | Build flag      |
|---------------------|------------------------------------------|-----------------|
| `boot.bin`          | Flash image (no reboot after boot TFTP)  | —               |
| `test.bin`          | RAM-testable bootloader (raw binary)     | `RAMTEST_TRACE` |

`test.bin` mirrors the bootloader behavior except it **skips kernel boot**
and enters download mode directly.  This allows testing all bootloader
functionality from RAM before committing to flash.

---

## Prerequisites

- Serial console: 38400 8N1
- Ethernet cable between PC and board (any port)
- PC network interface configured to `192.168.1.x` (e.g. `192.168.1.1`)
- TFTP client installed (`sudo apt install tftp-hpa`)

---

## Memory map constraints

```
0x80000000 - 0x80000200   MIPS exception vectors (DO NOT OVERWRITE)
0x80100000 - 0x80200000   Safe area for loading test.bin
0x80400000 - 0x80421600   Bootloader code/data/BSS (DO NOT OVERWRITE)
0x80500000 - ...          Default TFTP load address (AUTOBURN images)
```

**Important:** Never use `LOADADDR 80000000`.  Writing to this address
overwrites the CPU exception vectors, causing an immediate crash on
the next interrupt.

---

## 1. Loading test.bin into RAM

This is the primary testing workflow.  It runs the new bootloader from
RAM without modifying flash.

### Step 1 — Enter download mode

Power on or hardware-reset the board.  Press **ESC** within 3 seconds
to abort kernel boot:

```
Booting...
Realtek RTL8196E  CPU: 380MHz  RAM: 32MB  Flash: GD25Q128
Bootloader: v2.1 - 2026.02.11-11:15+0100 - J. Nilo
---Escape booting by user
P0phymode=01, embedded phy

---Ethernet init Okay!
<RealTek>
```

### Step 2 — Upload test.bin

```
<RealTek>AUTOBURN 0
AutoBurning=0
<RealTek>LOADADDR 80100000
Set TFTP Load Addr 0x80100000
```

From the PC:

```bash
tftp -m binary 192.168.1.6 -c put test.bin
```

Expected output on serial console:

```
**TFTP Client Upload, File Name: test.bin
\
**TFTP Client Upload File Size = 5220 Bytes at 80100000

Success!
<RealTek>
```

### Step 3 — Execute test.bin

```
<RealTek>J 80100000
---Jump to address=80100000
Realtek RTL8196E  CPU: 380MHz  RAM: 32MB  Flash: GD25Q128
Bootloader: v2.1 - 2026.02.11-11:30+0100 - J. Nilo
---RAMTEST mode: skipping kernel boot

---Escape booting by user
P0phymode=01, embedded phy

---Ethernet init Okay!
<RealTek>
```

Verify:
- Timestamp matches the build time (not the flash bootloader's timestamp)
- `RAMTEST mode: skipping kernel boot` is displayed
- Board enters `<RealTek>` prompt without booting the kernel

### Step 4 — Run tests

You are now running the new bootloader from RAM.  All commands are
available.  See sections below for specific test procedures.

**Note:** The serial console has no hardware flow control.  When
copy-pasting multiple commands, enter them one at a time and wait for
each prompt before sending the next.

---

## 2. Flashing the bootloader

Once test.bin is validated, flash the production bootloader.

### From the flash bootloader (ESC at boot)

```
<RealTek>AUTOBURN 1
AutoBurning=1
```

From the PC:

```bash
tftp -m binary 192.168.1.6 -c put boot.bin
```

Expected output:

```
**TFTP Client Upload, File Name: boot.bin
**TFTP Client Upload File Size = 55E2 Bytes at 80500000
Success!

Boot code upgrade.
checksum Ok !
Flash write: dst=0x0 src=0x80500010 len=0x55d2 (21970 bytes)
Flash Write Succeeded!
<RealTek>
```

The board stays at the prompt after flashing.  Reboot manually:

```
<RealTek>J BFC00000
```

### From test.bin (running in RAM)

The same procedure works when running test.bin.  This is useful to
flash a bootloader while still having a safety net (the flash
bootloader is untouched until you explicitly flash).

---

## 3. Flashing a firmware image (kernel)

```
<RealTek>AUTOBURN 1
AutoBurning=1
```

From the PC:

```bash
tftp -m binary 192.168.1.6 -c put firmware.bin
```

Expected output:

```
**TFTP Client Upload, File Name: firmware.bin
**TFTP Client Upload File Size = F5000 Bytes at 80500000
Success!

Linux kernel upgrade.
checksum Ok !
Flash write: dst=0x30000 src=0x80500000 len=0xF5000 (1003520 bytes)
Flash Write Succeeded!
reboot.......
```

Kernel images (`cs6c`/`cr6c` signature) have `reboot=1` — the board
reboots automatically after flashing.

---

## 4. Command validation checklist

Test each command after code changes.  Commands are grouped by risk
level.

### Read-only commands (safe, no side effects)

| Command | Test | Expected |
|---------|------|----------|
| `?` | `?` | Help text listing all commands |
| `DB` | `DB 80000000 64` | Hex byte dump, 4 lines |
| `DW` | `DW B8000000 4` | Word dump, 4 lines of 4 words |
| `CMP` | `CMP 80000000 80000000 100` | `No error found` |
| `PHYR` | `PHYR 0 0` | `PHYID=0x0 regID=0x0 data=0x1100` |
| `MDIOR` | `MDIOR 0` | 32 lines, PHY 0-4 show data, rest 0x0000 |
| `LOADADDR` | `LOADADDR` | Shows current load address |
| `AUTOBURN` | `AUTOBURN` | Shows current setting |
| `IPCONFIG` | `IPCONFIG` | `Target Address=192.168.1.6` |

### Write commands (safe, reversible)

| Command | Test | Expected |
|---------|------|----------|
| `EW` | `EW 80500000 DEADBEEF` then `DW 80500000 1` | First word = `DEADBEEF` |
| `EB` | `EB 80500000 41 42 43 44` then `DB 80500000 4` | Bytes `41 42 43 44` |
| `PHYW` | `PHYW 0 0 1100` | Write + Readback, data=0x1100 |
| `MDIOW` | `MDIOW 0 0 1100` | Write + Readback, data=0x1100 |
| `IPCONFIG` | `IPCONFIG 192.168.1.100` then `IPCONFIG` | Shows new address |
| `AUTOBURN` | `AUTOBURN 0` then `AUTOBURN` | `AutoBurning=0` |
| `LOADADDR` | `LOADADDR 80200000` then `LOADADDR` | Shows `0x80200000` |

### Flash commands (destructive, use with caution)

| Command | Test | Expected |
|---------|------|----------|
| `FLR` | `FLR 80500000 0 100` | `Flash Read Succeeded!` |
| `FLW` | see note below | Prompts (Y)es/(N)o, writes to SPI |

**FLW test procedure** (safe round-trip):

```
FLR 80500000 10000 100        Read 256 bytes from flash offset 0x10000
DB 80500000 16                Verify contents
FLW 10000 80500000 100        Write same data back (no-op, same content)
```

### Execution commands

| Command | Test | Expected |
|---------|------|----------|
| `J` | `J BFC00000` | Board reboots (watchdog reset) |

---

## 5. TFTP server validation

The TFTP server runs in the background while the console is active.

### Upload test

```bash
# From PC
tftp -m binary 192.168.1.6 -c put test.bin
```

Verify on serial console:
- File name displayed
- File size matches
- `Success!` message

### Download test (RRQ / `tftp get`)

Load data into RAM first, then download it to the host:

```
<RealTek>FLR 80500000 0 100
Flash Read Succeeded!
```

From the PC:

```bash
tftp -m binary 192.168.1.6 -c get flash_dump.bin
ls -l flash_dump.bin   # should be 256 bytes (0x100)
```

Verify on serial console:
- `**TFTP Server Download: 100 bytes from 80500000`
- Progress twiddler
- `TFTP Download Complete!`

**Echo-back test** (upload then download, compare):

```bash
dd if=/dev/urandom of=test_data.bin bs=1 count=4096
tftp -m binary 192.168.1.6 -c put test_data.bin
tftp -m binary 192.168.1.6 -c get readback.bin
cmp test_data.bin readback.bin && echo "PASS" || echo "FAIL"
```

**Error case** — `get` with no data loaded (fresh boot, no FLR/upload):

```bash
tftp -m binary 192.168.1.6 -c get empty.bin
```

Expected: serial console shows `**TFTP RRQ Error: no data loaded`,
transfer fails on the client side.

### AUTOBURN test

Upload images with known signatures and verify:

| Image | Signature | Expected behavior |
|-------|-----------|-------------------|
| `boot.bin` | `boot` | Flash to offset 0, no reboot |
| `firmware.bin` | `cs6c` | Flash to kernel offset, auto-reboot |

---

## 6. Troubleshooting

### TFTP transfer hangs

- Check IP address: default is `192.168.1.6`, reset after every reboot
- Verify the board is at the `<RealTek>` prompt (not booting kernel)
- Check PC network: `ping 192.168.1.6` should fail (bootloader does
  not respond to ICMP), but ARP should resolve

### Board reboots unexpectedly after TFTP upload

- Verify `AUTOBURN 0` if you don't want auto-flashing
- Never use `LOADADDR 80000000` — overwrites exception vectors

### test.bin shows wrong timestamp

- Verify you uploaded the freshly-built `test.bin`, not a stale copy
- Check build output: `make` prints the payload size — compare with
  the TFTP upload size on the serial console

### Checksum error on flash

- All images generated by `cvimg` use 16-bit checksums
- If checksum fails, the image file may be corrupted — rebuild and
  re-upload

### No boot log after J command

- Ensure `LOADADDR` was set to `80100000` (not `80000000`)
- Ensure test.bin was built with `RAMTEST_TRACE` (check for
  `---RAMTEST mode` in output)

---

## 7. Quick reference

```bash
# === Load and run test.bin ===
# On serial console:
AUTOBURN 0
LOADADDR 80100000
# On PC:
tftp -m binary 192.168.1.6 -c put test.bin
# On serial console:
J 80100000

# === Flash bootloader ===
# On serial console:
AUTOBURN 1
# On PC:
tftp -m binary 192.168.1.6 -c put boot.bin
# On serial console (after "Flash Write Succeeded!"):
J BFC00000

# === Flash firmware ===
# On serial console:
AUTOBURN 1
# On PC:
tftp -m binary 192.168.1.6 -c put firmware.bin
# (board reboots automatically)
```
