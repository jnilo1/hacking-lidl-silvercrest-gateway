/* SPDX-License-Identifier: GPL-2.0 */
/*
 * imem.S — On-chip I-MEM/D-MEM initialisation for RTL8196E (Lexra RLX4181).
 *
 * The RTL8196E SoC contains two tightly-coupled on-chip SRAMs accessed
 * via the Lexra COP3 coprocessor:
 *
 *   I-MEM  16 KB  physical 0x00C00000–0x00C03FFF  (instruction SRAM)
 *   D-MEM   8 KB  physical 0x00C04000–0x00C05FFF  (data SRAM)
 *
 * _imem_dmem_init() programs the COP3 "Instruction Window" (IW) and
 * "Data Window" (DW) registers to point at the .iram/.dram sections,
 * then triggers IRAM Fill so the hardware caches those ranges in on-chip
 * SRAM.  Subsequent instruction/data fetches from those physical addresses
 * are served at zero wait-state instead of going to external SDRAM.
 *
 * Called once during early boot from plat_mem_setup() in setup.c.
 *
 * COP3 register assignments (RTL8196E):
 *   $0  IW base   (physical address of .iram section, 16 KB aligned)
 *   $1  IW top    (base + 16 KB − 1)
 *   $2  IW base1  (not used: single bank on RTL8196E)
 *   $3  IW top1   (not used)
 *   $4  DW base   (physical address of .dram section, 8 KB aligned)
 *   $5  DW top    (base + 8 KB − 1)
 *   $6  DW base1  (not used)
 *   $7  DW top1   (not used)
 *
 * COP0 $20 (CCTL) bit definitions used here:
 *   bit  1  Invalidate D-cache
 *   bit  4  IRAM Fill  (copy SDRAM range into on-chip SRAM)
 *   bit  5  IRAM Off   (invalidate SRAM)
 *   bit  9  Invalidate I-cache
 *   bit 10  DMEM On
 *
 * Register usage: $8 ($t0), $9 ($t1) — caller-saved, no push/pop needed.
 */

#include <asm/asmmacro.h>

	.set	nomips16		/* this file is MIPS32; called from MIPS32 */
	.text

LEAF(_imem_dmem_init)
	.set	noreorder

	/* ------------------------------------------------------------------
	 * 1. Enable COP3 access in the MIPS Status register (COP0 $12).
	 *    The Lexra COP3 coprocessor implements the SRAM window control.
	 * ------------------------------------------------------------------ */
	mfc0	$8, $12
	nop
	nop
	or	$8, 0x80000000		/* set CU3 bit */
	mtc0	$8, $12
	nop
	nop

	/* ------------------------------------------------------------------
	 * 2. Invalidate the IRAM (0 → 1 transition on the IRAM Off bit).
	 * ------------------------------------------------------------------ */
	mtc0	$0, $20			/* CCTL = 0 */
	nop
	nop
	li	$8, 0x00000020		/* bit 5: IRAM Off */
	mtc0	$8, $20
	nop
	nop

	/* ------------------------------------------------------------------
	 * 3. Invalidate I-cache and D-cache (0 → 1 transition).
	 * ------------------------------------------------------------------ */
	mtc0	$0, $20			/* CCTL = 0 */
	nop
	nop
	li	$8, 0x00000202		/* bit 9: inv I-cache, bit 1: inv D-cache */
	mtc0	$8, $20
	nop
	nop

	/* ------------------------------------------------------------------
	 * 4. Program I-MEM window in COP3.
	 *
	 *    __iram is the virtual address of the .iram section in SDRAM.
	 *    Strip KSEG0/KSEG1 bits → physical address (bits [27:14]).
	 *    The hardware will cache this 16 KB SDRAM range in on-chip SRAM.
	 * ------------------------------------------------------------------ */
	la	$8, __iram
	la	$9, 0x0fffc000		/* mask to 16 KB-aligned physical bits */
	and	$8, $8, $9
	mtc3	$8, $0			/* COP3 $0 = IW base */
	nop
	nop
	addiu	$8, $8, 0x3fff		/* base + 16 KB − 1 */
	mtc3	$8, $1			/* COP3 $1 = IW top */
	nop
	nop

	/* ------------------------------------------------------------------
	 * 5. IRAM Fill: hardware caches the IW range from SDRAM into SRAM.
	 *    After this, instruction fetches from __iram..__iram+16KB
	 *    are served at zero wait-state.
	 * ------------------------------------------------------------------ */
	mtc0	$0, $20			/* CCTL = 0 */
	nop
	nop
	li	$8, 0x00000010		/* bit 4: IRAM Fill */
	mtc0	$8, $20
	nop
	nop

	/* ------------------------------------------------------------------
	 * 6. Program D-MEM window in COP3.
	 *
	 *    Skip if __dram_start == __dram_end (no .dram annotations active).
	 *    For the initial PoC, D-MEM is intentionally unused.
	 * ------------------------------------------------------------------ */
	la	$8, __dram_start
	la	$9, __dram_end
	beq	$8, $9, skip_dram
	nop
	la	$9, 0x0fffe000		/* mask to 8 KB-aligned physical bits */
	and	$8, $8, $9
	mtc3	$8, $4			/* COP3 $4 = DW base */
	nop
	nop
	addiu	$8, $8, 0x1fff		/* base + 8 KB − 1 */
	mtc3	$8, $5			/* COP3 $5 = DW top */
	nop
	nop

skip_dram:
	/* ------------------------------------------------------------------
	 * 7. Clear CCTL — re-enables normal cache operation.
	 *    The COP3 window registers remain active; the on-chip SRAM now
	 *    serves instruction fetches from the programmed ranges.
	 * ------------------------------------------------------------------ */
	mtc0	$0, $20			/* CCTL = 0 */
	nop
	nop

	.set	reorder
	j	$31			/* return to caller */
END(_imem_dmem_init)
