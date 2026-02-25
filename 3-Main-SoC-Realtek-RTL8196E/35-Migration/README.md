# Migration Guide

Migrate a Lidl/Silvercrest Zigbee Gateway from Tuya firmware to custom Linux system.

> **IMPORTANT: Backup First!**
>
> Before any migration, make a complete backup of all original partitions (bootloader, kernel, rootfs, userdata). This allows full recovery if something goes wrong.
>
> See **[30-Backup-Restore](../30-Backup-Restore/)** for detailed backup procedures.

## Prerequisites

### Hardware

- **Serial adapter** connected to gateway (38400 8N1)
- **Ethernet connection** between PC and gateway

### Software

- **tftp-hpa** client installed on your PC:
  ```bash
  # Debian/Ubuntu
  sudo apt install tftp-hpa
  ```

## Required Images

Pre-built images are available in the repository:

| Image | Location | Description |
|-------|----------|-------------|
| kernel.img | `32-Kernel/` | Linux 5.10 kernel |
| rootfs.bin | `33-Rootfs/` | Root filesystem (SquashFS) |
| userdata.bin | `34-Userdata/` | User partition (JFFS2) |

> **Note:** If you need to rebuild the images (e.g., after modifications):
> ```bash
> cd 3-Main-SoC-Realtek-RTL8196E
> ./build_rtl8196e.sh
> ```

## Migration Procedure

### Step 1: Enter Bootloader Mode

1. Open serial console on your PC:
   ```bash
   minicom -D /dev/ttyUSB0 -b 38400
   # or
   screen /dev/ttyUSB0 38400
   ```

2. Power cycle the gateway

3. Press **ESC** repeatedly during boot until you see the `<RealTek>` prompt

4. Make sure your PC's network interface is on the same subnet as the Realtek bootloader tftp server (default tftp server IP is 192.168.1.6 but can be changed if needed).
 

### Step 2: Run the Flash Script

From the `3-Main-SoC-Realtek-RTL8196E` directory:

```bash
# Flash everything (recommended for first migration)
./flash_rtl8196e.sh

# Or flash specific partitions
./flash_rtl8196e.sh rootfs           # Rootfs only
./flash_rtl8196e.sh userdata         # Userdata only
./flash_rtl8196e.sh kernel           # Kernel only
./flash_rtl8196e.sh rootfs userdata  # Rootfs + userdata
```

The script will:
1. Check that all required images exist
2. Verify you're connected and see the `<RealTek>` prompt
3. Flash partitions in the correct order (rootfs → userdata → kernel)
4. Wait for confirmation after each partition
5. Reboot automatically after kernel flash

### Step 3: Verify

After reboot, the gateway uses the network configuration chosen during flashing (static IP or DHCP). Connect via SSH:

```bash
ssh root@<GATEWAY_IP>
# Default password: root
```

Check the system:
```bash
uname -r              # Should show 5.10.x
cat /etc/version      # System version
ps | grep serial      # serialgateway should be running
```

## Script Options

```
./flash_rtl8196e.sh [target...] [--ip ADDRESS]

Targets:
  all        Flash everything (default)
  kernel     Flash Linux kernel
  rootfs     Flash root filesystem
  userdata   Flash user partition

Options:
  --ip ADDR  Bootloader TFTP server IP (default: 192.168.1.6) 
```

### Examples

```bash
# Standard migration (flash all)
./flash_rtl8196e.sh

# Update rootfs only (keep userdata and kernel)
./flash_rtl8196e.sh rootfs

# Flash to bootloader with different TFTP server IP
./flash_rtl8196e.sh --ip 10.0.0.6

# Update rootfs and userdata, keep existing kernel
./flash_rtl8196e.sh rootfs userdata
```

## Flashing Order

The script automatically handles the correct flashing order:

1. **rootfs.bin** — Root filesystem (SquashFS)
2. **userdata.bin** — User partition (JFFS2) — takes 1-2 minutes
3. **kernel.img** — Linux kernel — triggers automatic reboot

The kernel is always flashed last because it triggers an immediate reboot.

## Partition Layout

After migration:

```
0x000000-0x020000  mtd0  boot+cfg     (128 KB)   - Bootloader (unchanged)
0x020000-0x200000  mtd1  linux        (1.9 MB)   - Linux kernel
0x200000-0x420000  mtd2  rootfs       (2.1 MB)   - Root filesystem
0x420000-0x1000000 mtd3  jffs2-fs     (11.9 MB)  - User partition
```

## Troubleshooting

### Cannot enter bootloader

- Verify serial connection: 38400 baud, 8N1, no flow control
- Press ESC immediately and repeatedly when powering on
- Try different USB port or serial adapter

### TFTP transfer fails

- Check PC firewall allows UDP port 69
- Verify PC IP is on 192.168.1.x subnet
- Ensure no other TFTP server is running

### "Flash Write Successed!" doesn't appear

- Wait longer — userdata flash takes 1-2 minutes
- Check serial console for error messages
- Verify image file is not corrupted

### SSH connection refused after reboot

- Wait 30 seconds for full boot
- Check IP with serial console (`ifconfig`)
- Default credentials: `root` / `root`

### SQUASHFS error at boot

Rootfs built with wrong parameters. Rebuild with:
```bash
mksquashfs ... -b 128k -always-use-fragments
```

### Services not starting

Check init scripts and logs:
```bash
ls -la /etc/init.d/
cat /var/log/messages
```

## Rollback

To restore original firmware, flash the backed-up images:

```bash
# From bootloader (<RealTek> prompt), use TFTP to restore:
# 1. Restore kernel
tftp -m binary 192.168.1.6 -c put kernel_backup.img

# 2. Restore rootfs
tftp -m binary 192.168.1.6 -c put rootfs_backup.bin

# 3. Restore userdata
tftp -m binary 192.168.1.6 -c put userdata_backup.bin
```

See **[30-Backup-Restore](../30-Backup-Restore/)** for detailed restore procedures.
