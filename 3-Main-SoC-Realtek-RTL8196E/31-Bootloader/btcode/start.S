#include <asm/asm.h>
#include <asm/regdef.h>
#include <asm/mipsregs.h>
#include "start.h"

/*
 * Stage-1 reset vector for RTL8196E.
 * Initializes UART + DDR, flushes caches, copies the piggy payload to RAM,
 * then jumps to BOOT_ADDR.
 */

	.text
	.set noreorder
	.globl __start

/*---------------------------------------------------------------------------*/
/* Reset vector entry (runs from SPI flash)                                  */
/*---------------------------------------------------------------------------*/
__start:
	j	load_boot
	nop
	nop
	nop

/*---------------------------------------------------------------------------*/
/* Main stage-1 path: SoC patch, UART banner, DDR init/calibration, copy,   */
/* jump to stage-1.5 in RAM.                                                */
/*---------------------------------------------------------------------------*/
load_boot:
	/* Clear status register */
	move	t0, zero
	mtc0	t0, $12
	nop

	/* SoC patch for RTL8196E */
	REG32_R(SYS_ID_REG, t6)
	IF_NEQ(t6, SYS_ID_RTL8196E, notdiv)
	REG32_ANDOR(SYS_PATCH_REG, 0xffffffff, SYS_PATCH_BIT)	/* 8196E patch */

notdiv:
	nop

	/*-------------------------------------------------------------------------*/
	/* UART initialization and banner display                                 */
	/*-------------------------------------------------------------------------*/
lab_uart_show:
	jal	uart_show		/* Print boot message */
	nop
	nop

	/* Configure power management */
	REG32_W(MPMR_REG, MPMR_DEFAULT)		/* 3.1 MPMR, default power-saving */
	nop
	REG32_W(MPMR_REG, MPMR_PDN)		/* 3.2 MPMR, enable power down */
	nop

	/* DDR and clock configuration */
	REG32_W(DDCR_REG, DDCR_INIT_VAL)	/* DDR calibration register init */
	nop
	REG32_W(CLKMGR_REG, CLKMGR_DEFAULT)	/* Clock manager, value from start.h */
	nop

	/* Check system status and configure for DDR1 if needed */
	REG32_R(SYS_STATUS_REG, t6)
	nop
	IF_NEQ(t6, 0x7, rtl_8196E_four)
	nop
	IF_NEQ(t6, 0x4, rtl_8196E_four)
	nop
	REG32_W(CLKMGR_REG, CLKMGR_MCM_DDR1)	/* RTL8196E MCM DDR1 package */
	nop

rtl_8196E_four:
	/* DDR timing configuration */
	REG32_W(DDR_CFG_REG, BOARD_DDR_REG_1008)	/* per-board, boards/<board>/board.h */
	/* Set DTR by hw_strap ck_m2x_freq_sel */
	REG32_W(DDR_TIMING_REG, BOARD_DDR_REG_1004)
	nop
	nop

	/* Strap, clock frequency and OCP configuration */
	REG32_ANDOR(STRAP_REG, ~STRAP_MASK, STRAP_OR)
	nop
	REG32_ANDOR(CLK_FREQ_REG, ~CLK_FREQ_MASK, CLK_FREQ_OR)	/* Freq = 2M */
	nop
	REG32_ANDOR(OCP_REG, ~OCP_MASK, OCP_OR)			/* Max OCP */
	nop

	/*-------------------------------------------------------------------------*/
	/* DDR auto-calibration                                                    */
	/*-------------------------------------------------------------------------*/
lab_ddr_cali:
	jal	DDR_Auto_Calibration
	nop

	/* Flush all caches */
	mtc0	zero, $20		/* Cache control register: reset */
	nop
	li	t0, 0x3
	mtc0	t0, $20			/* Cache control register: enable flush */
	nop
	mtc0	zero, $20		/* Cache control register: reset */
	nop
	nop

	/*-------------------------------------------------------------------------*/
	/* Copy stage-1.5 payload from flash to RAM                               */
	/*-------------------------------------------------------------------------*/
	la	k0, __boot_start
	la	k1, (__boot_end + 4)
	la	t1, BOOT_ADDR

copy_boot_loop:
	lw	t0, 0(k0)
	nop
	sw	t0, 0(t1)		/* *(t1) = *(t0); t1 += 4; t0 += 4 */
	nop
	addu	t1, 4
	addu	k0, 4
	bne	k1, k0, copy_boot_loop
	nop

	/* Jump to stage-1.5 in RAM */
	li	k0, BOOT_ADDR
	jr	k0
	nop

/*---------------------------------------------------------------------------*/
/* DDR_Auto_Calibration - Calibrate DDR DQS delays                          */
/*---------------------------------------------------------------------------*/
	EXPORT(DDR_Auto_Calibration)

