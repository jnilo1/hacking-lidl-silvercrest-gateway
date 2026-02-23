# Kernel compression — from lzma-loader to zboot

## Background

The kernel must be compressed to fit in the gateway flash (1 MB available for the
kernel image). Decompression happens at boot time, before the kernel takes control.

Two approaches have been used successively.

---

## Old approach — lzma-loader (Realtek SDK)

The original pipeline, inherited from the Realtek 2.6.30 SDK, relied on an external
binary: `lzma-loader`, a small MIPS stub compiled separately with the Lexra toolchain.

```
vmlinux
  │  objcopy (-O binary)
  ▼
vmlinux.bin
  │  lzma e  (Realtek SDK 4.65 tool, options -lc1 -lp2 -pb2)
  ▼
vmlinux.bin.lzma
  │  make -C lzma-loader/   (Lexra cross-compiled decompressor stub)
  ▼
loader.bin                  (decompressor + compressed kernel, linked at 0x81000000)
  │  cvimg -e 0x80c00000
  ▼
kernel.img
```

**External dependencies**: `lzma` binary (SDK 4.65) + `lzma-loader/` directory.

At boot, the loader self-relocates from `0x80c00000` to `0x81000000`, decompresses
the kernel to `0x80000000`, then jumps to it.

---

## New approach — zboot (in-tree)

Linux 5.10 ships its own MIPS decompressor: `arch/mips/boot/compressed/`. Enabling
`SYS_SUPPORTS_ZBOOT` in the platform Kconfig is enough for the `vmlinuz` target to
be added automatically to the build.

```
vmlinux
  │  make  (SYS_SUPPORTS_ZBOOT + KERNEL_LZMA → vmlinuz target automatic)
  │    arch/mips/boot/compressed/vmlinux.bin    (objcopy)
  │    arch/mips/boot/compressed/vmlinux.bin.z  (LZMA, in-tree)
  │    arch/mips/boot/compressed/piggy.o        (compressed payload as object)
  │    vmlinuz  (ELF: head.S + decompress.c + piggy.o)
  ▼
vmlinuz                     (decompressor + compressed kernel)
  │  objcopy (-O binary)
  ▼
vmlinuz.bin
  │  cvimg -e <entry point read from ELF>
  ▼
kernel.img
```

**External dependencies**: `cvimg` only (unchanged).

The entry point is read dynamically from the ELF header at packaging time:

```bash
${CROSS_COMPILE}readelf -h vmlinuz | awk '/Entry point address/ {print $NF}'
```

The value is normalised to 32 bits (masks off MIPS sign-extension
`0xffffffff8xxxxxxx → 0x8xxxxxxx`).

---

## Kconfig change

One line added to `files/arch/mips/realtek/Kconfig`, inside `config SOC_RTL8196E`:

```kconfig
select SYS_SUPPORTS_ZBOOT
```

Effect in `arch/mips/Makefile`:

```makefile
all-$(CONFIG_SYS_SUPPORTS_ZBOOT) += vmlinuz
```

`CONFIG_KERNEL_LZMA=y` is injected by `build_kernel.sh` to use LZMA, matching the
algorithm used by the legacy lzma-loader.

---

## Load address calculation

`calc_vmlinuz_load_addr` (in `arch/mips/boot/compressed/`) computes:

```
vmlinuz_load_addr = 0x80000000 + sizeof(vmlinux.bin) + roundup_to_64K
```

For this kernel (~4.2 MB uncompressed): **0x80440000**

This guarantees no overlap between:
- `[0x80000000 … vmlinux_size]` — decompressed kernel being written
- `[0x80440000 … ]` — vmlinuz (decompressor + payload + heap + stack)

`files/arch/mips/realtek/Platform` already sets `load-y = 0xffffffff80000000`,
used by `calc_vmlinuz_load_addr` as `LINKER_LOAD_ADDRESS` — no changes needed there.

---

## Image sizes

| Image | Size | Notes |
|-------|------|-------|
| `kernel-legacy.img` (rtl819x + lzma-loader) | 1 004 KiB | reference |
| `kernel.img` (rtl8196e-eth + zboot)          | 1 004 KiB | identical |

Both approaches produce images of equivalent size. The in-tree zboot decompressor
(`head.S` + `decompress.c`) is slightly larger than the external `lzma-loader`, but
the difference is absorbed by the alignment rounding.
