# Linux 6.18 Kernel for RTL8196E

This directory contains everything needed to build a modern Linux kernel for the Realtek RTL8196E gateway.

**Current version**: [Linux 6.18.35](https://cdn.kernel.org/pub/linux/kernel/v6.x/) — tracks the stable 6.18.x LTS family (6.18.0 was released 2025-12-01; the exact point release pinned in `build_kernel.sh` is bumped periodically to pick up CVE and bug fixes).

## Why Linux 6.18?

Linux 6.18 is an **[LTS](https://www.kernel.org/category/releases.html)** release, maintained upstream for several years. It brings a modern kernel surface to the gateway while remaining practical to cross-compile against the project's Lexra MIPS toolchain. Compared to legacy 3.10 / 4.14 / 5.10 lines, 6.18 gives us current driver APIs, recent security hardening defaults, and the in-kernel UART↔TCP bridge (`rtl8196e-uart-bridge`) used for the Zigbee radio path.

The `build_kernel.sh` script pins a specific 6.18.x stable release via `KERNEL_VERSION` and applies our local `patches-6.18/` on top. Bumping to a newer point release is a one-line edit — the patches, overlay and config are keyed on the 6.18 family, not the point version.

## The Porting Challenge

Porting to modern Linux on the RTL8196E (Lexra RLX4181, MIPS-I class) was a **significant undertaking**:

| Challenge | Description |
|-----------|-------------|
| **Ethernet driver rewrite** | The Realtek SDK driver used obsolete APIs. It was completely rewritten to comply with modern kernel networking standards (NAPI, phylib, devicetree). |
| **Lexra CPU support** | The Lexra MIPS variant lacks `ll/sc` in hardware. Required kernel-side emulation (`simulate_llsc`) plus atomics/memory-barrier patches. |
| **Platform code cleanup** | Realtek SDK platform code was heavily tied to old kernel internals. Board support was rewritten around modern devicetree and platform drivers. |
| **Build system changes** | Successive Kbuild generations moved enough code around that the overlay/patch set had to be regenerated against 6.x. |

The result is a clean, maintainable kernel that can be updated to newer 6.18.x point releases with minimal friction.

## Contents

| Directory/File | Description |
|----------------|-------------|
| [`patches-6.18/`](https://github.com/jnilo1/rtl8196e-gateway/tree/main/3-Main-SoC-Realtek-RTL8196E/32-Kernel/patches-6.18) | Patches to apply on vanilla Linux 6.18 |
| [`files-6.18/`](https://github.com/jnilo1/rtl8196e-gateway/tree/main/3-Main-SoC-Realtek-RTL8196E/32-Kernel/files-6.18) | New files to add to the kernel tree (Realtek platform support, custom drivers) |
| [`config-6.18-realtek.txt`](https://github.com/jnilo1/rtl8196e-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/32-Kernel/config-6.18-realtek.txt) | Kernel configuration |
| [`build_kernel.sh`](https://github.com/jnilo1/rtl8196e-gateway/blob/main/3-Main-SoC-Realtek-RTL8196E/32-Kernel/build_kernel.sh) | Build script |

## Building

```bash
./build_kernel.sh [clean|menuconfig|olddefconfig|vmlinux]
```

### Options

| Option | Description |
|--------|-------------|
| *(none)* | Normal build: download sources if needed, apply patches, compile, package |
| `clean` | Remove kernel source directory and rebuild from scratch |
| `menuconfig` | Run kernel menuconfig interactively |
| `olddefconfig` | Update `.config` non-interactively against the current Kconfig |
| `vmlinux` | Build `vmlinux` only (skip packaging) |

### Board selection

The image embeds a single device tree, selected at build time with the
`BOARD` environment variable (default: `lidl`, the Lidl Silvercrest
gateway):

```bash
BOARD=lidl ./build_kernel.sh        # default — builds rtl8196e.dtb
```

Porting to another RTL8196E board means adding an `rtl8196e-<board>.dts`,
one Kconfig entry and one Makefile line — the recipe is documented in
`files-6.18/arch/mips/boot/dts/realtek/Makefile` and in the devicetree
Kconfig choice (`files-6.18/arch/mips/realtek/Kconfig`).

### Build process

The script will:
1. Download Linux 6.18.x source (if not present)
2. Apply all patches from `patches-6.18/`
3. Overlay Realtek platform files from `files-6.18/`
4. Compile the kernel
5. Package the compressed kernel image (zboot) into `kernel-6.18.img`, ready to flash

**Requirements**: [Toolchain](../../1-Build-Environment/README.md) must be built first.

## Output

- `kernel-6.18.img` — Flashable kernel image with Realtek header (~1.2 MB)

## Technical Details

### Build process (zboot)

The kernel uses the in-tree `arch/mips/boot/compressed/` (zboot) decompressor — no external LZMA tool or loader is needed.

1. Compile kernel → `vmlinux`
2. zboot compresses the kernel with LZMA and prepends a small decompressor → `vmlinuz` (ELF)
3. Strip to raw binary → `vmlinuz.bin`
4. Add Realtek header (cvimg) → `kernel-6.18.img`

### Key patches

- Lexra MIPS support (kernel-side `ll/sc`/`sync` emulation, atomics, memory barriers)
- RTL8196E SoC and board support (devicetree, platform drivers)
- SPI flash driver, GPIO bank, LEDs (gpio-leds + PWM brightness modes)
- From-scratch Ethernet driver (`rtl8196e-eth`) targeting modern APIs
- In-kernel UART↔TCP bridge (`rtl8196e-uart-bridge`) for the Zigbee radio path
- 8250-compatible UART (`8250_rtl819x`), hardware timer clocksource (`timer-rtl819x`)

## 🙏 Credits

The kernel platform support traces back to early work by [Gaspare Bruno](https://github.com/ggbruno) on the Realtek target:
- [ggbruno/openwrt — Realtek branch](https://github.com/ggbruno/openwrt/tree/Realtek/target/linux/realtek)

Those patches (originally for Linux 4.14) were heavily reworked for 5.10, then regenerated against 6.18 as part of the v3.0 rebase.

## 🔗 References

- [Linux 6.18](https://kernel.org/)
- [Lexra processors](https://en.wikipedia.org/wiki/Lexra)
