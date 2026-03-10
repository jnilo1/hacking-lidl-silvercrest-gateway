/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __ASM_MACH_REALTEK_IMEM_H
#define __ASM_MACH_REALTEK_IMEM_H

/*
 * On-chip I-MEM (instruction SRAM) placement macros for RTL8196E.
 *
 * The RTL8196E has 16 KB of on-chip instruction SRAM accessible via the
 * Lexra COP3 Instruction Window.  Functions annotated with __iram are
 * placed in the .iram linker section, which is copied to on-chip SRAM
 * at boot by _imem_dmem_init().  Subsequent instruction fetches from
 * these functions are served at zero wait-state (1 cycle), bypassing
 * the I-cache entirely.
 *
 * Usage:
 *   static __iram void hot_function(void) { ... }
 *
 * Budget: 16 KB total.  Use only for performance-critical hot-path code
 * (IRQ dispatch, NAPI poll, TX submit, DMA cache ops).
 */

#ifdef CONFIG_RTL8196E_IMEM
#define __iram		__attribute__((section(".iram")))
#define __iram_gen	__attribute__((section(".iram-gen")))
#define __iram_fwd	__attribute__((section(".iram-fwd")))
#define __dram		__attribute__((section(".dram")))
#else
#define __iram
#define __iram_gen
#define __iram_fwd
#define __dram
#endif

#endif /* __ASM_MACH_REALTEK_IMEM_H */
