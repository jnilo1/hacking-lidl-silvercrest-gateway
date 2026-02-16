/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTL8196E_REGS_H
#define RTL8196E_REGS_H

#include <linux/types.h>

/*
 * Minimal register map for RTL8196E.
 * Keep this file small and only add what the new driver uses.
 */

#define RTL8196E_UNCACHE_MASK 0x20000000

static inline void *rtl8196e_uncached_addr(void *p)
{
	return (void *)((unsigned long)p | RTL8196E_UNCACHE_MASK);
}

/* Base addresses */
#define SYSTEM_BASE    0xB8000000
#define SWCORE_BASE    0xBB800000
#define ASIC_TABLE_BASE 0xBB000000

#define SYS_CLK_MAG   (SYSTEM_BASE + 0x0010)
#define CM_ACTIVE_SWCORE (1 << 11)
#define CM_PROTECT (1 << 27)

#define CPU_IFACE_BASE (SYSTEM_BASE + 0x10000)
/* MAC / PHY control */
#define SWMACCR_BASE (SWCORE_BASE + 0x4000)
#define PCRAM_BASE   (SWCORE_BASE + 0x4100)
#define ALE_BASE     (0x4400 + SWCORE_BASE)

/* CPU interface registers */
#define CPUICR    (0x000 + CPU_IFACE_BASE)
#define CPURPDCR0 (0x004 + CPU_IFACE_BASE)
#define CPURPDCR1 (0x008 + CPU_IFACE_BASE)
#define CPURPDCR2 (0x00C + CPU_IFACE_BASE)
#define CPURPDCR3 (0x010 + CPU_IFACE_BASE)
#define CPURPDCR4 (0x014 + CPU_IFACE_BASE)
#define CPURPDCR5 (0x018 + CPU_IFACE_BASE)
#define CPURMDCR0 (0x01C + CPU_IFACE_BASE)
#define CPUTPDCR0 (0x020 + CPU_IFACE_BASE)
#define CPUQDM0   (0x030 + CPU_IFACE_BASE)
#define CPUQDM2   (0x034 + CPU_IFACE_BASE)
#define CPUQDM4   (0x038 + CPU_IFACE_BASE)
#define CPUIIMR   (0x028 + CPU_IFACE_BASE)
#define CPUIISR   (0x02C + CPU_IFACE_BASE)

/* Switch misc */
#define SWMISC_BASE (0x4200 + SWCORE_BASE)
#define SSIR       (0x04 + SWMISC_BASE)
#define SIRR       (SSIR)
#define TRXRDY     (1 << 0)
#define MEMCR      (0x34 + SWMISC_BASE)

/* VLAN / netif mapping */
#define VCR0      (0x00 + 0x4A00 + SWCORE_BASE)
#define PVCR0      (0x08 + 0x4A00 + SWCORE_BASE)
#define PLITIMR    (0x20 + ALE_BASE)

#define EN_ALL_PORT_VLAN_INGRESS_FILTER (0x1ff << 0)

/* Output queue control */
#define OQNCR_BASE (SWCORE_BASE + 0x4700)
#define QNUMCR    (0x54 + OQNCR_BASE)

/* PHY/MAC registers */
#define PCRP0     (0x004 + PCRAM_BASE)
#define PSRP0     (0x028 + PCRAM_BASE)
#define MDCIOCR   (0x004 + SWMACCR_BASE)
#define MDCIOSR   (0x008 + SWMACCR_BASE)

/* PHY bits */
#define EnablePHYIf        (1 << 0)
#define MacSwReset         (1 << 3)
#define PortStatusLinkUp   (1 << 4)
#define PortStatusNWayEnable (1 << 7)
#define PortStatusDuplex   (1 << 3)
#define PortStatusLinkSpeed_MASK (3 << 0)
#define PortStatusLinkSpeed_OFFSET 0
#define STP_PortST_MASK (3 << 4)
#define STP_PortST_FORWARDING (3 << 4)

