/*
 * Realtek RTL819x MIPS Interrupt Dispatch
 *
 * Copyright (C) 2025 Jacques Nilo
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 as published
 * by the Free Software Foundation.
 */

#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/irqchip.h>
#include <linux/of_irq.h>

#include <asm/irq_cpu.h>
#include <asm/mipsregs.h>
#include <asm/mach-realtek/imem.h>

/* MIPS CPU Interrupt Lines (IP0-IP7) */
#define REALTEK_CPU_IRQ_CASCADE     2       /* IP2 - Cascaded interrupts (UART0 only) */
#define REALTEK_CPU_IRQ_UART1       3       /* IP3 - UART1 direct */
#define REALTEK_CPU_IRQ_SWITCH      4       /* IP4 - Switch direct */
#define REALTEK_CPU_IRQ_TIMER       7       /* IP7 - Timer direct */

/* Mask of all known/handled interrupt sources */
#define REALTEK_HANDLED_IRQS (STATUSF_IP7 | STATUSF_IP4 | STATUSF_IP3 | STATUSF_IP2)

/**
 * plat_irq_dispatch - Top-level MIPS interrupt dispatcher
 *
 * Main entry point for hardware interrupts. Routes interrupts based
 * on MIPS IP lines:
 * - IP7: System timer (direct, most frequent - checked first)
 * - IP4: Switch/Ethernet (direct via INTC bit 15)
 * - IP3: UART1 (direct via INTC bit 13, production traffic)
 * - IP2: Cascaded interrupts (UART0 only via INTC bit 12)
 *
 * Note: Uses independent if statements (not else-if) to handle multiple
 * simultaneous interrupts in a single dispatch call, reducing latency.
 */
asmlinkage __iram void plat_irq_dispatch(void)
{
    unsigned long pending = read_c0_status() & read_c0_cause() & ST0_IM;

    if (likely(pending)) {
        /* Timer is the most frequent interrupt (periodic tick) */
        if (likely(pending & STATUSF_IP7)) {
            do_IRQ(REALTEK_CPU_IRQ_TIMER);
        }
        /* Switch/Ethernet second most frequent (network traffic) */
        if (pending & STATUSF_IP4) {
            do_IRQ(REALTEK_CPU_IRQ_SWITCH);
        }
        /* UART1 production traffic */
        if (pending & STATUSF_IP3) {
            do_IRQ(REALTEK_CPU_IRQ_UART1);
        }
        /* UART0 cascaded (least frequent) */
        if (pending & STATUSF_IP2) {
            do_IRQ(REALTEK_CPU_IRQ_CASCADE);
        }

        /* Check for spurious interrupts (should be very rare) */
        if (unlikely(!(pending & REALTEK_HANDLED_IRQS))) {
            spurious_interrupt();
        }
    }
}

/**
 * arch_init_irq - Architecture-specific IRQ initialization
 *
 * This function initializes the interrupt system by invoking the
 * device tree IRQ initialization framework.
 */
void __init arch_init_irq(void)
{
    irqchip_init();
}
