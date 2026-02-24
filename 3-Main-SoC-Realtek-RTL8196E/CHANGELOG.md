# Changelog — RTL8196E Platform (Lidl Silvercrest Zigbee Gateway)

All notable changes to the RTL8196E firmware distribution are documented here.
A version covers the complete set of components: bootloader (31-), kernel (32-),
rootfs (33-), and userdata (34-).

---

## [1.1.0] - 2026-02-24

### 30-Backup-Restore (new)
- `backup_mtd_via_ssh.sh` / `restore_mtd_via_ssh.sh`: per-partition SSH backup and restore, original firmware only (5 partitions, port 2333); 4-partition layout rejected with FLR/FLW guidance
- README: method comparison table (SSH / FLR/FLW / SPI programmer), full FLR/FLW backup and restore procedure

### 31-Bootloader
- Fully rewritten from [Sourceforge V3.4.7.3 SDK](https://sourceforge.net/projects/rtl819x/files/) source code and adapted to the new lexra toolchain
- V2.3: ICMP ping support — `ping 192.168.1.6` works from download mode
- Boothold mechanism: reboot-to-bootloader from Linux via DRAM magic flag
  (`devmem 0x003FFFFC 32 0x484F4C44 && reboot`), RAM flag at 0x803FFFFC
- Download progress shown as percentage instead of endless `.` / `#`
- `flash_bootloader.sh`: ARP-based boot mode detection (rootless, no arping),
  clean error reporting with exit code, TFTP error detection

### 32-Kernel
- **New driver**: `rtl8196e-eth` — clean-room Ethernet driver (1 855 pure LOC
  vs 9 664 for legacy rtl819x, 5.2× reduction)
  - TCP RX: **91.2 Mbps** (+6.4% vs legacy 85.7 Mbps)
  - TCP TX: **46.9 Mbps** (+8.1% vs legacy 43.4 Mbps)
  - TCP stress 300s: 92.0 Mbps, 0 errors, 0 retransmissions (SoC side)
  - Architecture: NAPI, zero-copy RX (`napi_alloc_skb`), no spinlock, no BQL,
    devicetree-based configuration
- **New build system**: unified `build_kernel.sh` supporting both drivers
  (`./build_kernel.sh` for rtl8196e-eth, `./build_kernel.sh legacy` for rtl819x)
- **New decompressor**: zboot (`arch/mips/boot/compressed/`) replaces the
  external lzma-loader from the Realtek SDK — no external tool dependency
- Legacy `rtl819x` driver from initial release 1.0.0 remains available as a reference build

### 34-Userdata
- `/etc/version` updated to include firmware version

### Flash scripts
- Fixed invalid `-timeout` tftp flag in all scripts — replaced by `timeout N tftp` wrapper
- `flash_rtl8196e.sh`: fixed `set -e` silent exit, improved UX messages
- `flash_rtl8196e.sh`: optional FLR full flash backup before flashing, saved as `YYMMJJ-HH.MM-Gw-Backup.bin`

---

## [1.0.0] - 2025-12-18

Initial release.

### 31-Bootloader
- Lidl/Tuya/Realtek original bootloader

### 32-Kernel
- Linux 5.10.246, legacy `rtl819x` Ethernet driver developed from original 2.6 code, lzma-loader decompressor

### 33-Rootfs
- musl 1.2.5, busybox 1.37, dropbear 2025.88

### 34-Userdata
- Init scripts: S20time (NTP), S30dropbear (SSH), hostname, eth0 config
