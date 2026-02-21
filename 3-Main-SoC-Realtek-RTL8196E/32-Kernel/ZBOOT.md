# Kernel packaging: zboot (arch/mips/boot/compressed/) vs lzma-loader

**Branch:** `exp/zboot-rtl8196e`
**Date:** February 2026
**Status:** Validated — boots on RTL8196E hardware

---

## Background

The original kernel packaging pipeline relied on an external `lzma-loader`: a small
standalone MIPS binary from the Realtek SDK that decompresses the kernel at boot time.
This loader self-relocates from its load address (0x80c00000) to its link address
(0x81000000), decompresses the LZMA kernel to 0x80000000, then jumps to it.

The `lzma-loader` was compiled with the Lexra toolchain and depended on two external
tools from the Realtek SDK 4.65:

- `lzma` — the compression tool (LZMA SDK 4.65 CLI)
- `lzma-loader/` — the pre-built decompressor binary

This experiment replaces both with the Linux in-tree decompressor:
`arch/mips/boot/compressed/vmlinuz`.

---

## Pipeline comparison

### Before — lzma-loader

```
vmlinux
  │  objcopy (-O binary)
  ▼
vmlinux.bin
  │  lzma e (SDK 4.65, -lc1 -lp2 -pb2)
  ▼
vmlinux.bin.lzma
  │  make -C lzma-loader/   (Lexra cross-compiled decompressor stub)
  ▼
loader.bin                  (decompressor + compressed kernel, linked at 0x81000000)
  │  cvimg -e 0x80c00000
  ▼
kernel.img
```

### After — zboot

```
vmlinux
  │  make (SYS_SUPPORTS_ZBOOT + KERNEL_LZMA trigger vmlinuz target automatically)
  │    → arch/mips/boot/compressed/vmlinux.bin   (objcopy)
  │    → arch/mips/boot/compressed/vmlinux.bin.z (LZMA, in-tree)
  │    → arch/mips/boot/compressed/piggy.o       (compressed payload as object)
  │    → vmlinuz (ELF: head.S + decompress.c + piggy.o)
  ▼
vmlinuz                     (decompressor + compressed kernel, load addr from ELF)
  │  objcopy (-O binary)
  ▼
vmlinuz.bin
  │  cvimg -e <entry from readelf>
  ▼
kernel-rtl8196e-zboot.img
```

---

## Kconfig change

One line added to `files/arch/mips/realtek/Kconfig`, inside `config SOC_RTL8196E`:

```kconfig
select SYS_SUPPORTS_ZBOOT
```

Effect: `arch/mips/Makefile` line 86 adds `vmlinuz` to the default build targets:

```makefile
all-$(CONFIG_SYS_SUPPORTS_ZBOOT) += vmlinuz
```

`SYS_SUPPORTS_ZBOOT` only selects `HAVE_KERNEL_*` symbols (makes compression options
visible in menuconfig). It does not activate any compression by itself — no impact on
existing builds (`build_kernel.sh`, `build_rtl8196e_eth.sh`).

`CONFIG_KERNEL_LZMA=y` is injected by `build_rtl8196e_zboot.sh` to match the
compression algorithm used by the legacy lzma-loader, enabling direct comparison.

---

## Load address calculation

`calc_vmlinuz_load_addr` (in `arch/mips/boot/compressed/`) computes:

```
vmlinuz_load_addr = 0x80000000 + sizeof(vmlinux.bin) + roundup_to_64K
```

For this kernel (~4.2 MB uncompressed): **0x80440000**

This guarantees no overlap between:
- `[0x80000000 … vmlinux_size]` — decompressed kernel being written
- `[0x80440000 … ]` — vmlinuz (decompressor + LZMA payload + 4 MB heap + stack)

The entry address is read at package time from the vmlinuz ELF header:

```bash
${CROSS_COMPILE}readelf -h vmlinuz | awk '/Entry point address/ {print $NF}'
```

Result is normalised to 32 bits (masks off MIPS sign-extension `0xffffffff8xxxxxxx`).

Note: `files/arch/mips/realtek/Platform` already sets `load-y = 0xffffffff80000000`
which `calc_vmlinuz_load_addr` uses as `LINKER_LOAD_ADDRESS`. No changes needed there.

---

## Image sizes (measured on identical source)

| Image | Size | Notes |
|-------|------|-------|
| `kernel.img` (legacy rtl819x + lzma-loader) | 1 028 096 B (1004 KiB) | reference |
| `kernel-rtl8196e-eth.img` (eth + lzma-loader) | 1 019 904 B (996 KiB) | −8 KiB |
| `kernel-rtl8196e-zboot.img` (eth + zboot) | 1 028 096 B (1004 KiB) | = reference |

The zboot image is 8 KiB larger than the lzma-loader eth build. Both use LZMA with the
same parameters — the difference comes from the size difference between the in-tree
`head.S`/`decompress.c` decompressor and the external `lzma-loader` binary. No
significant size advantage either way.

---

## Dependency analysis

| Tool | Bootloader build | Kernel (legacy) | Kernel (zboot) |
|------|-----------------|-----------------|----------------|
| `lzma` binary (SDK 4.65) | **yes** — compresses stage-2 | yes | **no** |
| `lzma-loader` binary | no | yes | **no** |
| `LzmaDecode.c` (embedded in btcode) | yes (runtime) | no | no |
| `cvimg` | yes | yes | yes |

The `lzma` binary from realtek-tools is still required for the bootloader build
(`31-Bootloader/btcode/Makefile` compresses the stage-2 binary with it). It is not
needed by `build_rtl8196e_zboot.sh`.

The bootloader uses its own embedded LZMA decoder (`LzmaDecode.c` in `btcode/`),
not the `lzma-loader` binary. These are two independent components that happen to
implement the same algorithm.

---

## Boot test result

Flashed on 2026-02-21, RTL8196E gateway (Lidl Silvercrest Zigbee):

```
Linux version 5.10.246-rtl8196e-zboot
vmlinuz entry: 0x80440000
Memory: 27968K/32768K available
```

Full boot, SSH accessible, all init scripts completed normally.

---

## Build script

`build_rtl8196e_zboot.sh` — derived from `build_rtl8196e_eth.sh`.

Key differences:
- No `lzma` or `lzma-loader` dependency check
- `CONFIG_KERNEL_LZMA=y` injected in `.config`
- Build tree: `linux-5.10.246-rtl8196e-zboot/`
- `LOCALVERSION="-rtl8196e-zboot"`
- Packaging reads entry point from ELF, converts vmlinuz to flat binary, calls cvimg

Usage identical to other build scripts:
```bash
./build_rtl8196e_zboot.sh              # full build + package
./build_rtl8196e_zboot.sh clean        # rebuild from scratch
./build_rtl8196e_zboot.sh menuconfig
```