DDR_Auto_Calibration:
	/* Initialize registers */
	li	t3, DDR_TEST_ADDR		/* (t3) = DRAM test address */
	li	v0, DDR_TEST_PATTERN		/* (v0) = DRAM test pattern */
	li	t2, DDCR_REG			/* (t2) = DDR calibration register */
	li	t1, DDCR_SW_BASE		/* Digital delay line base (SW) */
	
	li	a2, 0				/* L0 = 0 (DQS0 left boundary) */
	li	t6, 33				/* R0 = 33 (DQS0 right boundary) */
	li	t5, 0				/* L1 = 0 (DQS1 left boundary) */
	li	t7, 33				/* R1 = 33 (DQS1 right boundary) */

	/* Write test pattern to DRAM */
	sw	v0, 0(t3)			/* DRAM_ADDR = 0x5a5aa5a5 */

	li	v1, 1				/* v1 = 1, DQS0 calibration, 1..32 */
	move	a0, t1				/* (a0) = DDCR_Pattern */
	li	t4, DDR_TEST_MASK		/* (t4) = mask */
	li	t0, DDR_TEST_EXPECT		/* (t0) = expected value */
	move	a3, t4
	move	a1, t0
	addiu	v0, v1, -1

	/*-----------------------------------------------------------------------*/
	/* DQS0 calibration loop - find left and right boundaries               */
	/*-----------------------------------------------------------------------*/
lab_loop_DQS0:
	sll	v0, v1, 25			/* tmp = (DQS0 << DQS0_offset) */
	or	v0, a0, v0			/* tmp = DDCR_Pattern | tmp */
	bnez	a2, lab_notzero			/* if (L0 == 0), continue */
	sw	v0, 0(t2)			/* DDCR = tmp */

lab_zero:					/* L0 not yet found */
	lw	v0, 0(t3)			/* Read test pattern */
	nop
	and	v0, v0, t4			/* val = val & mask */
	bne	v0, t0, lab_next_DQS0		/* Compare val with expected */
	nop
	j	lab_next_DQS0
	move	a2, v1				/* Save to L0 */

lab_notzero:					/* L0 already found, find R0 */
	lw	v0, 0(t3)
	nop
	and	v0, v0, a3			/* val = val & mask */
	bne	v0, a1, lab_end_DQS0		/* Compare val with expected */
	nop

lab_next_DQS0:
	addiu	v1, v1, 1			/* v1++ , DQS0++ */
	sltiu	v0, v1, 33
	bnez	v0, lab_loop_DQS0

lab_end_DQS0:
	addiu	t8, v1, -1			/* Saved R0's value to t8 */
	li	v0, DDCR_SW_MASK		/* Digital (SW) mask */
	and	t1, t1, v0
	add	v0, t8, a2			/* v0 = L0 + R0 */
	srl	v0, v0, 0x1			/* c0 = (L0 + R0) / 2 */

/*-----------------------------------------------------------------------*/
/* DDCR_SHIFT_EXIT - Apply DQS0 and DQS1 delay values                   */
/*-----------------------------------------------------------------------*/
DDCR_SHIFT_EXIT:
	move	t9, v0				/* Save for DQS1 */
	sll	v0, v0, 25			/* DQS0 Offset */
	sll	t9, t9, 20			/* DQS1 Offset */
	or	t1, t1, v0
	or	t1, t1, t9			/* Combine DQS0 and DQS1 offsets */
	sw	t1, 0(t2)			/* Set DDCR DQS0/DQS1 */
	nop
	nop
	j	DDR_Calibration_end
	nop

DDR_Calibration_end:
	jr	ra
	nop

/*---------------------------------------------------------------------------*/
/* uart_show - Initialize UART0 and print boot banner                       */
/*---------------------------------------------------------------------------*/
	EXPORT(uart_show)

uart_show:
	/*-----------------------------------------------------------------------*/
	/* UART initialization                                                   */
	/*-----------------------------------------------------------------------*/
	REG32_W(UART_LCR, 0x03000000)		/* 8-bit, 1 stop, no parity */
	REG32_W(UART_FCR, 0xc7000000)		/* Enable FIFO, clear, trigger level */
	REG32_W(UART_IER, 0x00000000)		/* Disable interrupts */

	/* Calculate baud rate divisor */
	dl  = (SYS_CLK_RATE / 16) / BAUD_RATE - 1
	dll = dl & 0xff
	dlm = dl / 0x100

	REG32_W(UART_LCR, 0x83000000)		/* Enable divisor latch access */
	REG32_W(UART_DLL, dll * 0x1000000)	/* Set DLL */
	REG32_W(UART_DLM, dlm * 0x1000000)	/* Set DLM */
	REG32_W(UART_LCR, 0x83000000 & 0x7fffffff)	/* Disable divisor latch */

	/*-----------------------------------------------------------------------*/
	/* Print boot message                                                   */
	/*-----------------------------------------------------------------------*/
	UART_PRINT(boot_msg)

	jr	ra
	nop

/*---------------------------------------------------------------------------*/
/* Boot message                                                              */
/*---------------------------------------------------------------------------*/
boot_msg:
	.ascii	"\r\nBooting...\r\n\0"
	.align	4
