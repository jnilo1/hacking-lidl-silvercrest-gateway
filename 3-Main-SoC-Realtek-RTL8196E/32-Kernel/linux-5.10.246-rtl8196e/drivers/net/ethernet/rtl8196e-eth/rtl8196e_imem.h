/* SPDX-License-Identifier: GPL-2.0 */
/*
 * rtl8196e_imem.h - Placement macros for RTL8196E on-chip I-MEM/D-MEM.
 *
 * Two independent attributes are provided:
 *
 *   __MIPS16     — always active: instructs GCC to compile the annotated
 *                  function using the MIPS16e ISA extension (16-bit compressed
 *                  instructions).  Reduces per-function code size by ~30%,
 *                  improving I-cache utilisation even without I-MEM.
 *
 *   __iram_gen   — when CONFIG_RTL8196E_IMEM=y: places the function in
 *                  section ".iram-gen" (essential hot path).
 *
 *   __iram_fwd   — when CONFIG_RTL8196E_IMEM=y: places the function in
 *                  section ".iram-fwd" (packet forwarding / driver hot path).
 *
 * Usage pattern (mirrors Realtek 2.6.30 __MIPS16 __IRAM_FWD):
 *
 *   __MIPS16 __iram_fwd int my_hot_function(...)
 *   {
 *       ...
 *   }
 *
 * When CONFIG_RTL8196E_IMEM is not set, __iram_gen and __iram_fwd expand
 * to empty, so the function stays in normal .text.  __MIPS16 is always
 * applied regardless, as it is unconditionally beneficial on this CPU.
 */
#ifndef RTL8196E_IMEM_H
#define RTL8196E_IMEM_H

/*
 * __MIPS16: compile this function with MIPS16e (16-bit compressed ISA).
 *
 * Safe to use unconditionally on Lexra RLX4181; cpu_has_mips16 = 1 is
 * declared in arch/mips/include/asm/mach-realtek/cpu-feature-overrides.h.
 *
 * GCC emits an inter-ISA thunk automatically when MIPS32 callers invoke
 * a MIPS16e function, so no manual trampolines are needed.
 */
#define __MIPS16  __attribute__((mips16))

/*
 * __iram_gen / __iram_fwd: I-MEM section placement.
 *
 * When enabled, the linker places annotated functions in the .iram output
 * section (see arch/mips/kernel/vmlinux.lds.S).  _imem_dmem_init() fills
 * the on-chip SRAM from that SDRAM range at boot, so subsequent fetches
 * are zero wait-state.
 *
 * Maximum budget for .iram: 16 KB.  Estimated footprint with only
 * rtl8196e_ring_rx_poll annotated: ~0.5 KB (MIPS16e).
 */
#ifdef CONFIG_RTL8196E_IMEM
# define __iram_gen  __attribute__((section(".iram-gen")))
# define __iram_fwd  __attribute__((section(".iram-fwd")))
#else
# define __iram_gen  /* no-op: function stays in .text */
# define __iram_fwd  /* no-op: function stays in .text */
#endif

#endif /* RTL8196E_IMEM_H */
