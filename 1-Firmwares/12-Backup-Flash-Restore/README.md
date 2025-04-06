# Backup, Flash and Restore Procedure

## Overview

Before modifying the firmware of your **Lidl Silvercrest Zigbee gateway**, it is **strongly recommended** to back up the original firmware. This ensures you can recover in case of a failed update or configuration error.

This guide describes two main methods to back up, flash and restore the **EFR32MG1B firmware**:

1. **Method 1 – Hardware-based (RECOMMENDED)**:  
   Using a hardware debugger via the SWD interface with Simplicity Commander.

2. **Method 2 – Software-based**:  
   Using tools like ad-hoc script over SSH or software tools (like `universal-silabs-flasher`) requiring no extra hardware.

> ⚠️ **Important:** Method 1 is the **most reliable and complete** solution, offering full access to the flash memory and robust verification.


---


### Firmware File Types: `.bin`, `.s37`, and `.gbl`

When working with EFR32MG1B firmware, you may encounter different file formats, each serving specific purposes:

- **`.bin` (Raw Binary)**: A direct dump of the flash memory. This format is typically produced by the `commander readmem` command or `universal-silabs-flasher`. It contains the exact contents of the flash, byte-for-byte, without metadata. It is the **preferred format for full backup and restore operations** using hardware debuggers or low-level tools.

- **`.s37` (Motorola S-Record)**: An ASCII-based, human-readable representation of binary data, often used during development or with bootloaders. While supported by many Silicon Labs tools, this format is less common in user-generated backups.

- **`.gbl` (Gecko Bootloader Image)**: A structured, compressed firmware package used for **bootloader-based OTA (Over-The-Air)** or UART-based updates. It includes integrity checks and metadata, making it suitable for secure, partial updates, but **cannot be used for full flash restoration**. `commander flash` accepts `.gbl` files, but only if the bootloader is intact and supports it.

> ⚠️ **Important**: When performing a full firmware backup or raw restoration, always use the `.bin` format. Flashing `.gbl` files over raw flash interfaces (like SWD) will not reconstruct the original flash layout and may result in a non-functional system unless the Gecko Bootloader is in place and operational.


--- 


## Method 1: Hardware Backup, Flash & Restore via SWD (Recommended)

### Requirements

- Lidl Silvercrest gateway with accessible SWD pins
- A J-Link or compatible SWD debugger. I personally use a cheap (less than 5 USD incl shipping) OB-ARM Emulator Debugger Programmer:
    <p align="center"> <img src="./media/image1.png" alt="OB-ARM debugger" width="70%"> </p>