/* MDIO */
#define COMMAND_READ  (0 << 31)
#define COMMAND_WRITE (1 << 31)
#define PHYADD_OFFSET 24
#define REGADD_OFFSET 16
#define MDC_STATUS    (1 << 31)

/* ALE / L2 control */
#define TEACR    (0x00 + ALE_BASE)
#define MSCR     (0x10 + ALE_BASE)
#define SWTCR0   (0x18 + ALE_BASE)
#define SWTCR1   (0x1c + ALE_BASE)
#define FFCR     (0x28 + ALE_BASE)
#define CSCR     (0x048 + SWMACCR_BASE)
#define SWTCR0_TLU_START (1 << 18)
#define SWTCR0_TLU_BUSY  (1 << 19)
#define EN_L2    (1 << 0)
#define EN_L3    (1 << 1)
#define EN_L4    (1 << 2)

#define TLU_CTRL        (SWCORE_BASE + 0x4418)
#define TLU_CTRL_START  (1 << 18)
#define TLU_CTRL_READY  (1 << 19)
#define LIMDBC_MASK (3 << 16)
#define LIMDBC_VLAN (0 << 16)
#define NAPTF2CPU (1 << 14)
#define EN_UNUNICAST_TOCPU (1 << 1)
#define EN_UNMCAST_TOCPU (1 << 0)
#define EN_MCAST (1 << 3)
#define MultiPortModeP_OFFSET 5
#define MultiPortModeP_MASK (0x1ff)
#define MCAST_PORT_EXT_MODE_OFFSET MultiPortModeP_OFFSET
#define MCAST_PORT_EXT_MODE_MASK MultiPortModeP_MASK
#define ALLOW_L2_CHKSUM_ERR (1 << 0)
#define ALLOW_L3_CHKSUM_ERR (1 << 1)
#define ALLOW_L4_CHKSUM_ERR (1 << 2)

/* SWTCR1 bits (minimal subset) */
#define ENNATT2LOG   (1 << 10)
#define ENFRAGTOACLPT (1 << 11)

/* ASIC table types (minimal) */
#define RTL8196E_TBL_L2    0
#define RTL8196E_TBL_NETIF 4
#define RTL8196E_TBL_VLAN  6

#define RTL8196E_NETIF_TABLE_SIZE 8
#define RTL8196E_VLAN_TABLE_SIZE 16
#define RTL8196E_CPU_PORT_MASK  0x20

/* ASIC table access */
#define TBL_ACCESS_BASE (SWCORE_BASE + 0x4d00)
#define TBL_ACCESS_CTRL (TBL_ACCESS_BASE + 0x00)
#define TBL_ACCESS_STAT (TBL_ACCESS_BASE + 0x04)
#define TBL_ACCESS_ADDR (TBL_ACCESS_BASE + 0x08)
#define TBL_ACCESS_DATA (TBL_ACCESS_BASE + 0x20)
#define TBL_ACCESS_BUSY (1 << 0)
#define TBL_ACCESS_CMD_WRITE 9

/* CPUICR bits */
#define TXCMD            (1 << 31)
#define RXCMD            (1 << 30)
#define BUSBURST_32WORDS 0
#define MBUF_2048BYTES   (4 << 24)
#define EXCLUDE_CRC      (1 << 16)
#define TXFD             (1 << 23)

/* Interrupt bits */
#define LINK_CHANGE_IE         (1 << 31)
#define PKTHDR_DESC_RUNOUT_IE_ALL (0x3f << 17)
#define RX_DONE_IE_ALL         (0x3f << 3)
#define TX_ALL_DONE_IE_ALL     (0x3 << 1)

#define LINK_CHANGE_IP         (1 << 31)
#define PKTHDR_DESC_RUNOUT_IP_ALL (0x3f << 17)
#define MBUF_DESC_RUNOUT_IP_ALL   (1 << 16)
#define RX_DONE_IP_ALL         (0x3f << 3)
#define TX_ALL_DONE_IP_ALL     (0x03 << 1)

/* Reset bits */
#define FULL_RST               (1 << 2)

#endif /* RTL8196E_REGS_H */
