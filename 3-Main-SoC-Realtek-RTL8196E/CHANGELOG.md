# Changelog — RTL8196E Platform (Lidl Silvercrest Zigbee Gateway)

All notable changes to the RTL8196E firmware distribution are documented here.
A version covers the complete set of components: bootloader (31-), kernel (32-),
rootfs (33-), and userdata (34-).

---

## [1.1.0] - 2026-02-23

### 31-Bootloader
- V2.3: ICMP ping support in the bootloader network stack
- Boothold mechanism: reboot-to-bootloader from Linux via DRAM magic flag
- RAM flag relocated to 0x803FFFFC (avoids kernel text corruption)

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
- **Fix**: `patches/net-core-skbuff.c.patch` hunk header corrected
  (`+89,12` → `+89,13`). The malformed header caused `patch` to silently fail,
  leaving the legacy rtl819x kernel without its private buffer pool hooks and
  causing a boot hang at S30dropbear
- Legacy `rtl819x` driver remains available as a reference build

### 34-Userdata
- `/etc/version` updated to include firmware version

---

## [1.0.0] - 2025-12-01

Initial release.

### 31-Bootloader
- V2.2: basic TFTP boot, network stack

### 32-Kernel
- Linux 5.10.246, legacy `rtl819x` Ethernet driver, lzma-loader decompressor

### 33-Rootfs
- musl 1.2.5, busybox 1.37, dropbear 2025.88

### 34-Userdata
- Init scripts: S20time (NTP), S30dropbear (SSH), hostname, eth0 config
