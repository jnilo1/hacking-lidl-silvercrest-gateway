# Changelog — RTL8196E Platform (Lidl Silvercrest Gateway)

All notable changes to the RTL8196E firmware distribution are documented here.
A version covers the complete set of components: bootloader (31-), kernel (32-),
rootfs (33-), and userdata (34-).

---

## [2.1.6] - 2026-04-10

### Fixes
- **DHCP resilience**: udhcpc now uses `-b` instead of `-n`, so if the DHCP
  server is unavailable at boot the client keeps retrying in the background
  and configures the gateway automatically once a lease is obtained. Previously
  the gateway stayed without an IP until rebooted. (S10network — [#82])
- **`/var/hosts` updated on late DHCP lease**: `udhcpc.script` now regenerates
  `/var/hosts` in the `bound` handler, so the hostname→IP mapping is corrected
  when a lease arrives after initial failure. (udhcpc.script — [#82])
- **Hostname fallback uses `127.0.1.1`**: S15hostname now falls back to
  `127.0.1.1` (Debian convention) instead of `192.168.1.254` when no IP is
  assigned at boot. (S15hostname — [#82])

[#82]: https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/82

---

## [2.1.5] - 2026-04-04

### OTBR REST API — PascalCase kept

The PascalCase REST API patch is **kept**. `python-otbr-api` 2.9.0
(HA 2026.4) accepts camelCase in GET responses but still sends PascalCase
in PUT requests — upstream `otbr-agent` (camelCase) rejects them.
PascalCase `otbr-agent` works with all HA versions.
See [python-otbr-api#238](https://github.com/home-assistant-libs/python-otbr-api/issues/238).

### New features
- **Dropbear SCP & SSH client**: `scp` and `dbclient` (SSH client) added to
  the dropbear multi-call binary. Enables `scp` file transfers to/from the
  gateway and outbound SSH connections via `dbclient`. Progress bar included
  (`SCPPROGRESS`). Binary size: 473 KB → 555 KB (+82 KB).

### Fixes
- **rootfs.bin always rebuilt**: `build_fullflash.sh` and `flash_rootfs.sh`
  now always rebuild `rootfs.bin` from the skeleton, like `userdata.bin`.
  Prevents stale images from being flashed after an upgrade.
- **version/motd bumped** to v2.1.5.

---

## [2.1.4] - 2026-04-02

### New features
- **LED off mode**: `MODE=off` in `leds.conf` completely disables both LEDs
  (LAN + STATUS). The LAN LED is turned off via the `DIRECTLCR` register
  (0xBB804314) which controls the switch ASIC LED output scale — setting it
  to 0 fully disables the LED output with no residual glow.
- **`led_mode` sysfs**: now supports `bright`, `dim`, and `off`.
  `serialgateway` v2.2 and `S70otbr` respect `off` mode (STATUS LED stays
  at 0 even when the radio is connected).

### Changes
- **rtl8196e-eth v2.2**: added `DIRECTLCR` register support for true LED off.
- **serialgateway v2.2**: respects `led_mode=off` (keeps STATUS LED at 0).

---

## [2.1.3] - 2026-04-01

### New features
- **LED dual brightness mode**: new `led_mode` sysfs attribute
  (`/sys/class/net/eth0/led_mode`) allows switching between `bright`
  (default) and `dim` modes. In `dim` mode, both LEDs run at reduced
  intensity for nighttime use.
- **`leds-gpio-pwm` driver**: new GPIO LED driver with software PWM
  brightness control (0-255) via kernel timer_list (250 Hz). Replaces
  `gpio-leds` for the STATUS LED. At brightness 0 or 255 the timer is
  stopped (zero CPU overhead). Designed for SoCs without hardware PWM.
- **`S11leds` init script**: persistent LED mode via `/userdata/etc/leds.conf`.
  Set `MODE=dim` or `MODE=bright` (default). Applied at boot right after
  network init, before serialgateway/otbr-agent start.
- **`flash_efr32.sh` PWM guard**: disables status LED PWM before Xmodem
  transfer to avoid bus contention between GPIO writes and UART on the
  shared LX bus. Brightness is restored on reboot via S11leds.
- **Config preservation**: `leds.conf` added to `SAVE_FILES` in
  `flash_install_rtl8196e.sh` and `flash_remote.sh` — LED preference
  survives firmware upgrades.

### Bug fixes
- **LAN LED dim after Linux 5.10 port**: the LAN LED is hardwired to
  the switch ASIC LED_PORT0 output, not to the GPIO pad. GPIO control
  had no physical effect. Fixed: Ethernet driver now configures LEDCREG
  in LEDMODE_DIRECT after FULL_RST, restoring full-brightness
  link/activity indication as in the stock firmware.
- **STATUS LED invisible with serialgateway**: `_set_status_led()` wrote
  `"1\n"` to brightness. With `gpio-leds` (max=1) this was full-on, but
  with `leds-gpio-pwm` (max=255) it was 0.4% duty cycle — invisible.
  Fixed: serialgateway v2.1 reads `led_mode` and writes 255 (bright) or
  60 (dim). Same fix applied to S70otbr LED daemon.

### Technical notes
- **Hardware discovery**: PIN_MUX_SEL_2 bits [1:0] = 11 (GPIO mode)
  has no effect on the LAN LED — the PCB routes it directly to the
  switch ASIC LED output, bypassing the pin mux. Confirmed by register
  analysis: GPIO DATA register toggles correctly but LED does not
  respond; LEDCREG changes immediately affect the LED.
- Ethernet driver bumped to v2.1, serialgateway bumped to v2.1.

---

## [2.1.2] - 2026-03-23

### Bug fixes
- **Skeleton pollution / cross-contamination after flash**: `flash_remote.sh`,
  `flash_install_rtl8196e.sh`, `build_fullflash.sh`, and `create_fullflash.sh`
  injected gateway config into the skeleton directory, leaving residual files
  (dropbear keys, radio.conf, thread/) between runs. Flashing one device in
  OTBR mode then another in Zigbee mode leaked radio.conf. Refactored: all
  scripts now work on a temporary copy of the skeleton via `SKELETON_DIR`;
  the original is never modified. Credit: olivluca (#73).
- **S70otbr redundant flash writes**: sync daemon wrote to flash on first poll
  (seeded with empty `last_dataset`) and unconditionally on shutdown. Fixed:
  `last_dataset` seeded from REST API before entering the loop; trap and stop
  no longer copy — the daemon syncs on dataset change only. Frame counters
  are ephemeral (OpenThread recovers by jumping ahead). Credit: olivluca (#66).
- **Serial console backspace**: replaced `askfirst` + `login` with
  `getty -L 38400 ttyS0 vt100` in rootfs inittab — backspace now works
  at the login prompt.

---

## [2.1.1] - 2026-03-22

### Bug fixes
- **`boothold` unreliable via SSH**: BusyBox `devmem` writes through KSEG0
  (cached, write-back) — the HOLD flag could stay in L1 D-cache and be lost
  on watchdog reset. Replaced with a C binary (`boothold`) that uses
  `pwrite()` + `O_SYNC` on `/dev/mem` to force the write to DRAM.
- **JFFS2 decompression errors on fresh userdata flash**: `mkfs.jffs2 -X zlib`
  enables zlib but does not disable rtime (enabled by default). Added
  `-x rtime -x lzo` to force zlib-only compression — matches the kernel
  config (`CONFIG_JFFS2_ZLIB=y`, no rtime/lzo).
- **Skeleton pollution after flash**: `flash_remote.sh` and
  `flash_install_rtl8196e.sh` injected gateway config (passwd, eth0.conf,
  etc.) into the skeleton without cleanup. Added `rsync --delete` restore
  via EXIT trap — skeleton is always restored to its original state.

### Improvements
- **Bootloader V2.5**: auto-reboot after flashing all partition types
  (rootfs, bootloader — was only kernel).
- **`flash_remote.sh`**: two-phase bootloader detection (wait SSH down,
  then ARP) prevents false positives during shutdown. ControlMaster socket
  closed after boothold. Skip redundant boot mode check via
  `BOOTLOADER_CONFIRMED`. Quiet build mode via `BUILD_QUIET`.
- **`flash_install_rtl8196e.sh`**: firmware version displayed early (v2.1.0
  format). EFR32 compatible firmware list shown at end (depends on radio mode).
  Same two-phase detection and ControlMaster fix.
- **`build_rootfs.sh`**: quiet mode (`-q`) for auto-build from flash scripts.
- **S70otbr**: sync daemon uses REST API instead of `ot-ctl` (eliminates
  broken pipe warnings). Fast poll (5s) until Thread is up, then 30s.

---

## [2.1.0] - 2026-03-21

### Bug fixes
- **`boothold` fails on running system**: the kernel's page allocator actively
  uses the page at physical `0x003FFFFC` (KSEG0 cached), overwriting the HOLD
  magic written by `devmem` (KSEG1 uncached) within milliseconds. Fixed by
  declaring the page as `reserved-memory` with `no-map` in the device tree —
  the kernel never allocates it, eliminating the cache coherency conflict.
  Address kept at `0x003FFFFC` (top of DRAM is unsafe: btcode stack).
  Bootloader V2.4: BOOTHOLD_RAM uses KSEG1 (`0xA03FFFFC`) so the clear
  bypasses the write-back cache and reaches DRAM — prevents false boot-hold
  after power cycle.
- **Thread dataset lost on reboot**: S70otbr sync loop only ran 60s after boot —
  networks created later were never persisted. Replaced with a persistent daemon
  that polls `ot-ctl dataset active -x` every 30s and syncs to flash only when
  the dataset changes. Traps SIGTERM for a final sync on shutdown.
- **No shutdown hooks**: added `::shutdown:` entry to rootfs inittab, calling a
  new `rcK` script that stops all services in reverse order on reboot — ensures
  clean `stop` for otbr-agent and all other init scripts.

### New features
- **OTBR status LED**: S70otbr sync daemon polls `ot-ctl state` every 30s —
  LED on when Thread network is formed (child/router/leader), off otherwise.
  Replaces netdev trigger on wpan0 which did not reflect Thread network state.

### Improvements
- **Auto-flash on first flash**: `flash_install_rtl8196e.sh` now attempts auto-flash
  when `BOOTLOADER_TYPE=v2` even without SSH (first flash, `FW_VERSION` unknown).
  Worst case (old V2.3 without auto-flash): 3-min timeout then fallback to manual FLW.
- **EFR32 flash prompt**: at the end of `flash_install_rtl8196e.sh`, interactive mode
  now offers to launch `flash_efr32.sh` to flash the Zigbee/Thread radio firmware.
- **`userdata.bin` and `rootfs.bin` removed from git**: both binaries are now
  rebuilt on the fly by the build/flash scripts (skeletons and build tools are
  in git). `build_fullflash.sh` and `create_fullflash.sh` auto-rebuild
  `rootfs.bin` if missing. Skeleton backup/restore traps simplified.
- **`create_fullflash.sh` aligned**: now prompts for network/radio configuration
  and rebuilds userdata via `build_userdata.sh --jffs2-only` before assembly,
  matching `build_fullflash.sh` behavior.
- **Dropbear 2025.89**: updated from 2025.88.
- **EFR32 build scripts**: all firmware build scripts (bootloader, NCP, RCP,
  OT-RCP, Router) now consistently output exactly two files in `firmware/`:
  `.gbl` (for UART/Xmodem flashing) and `.s37` (for J-Link). Removed `.hex`,
  `.bin`, and intermediate `.s37` variants.

---

## [2.0.1] - 2026-03-17

### Bug fixes
- **DHCP wipes IPv6**: `udhcpc.script` uses `ip -4 addr flush` to preserve IPv6 link-local
- **Thread dataset not persisted**: S70otbr syncs to flash once Thread is up (was daily)
- **`tr: not found` in S70otbr**: replaced with shell parameter expansion
- **`/root` permissions**: fixed to 750 in rootfs skeleton (read-only squashfs)
- **SSH probe timeout**: `SSH_TIMEOUT` env var (default 2s) for slow networks
- **Auto-flash timeout**: 10s → 180s (flash write takes ~2 min)
- **`resolv.conf` overwritten by S15hostname**: removed, handled by S10network
- **Kernel .config warnings**: removed duplicate config entries
- **motd/version sync**: motd now shows the same version and date as `/etc/version`

### Improvements
- **`flash_install_rtl8196e.sh` refactored**: two distinct modes of operation:
  - **First flash** (no argument): gateway must be in bootloader mode, prompts
    for network/radio config, TFTP probe confirms bootloader presence
  - **Upgrade** (`LINUX_IP`): connects via SSH, saves user config (eth0.conf,
    mac_address, radio.conf, passwd, TZ, hostname, dropbear keys, SSH keys,
    Thread credentials), boothold + reboot, then flash. Prompts skipped
  - **`-y` / `--yes` flag**: non-interactive mode for fully automated upgrades
    (firmware >= v2.0.0 with auto-flash support)
- **Firmware detection via `devmem`**: distinguishes custom firmware from Tuya
  (even if Tuya SSH port was changed to 22) by checking `devmem` presence
- **TFTP bootloader probe**: ARP + TFTP PUT distinguishes bootloader from Linux
  running on `BOOT_IP` — prevents false positive detection
- **Auto-flash skip for firmware < v2.0.0**: reads `/etc/version` before boothold
  to skip the 3-minute nc listener on older bootloaders that lack UDP notification
- **Quiet build mode** (`-q`): `build_fullflash.sh` and `build_userdata.sh`
  suppress non-essential output (banners, cvimg details, image sizes) when
  called from `flash_install_rtl8196e.sh`
- **Removed `--boot-ip` parameter**: `BOOT_IP` is env-var only (always 192.168.1.6)
- **Config preservation on reflash**: prompts skipped when config is preserved
- **DNS/domain in eth0.conf**: S10network reads optional `DNS` and `DOMAIN` fields
- **SSH ControlMaster**: single password prompt instead of two
- **SSH auth check**: fail fast on bad password
- **Clean git checkout after flash**: `build_fullflash.sh` and `flash_userdata.sh`
  restore skeleton after build so `git pull` is not blocked
- **`flash_remote.sh` refactored** (renamed from `remote_flash.sh`):
  - `LINUX_IP` is now required (no more hardcoded default)
  - Dual-port SSH probe: port 2333 → Tuya error with redirect to `flash_install_rtl8196e.sh`
  - `devmem` check after SSH: absent = Tuya/v1.0 → same error
  - Boothold via `devmem` directly (no dependency on `boothold` binary)
  - Bootloader wait confirms SSH is down before declaring ready
  - Removed bootloader-already-up path (use individual flash scripts directly)
  - Added `-y`/`--yes` flag, `SSH_TIMEOUT` env var, `StrictHostKeyChecking=no`
  - Renamed to `flash_remote.sh` to match `flash_*.sh` naming convention

---

## [2.0.0] - 2026-03-13

### 30-Backup-Restore
- **`backup_gateway.sh`** (new, at repository root): unified backup script that auto-detects
  gateway state (custom Linux SSH:22, Tuya Linux SSH:2333, or bootloader) and chooses the
  best backup method. Outputs `fullflash.bin` + individual partition files + `backup.log`
  to `backups/YYYYMMDD-HHMM/`. Replaces `backup_mtd_via_ssh.sh` and `backup_rtl8196e.sh`.
- **`restore_gateway.sh`** (new, at repository root): restore a `fullflash.bin` backup to the
  gateway. Verifies 16 MiB size, detects bootloader type (V2 auto-flash vs V1.2/Tuya guided
  LOADADDR + FLW on serial console). Symmetric counterpart to `backup_gateway.sh`.
- Removed `backup_mtd_via_ssh.sh` (superseded by unified script SSH path)
- Removed `backup_rtl8196e.sh` (superseded by unified script bootloader path)

### 31-Bootloader
- **UDP notification after flash** (port 9999): bootloader sends "OK" or "FAIL" to the
  TFTP client after `checkAutoFlashing()` completes, enabling fully automated remote
  flashing without serial console confirmation
- **Raw fullflash auto-flash**: V2.3+ bootloader detects raw 16 MiB images by verifying
  magic bytes at partition offsets (bootloader at 0x0, cs6c at 0x20000, hsqs at 0x200000)
  and writes the entire image to flash — enables fully automatic install via TFTP
- Notification sent before `autoreboot()` so it arrives even for kernel images

### 32-Kernel
- **GPIO 11 / status LED fix**: Ethernet driver no longer clears PIN_MUX_SEL2 bits [4:3]
  that control GPIO 11 (Port B3), fixing the gpio-leds regression introduced in the
  procfs-to-gpio-leds migration
- **Ethernet driver v2.0** — optimized for OTBR/NCP-UART workloads:
  - TX IRQ mitigation: TX_ALL_DONE interrupt disabled, descriptors reclaimed in start_xmit and NAPI poll (eliminates 1 IRQ per TX packet)
  - Ring buffers reduced from 600/500 to 128/128 — saves ~780 KB RAM (3.8% of free memory)
  - TX stop/wake thresholds scaled proportionally (16→4, 64→16)
  - UDP TX throughput +28% vs conditional reclaim approach
  - OTBR use case validated: CoAP/mDNS traffic has 88× headroom vs UART bottleneck
  - 29 hot-path functions placed in 16 KB on-chip I-MEM (SRAM) via `__iram` section
- Syscon/regmap: PIN_MUX_SEL/SEL2 access coordinated via shared regmap (GPIO, UART, Ethernet)
- Interrupt controller: chained_irq_enter/exit, GIMR enabled after handler install, raw_spinlock on GIMR
- Ethernet: IRQ_NONE on spurious, tx_dropped accounting, napi_enable after HW init
- CONFIG_MIPS_L1_CACHE_SHIFT corrected from 5 (32 B) to 4 (16 B) to match actual RLX4181 cache line size
- Timer: bus clock from DT (busclk fixed-clock), max_delta_ticks capped to 28-bit, clk_prepare_enable
- SPI: unaligned access safety (get/put_unaligned), devm_clk_get_optional, double-disable prevention
- UART1: devm_clk_get_optional, dev_warn/err/dbg, PIN_MUX via syscon
- GPIO: spinlock on get_direction, pinmux via syscon/regmap
- LED: replaced custom /proc/led1 driver with standard gpio-leds DT binding (/sys/class/leds/status/)
- DT: syscon on system-controller, busclk fixed-clock, gpio-leds node
- Kconfig: CONFIG_MFD_SYSCON=y, CONFIG_LEDS_GPIO=y, CONFIG_LEDS_TRIGGERS=y
- IPv6 stack integrated into base config (+135 KB kernel, zero overhead when unused)
- CONFIG_FILE_LOCKING=y (required by otbr-agent flock())
- CONFIG_TUN=y (required for wpan0 Thread interface)
- Kconfig size reduction (-298 KB text, -106 KB compressed = -9.2%):
  - Stripped unused subsystems: MTD_CFI/JEDECPROBE, PHYLIB/MDIO, MSDOS/EFI_PARTITION,
    NLS, IKCONFIG, INET_DIAG, IPV6_SIT/TUNNEL, MIPS_FP_SUPPORT, IEEE802154, SHMEM
  - CRC32_SLICEBY8 → SLICEBY4 (-4 KB tables, better D-cache fit)
  - Disabled SYN_COOKIES (unnecessary behind NAT), NETFILTER (incompatible with
    RTL8196E Ethernet driver)
- Kernel size: 1.0 MB → 1.03 MB (net, after IPv6 addition and kconfig stripping)

### 33-Rootfs
- BusyBox: IPv6 support (ping6, traceroute6, ip route)
- Migrated all scripts from ifconfig/route to ip commands
- Removed ifconfig, route, microcom applets (replaced by ip, no longer needed)

### 34-Userdata
- serialgateway: LED control migrated from /proc/led1 to /sys/class/leds/status/brightness
- otbr-agent and ot-ctl binaries in /userdata/usr/bin/
- S70otbr init script: IPv6 forwarding, UART 115200, REST on :8081
- Build script: `ot-br-posix/build_otbr.sh` for cross-compilation

### Flash scripts
- **`flash_install_rtl8196e.sh`** (new): unified firmware installation script —
  builds `fullflash.bin`, auto-detects gateway state (custom Linux → boothold,
  V2 bootloader → auto-flash, old bootloader → guided FLW), handles Tuya and
  custom firmware. Replaces `flash_rtl8196e.sh` as the recommended install method.
- **`build_fullflash.sh`** (new): assembles bootloader + kernel + rootfs + userdata
  into a verified 16 MiB flash image with correct header stripping per partition
- **`flash_remote.sh`** (new): fully automated remote flash via SSH — connects to the
  gateway, sends `boothold`, waits for bootloader, runs the appropriate flash script.
  Supports all 4 components: `./flash_remote.sh <bootloader|kernel|rootfs|userdata>`
- All individual flash scripts (`flash_bootloader.sh`, `flash_kernel.sh`, `flash_rootfs.sh`,
  `flash_userdata.sh`) now wait for bootloader UDP notification ("OK"/"FAIL") instead of
  returning immediately after TFTP upload
- All build scripts (`build_kernel.sh`, `build_rootfs.sh`, `build_userdata.sh`) check
  for gcc before attempting to compile cvimg
- Non-interactive mode via environment variables: `CONFIRM=y` skips "Proceed?" prompt,
  `NET_MODE=static|dhcp` and `RADIO_MODE=zigbee|thread` skip userdata config prompts.
- Removed `flash_rtl8196e.sh` (superseded by `flash_install_rtl8196e.sh` and `flash_remote.sh`)

### Thread Border Router — OTBR on-device
- OpenThread Border Router runs natively on the RTL8196E gateway (no Docker, no PC)
- otbr-agent 0.3.0 (Thread 1.4) cross-compiled for MIPS Lexra, static binary (4.3 MB)
- ot-ctl CLI for Thread network management (57 KB)
- REST API on port 8081 — compatible with Home Assistant OTBR integration
- mDNS/DNS-SD (OpenThread built-in), SRP Advertising Proxy, Border Routing
- Tested: IKEA TIMMERFLOTTE commissioned via HA Companion App, 20 MB RAM free

### Unified Zigbee/Thread distribution
- Single kernel, rootfs, and userdata image for both Zigbee and Thread modes
- `flash_userdata.sh`: new "Radio mode" prompt selects Zigbee or Thread at flash time
- `/userdata/etc/radio.conf` (MODE=otbr) gates init scripts at boot
- S60serialgateway: skips when radio mode is OTBR
- S70otbr: starts only when radio mode is OTBR

### Build fixes (ot-br-posix)
- `-Wno-error=maybe-uninitialized` for GCC 8.5 false positive
- Socket path redirected to /tmp (rootfs is read-only, no /run)
- `--vendor-name` / `--model-name` required by latest ot-br-posix

---

## [1.2.0] - 2026-03-02

### 30-Backup-Restore
- Added custom firmware partition map (4 partitions) alongside the original Lidl/Tuya map
- Added FLR/FLW quick reference table for the custom layout (mtd3 = 12 MiB JFFS2 userdata)

### 32-Kernel
- Updated README: build process now describes zboot (in-tree `arch/mips/boot/compressed/`), corrected image size (~1 MB)
- PIN_MUX_SEL fix: UART1 TX/RX pins correctly muxed in both `rtl8196e-eth` and legacy `rtl819x` drivers — fixes EFR32 communication after Ethernet init
- PIN_MUX_SEL2: nRST clearing preserved for EFR32 reset control

### 33-Rootfs
- Fixed Dropbear pubkey auth by correcting `/root` permissions at startup

### 34-Userdata
- NTP: retry connectivity check in `S20time` for reliable time sync
- Dropbear: unified stop emoji, fixed restart logic
- `flash_userdata.sh`: network configuration (static IP or DHCP) asked at flash time

### Flash scripts (root level)
- New `flash_rtl8196e.sh` at repository root — flashes all RTL8196E partitions in one command
- New `flash_efr32.sh` at repository root — OTA flash of EFR32 via SSH + universal-silabs-flasher
  - Firmware selection menu (bootloader, NCP, RCP, OT-RCP, Z3-Router)
  - SSH retry (3 attempts, ConnectTimeout=10) for unreliable networks
  - Progress bar visible for normal firmware flash
  - Bootloader flash chains application firmware automatically
- Prerequisite checks: tftp-hpa (flash_rtl8196e.sh), python3 + venv (flash_efr32.sh)
- Deleted unused `clean_part1.sh`, `clean_part2.sh`, `clean_part3.sh`

### Documentation
- All EFR32 firmware READMEs (23-Bootloader, 24-NCP, 25-RCP, 26-OT-RCP, 27-Router) updated to reference `flash_efr32.sh`
- Root README rewritten: user-oriented intro, single quick start flow, firmware selection table
- `35-Migration` README rewritten to describe the two root-level flash scripts
- Fixed Z2M port syntax to `tcp://` across all READMEs
- `3-Main-SoC-Realtek-RTL8196E/README.md`: clarified flash script paths (root vs subdirectory)

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
  `set -euo pipefail`, helper functions, background UDP ARP trigger with proper
  cleanup, `ip neigh del` flush before probing, `timeout 15` on tftp,
  `TRIES`/`PORT`/`SLEEP_BETWEEN` env-var overrides, clean error reporting

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
- `boothold` script installed in `usr/bin/`: one-command reboot-to-bootloader
  from Linux SSH, wraps `devmem 0x003FFFFC 32 0x484F4C44 && reboot` with a root check
- `flash_userdata.sh`: asks for network configuration (static IP or DHCP) before
  flashing; generates `skeleton/etc/eth0.conf` temporarily, rebuilds JFFS2, then
  flashes — `eth0.conf` is removed after flash (trap EXIT), skeleton stays clean

### Flash scripts
- Fixed invalid `-timeout` tftp flag in all scripts — replaced by `timeout N tftp` wrapper
- `flash_rtl8196e.sh`: fixed `set -e` silent exit, improved UX messages
- `flash_rtl8196e.sh`: optional FLR full flash backup before flashing, saved as `YYMMJJ-HH.MM-Gw-Backup.bin`
- `flash_rtl8196e.sh`: asks for network configuration (static IP or DHCP) before
  flashing, rebuilds userdata with the chosen config

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
