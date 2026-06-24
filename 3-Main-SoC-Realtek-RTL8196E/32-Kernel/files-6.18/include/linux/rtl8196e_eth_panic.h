/* SPDX-License-Identifier: GPL-2.0 */
/*
 * rtl8196e_eth_panic.h - panic-time snapshot of the RTL8196E Ethernet
 * driver's issue-#99 (RUNOUT-storm) recovery state.
 *
 * Cross-subsystem contract between the rtl8196e-eth driver (producer) and
 * the rtl819x watchdog driver (consumer). The watchdog leaves a DRAM
 * post-mortem record that survives the soft-lockup reset; from record v5 it
 * carries this eth snapshot so the boot after a #99 lockup tells us whether
 * the rc2 poll-side resync actually fired:
 *
 *   resync > 0  -> the detector fired and the storm continued anyway
 *                  (the resync is insufficient — Hyp. B)
 *   resync == 0 -> the detector never fired (the gate is wrong — Hyp. A);
 *                  `iisr` then names which interrupt bit was actually storming
 *
 * The watchdog carries a __weak default definition that returns false; the
 * eth driver provides the strong override. So the watchdog always has a
 * callable symbol (it links and runs whether or not the eth driver is built
 * in), and — because the watchdog's call site is a normal strong reference —
 * the override survives --gc-sections. The snapshot is read from the panic
 * notifier, so it must touch only plain memory and MMIO — no locks, no sleeping.
 */
#ifndef _LINUX_RTL8196E_ETH_PANIC_H
#define _LINUX_RTL8196E_ETH_PANIC_H

#include <linux/types.h>

struct rtl8196e_eth_panic {
	u32 up;		/* 1 if the interface was running at panic, else 0 */
	u32 resync;	/* rx_runout_resync   — poll-side full resyncs performed */
	u32 kick;	/* rx_runout_kick     — swcore-watchdog NAPI kicks */
	u32 zero;	/* rx_runout_zero     — in-progress consecutive zero-work polls */
	u32 seen;	/* swcore_runout_seen — in-progress consecutive RUNOUT checks */
	u32 iisr;	/* live CPUIISR at panic (which IRQ source is asserted) */
	u32 iimr;	/* live CPUIIMR at panic (which sources are unmasked) */
	u32 rx_idx;	/* driver RX ring cursor */
};

/*
 * Fill *out and return true if the (single) eth instance is up; return false
 * (leaving *out untouched) otherwise. The rtl8196e-eth driver provides the
 * strong definition; the watchdog provides a __weak default returning false,
 * so a kernel without the eth driver still links. Panic-safe: plain reads + MMIO.
 */
bool rtl8196e_eth_panic_snapshot(struct rtl8196e_eth_panic *out);

#endif /* _LINUX_RTL8196E_ETH_PANIC_H */