A useful investment! You can also build your own debugger with a Raspberry Pico and [`OpenOCD`](https://openocd.org/). Search the web!
- [Simplicity Studio V5](https://www.silabs.com/developers/simplicity-studio) with `commander` tool
- Dupont jumper wires (x4)

### Pinout and Wiring

Connect the debugger to the gateway as follows:

| Gateway Pin | Function | J-Link Pin |
|-------------|----------|------------|
| 1           | VREF (3.3V) | VTref     |
| 2           | GND        | GND       |
| 5           | SWDIO      | SWDIO     |
| 6           | SWCLK      | SWCLK     |

---

### Backup Procedure

1. **Launch Commander**:  
   On Windows (default path):
   ```bash
   cd "C:\SiliconLabs\SimplicityStudio\v5\developer\adapter_packs\commander"
   ```

2. **Check Device Connection**:
   ```bash
   commander device info --device EFR32MG
   ```
   Output:
   ```
   C:\SiliconLabs\SimplicityStudio\v5\developer\adapter_packs\commander>commander device info --device EFR32MG
   Reconfiguring debug connection with detected device part number: EFR32MG1B232F256GM48
   Part Number    : EFR32MG1B232F256GM48
   Die Revision   : A3
   Production Ver : 166
   Flash Size     : 256 kB
   SRAM Size      : 32 kB
   Unique ID      : xxxxxxxxxxxxxxxx
   User Data Page : Unlocked
   Mass Erase     : Unlocked
   Bootloader     : Enabled
   Pin Reset      : Soft Reset
   DONE
   ```

3. **Read Full Flash (256KB)**:
   ```bash
   commander readmem --device EFR32MG1B232F256GM48 --range 0x0:0x40000 --outfile original_firmware.bin
   ```
   Output:
   ```
   C:\SiliconLabs\SimplicityStudio\v5\developer\adapter_packs\commander>commander readmem --device EFR32MG1B232F256GM48 --range 0x0:0x40000 --outfile original_firmware.bin
   Reading 262144 bytes from 0x00000000...
   Writing to original_firmware.bin...
   DONE
   ```
   This creates a full backup of the firmware, including the bootloader.
   
4. **(Optional) Verify Backup**:
   ```bash
   commander verify --device EFR32MG1B232F256GM48 original_firmware.bin
   ```
   Output:
   ```
   C:\SiliconLabs\SimplicityStudio\v5\developer\adapter_packs\commander>commander verify --device EFR32MG1B232F256GM48 original_firmware.bin
   Parsing file original_firmware.bin...
   Verifying 262144 bytes at address 0x00000000...OK!
   DONE
   ```
---

### Restore Procedure

1. **Connect and verify debugger** as above.

2. **Flash firmware**:
   ```bash
   commander flash --device EFR32MG1B232F256GM48 firmware.bin
   ```
   Output:
   ```
   C:\SiliconLabs\SimplicityStudio\v5\developer\adapter_packs\commander>commander flash --device EFR32MG1B232F256GM48 firmware.bin
   Parsing file firmware.bin...
   Writing 262144 bytes starting at address 0x00000000
   Comparing range 0x00000000 - 0x0001FFFF (128 KB)
   Comparing range 0x00020000 - 0x0003FFFF (128 KB)
   Comparing range 0x00000000 - 0x00003FFF (16 KB)
   Comparing range 0x00038000 - 0x0003FFFF (32 KB)
   Erasing range 0x00004000 - 0x00023FFF (64 sectors, 128 KB)
   Erasing range 0x00024000 - 0x00037FFF (40 sectors, 80 KB)
   Programming range 0x00004000 - 0x00004FFF (4 KB)
   Programming range 0x00005000 - 0x00005FFF (4 KB)
   Programming range 0x00006000 - 0x00006FFF (4 KB)
   # ... more output
   Programming range 0x00035000 - 0x00035FFF (4 KB)
   Programming range 0x00036000 - 0x00036FFF (4 KB)
   Programming range 0x00037000 - 0x00037FFF (4 KB)
   Flashing completed successfully!
   DONE
   ```


Alternatively, use Simplicity Studio GUI:
- Launch Simplicity Studio
- Open Tools → Commander
- Use the **Flash** tab to select your `.bin` file and program it

---

### Flashing a `.gbl` File (Bootloader Mode Only)

If your device is running a functional Gecko Bootloader, you can flash `.gbl` (Gecko Bootloader Image) files using Commander or the Simplicity Studio GUI. This method is useful for incremental updates or OTA-style deployment but **cannot perform full firmware restoration**.

#### Using Commander:
```bash
commander gbl flash --device EFR32MG1B232F256GM48 firmware.gbl
```

#### Caveats:
- The Gecko Bootloader **must be present and working**. If the bootloader is erased or corrupted, this method will fail silently.
- Flashing a `.gbl` file does **not overwrite the full flash memory**. Configuration, bootloader, and custom sections may be left unchanged.
- Do **not** use `.gbl` files if your goal is a full recovery or to revert to the factory state. Use `.bin` instead.

Alternatively, you can flash a `.gbl` file via the Simplicity Studio GUI:
- Open Simplicity Studio → Tools → Commander
- Select the **Upgrade Application** tab
- Choose your `.gbl` file and click Flash

---

## Method 2: Software-Based Backup, Flash & Restore (Without Hardware)

> ⚠️ While convenient, this method is **less reliable**, with potential timeouts issues. Use this only if the hardware method via SWD is not feasible.

Those approaches share important prerequisites: 
- No Zigbee2mqtt or ZHA attached to your gateway
- No ssh or terminal session connected to your gateway (apart from the one used by the flash script itself)
- A robust ethernet **wired** connection (No Wi-Fi!)

### The original Approach

The original script `firmware_upgrade.sh` was developed in `ash` (busybox minimal `bash`) and is available in [Lasse Bjerre GitHub](https://github.com/Ordspilleren/lidl-gateway-freedom)

My own version of this script, taking care of the most recent versions of ssh and risks of timeouts is provided in the [NCP firmware directory](../14-NCP-UART-HW/firmware). Three scripts are available:
- `flash_ezsp7.sh` to update an EZSP V7 based firmware like the original Lidl/Silvercrest gateway
- `flash_ezsp8.sh` to update an EZSP V8 based firmware like the hacked Lidl/Silvercrest gateway
- `flash_ezsp13.sh` to upfate an EZSP V13 based firmware like the one you can build from [here](../14-NCP-UART-HW) or that can be directly downloaded [here](../14-NCP-UART-HW/firmware)

You must choose the script according to the EZSP version **currently** installed in your firmware. You can identify it with Zigbee2mqtt INFO log. On a linux machine download in the same working directory the firmware you want to install (in .gbl format), the sx xmodem transfer utility and the proper script. Make the script executable (e.g. chmod +x flash_ezsp7.sh)

Examples:

To update an original Lidl/Silvercrest gateway with EmberZNet 7.5.0:
```
./flash_ezsp7 192.168.1.88 ncp-uart-7.5.0.gbl
```
To update an already hacked Lidl/Silvercrest gateway using the `NCP_UHW_MG1B232_678_PA0-PA1-PB11_PA5-PA4.gbl` firmware with Ember 7.4.5:
```
./flash_ezsp8 192.168.1.88 ncp-uart-7.4.5.gbl
```
To update an already hacked Lidl/Silvercrest gateway using a 7.4.5 EmberZNet firmware with EmberZNet 7.5.0:
```
./flash_ezsp13 192.168.1.88 ncp-uart-7.5.0.gbl
```

### Universal-silabs-flasher

Some users report that they have been able to use [universal-silabs-flasherhttps://github.com/NabuCasa/universal-silabs-flasher]](https://github.com/NabuCasa/universal-silabs-flasher] to update their firmware. In theory that should be possible but in my own experience I frequently got frequent timeouts issues. To I leave that approach to your own judgment and will happily report the proper way to use that tool.

---

## Resources

- [Simplicity Commander Reference Guide (PDF)](https://www.silabs.com/documents/public/user-guides/ug162-simplicity-commander-reference-guide.pdf)
- [universal-silabs-flasher GitHub](https://github.com/NabuCasa/universal-silabs-flasher)
- [EFR32MG1B Series Datasheet](https://www.silabs.com/documents/public/data-sheets/efr32mg1-datasheet.pdf)

