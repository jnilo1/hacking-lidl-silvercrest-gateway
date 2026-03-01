/*
 * RTL865x ASIC L2 Switch Driver
 * Copyright (c) 2009 Realtek Semiconductor Corporation
 * Author: hyking (hyking_liu@realsil.com.cn)
 * Adapted for Linux 5.10 & RTL8196E: Jacques Nilo (2025)
 *
 * Layer 2 switch ASIC functions: PHY, MII, ports, STP, QoS.
 *
 * SPDX-License-Identifier: GPL-2.0
 */
#include "rtl819x.h"
#include "rtl865x_asicCom.h"
#include "rtl865x_asicL2.h"

#include <linux/delay.h>

/* RTL865xC ASIC regs: local-only defines (trimmed from rtl865xc_asicregs.h) */
#define REVR (SYSTEM_BASE + 0x00000000)

#define POWER_DOWN (1 << 11)

#define RESTART_AUTONEGO (1 << 9)

#define CAPABLE_PAUSE (1 << 10)

#define LINK_RGMII 0				   /* RGMII mode */

#define LINK_MII_MAC 1				   /* GMII/MII MAC auto mode */

#define LINK_MII_PHY 2				   /* GMII/MII PHY auto mode */

#define LINKMODE_OFFSET 23			   /* Link type offset */

#define P5_LINK_RGMII LINK_RGMII	   /* Port 5 RGMII mode */

#define P5_LINK_MII_MAC LINK_MII_MAC   /* Port 5 GMII/MII MAC auto mode */

#define P5_LINK_MII_PHY LINK_MII_PHY   /* Port 5 GMII/MII PHY auto mode */

#define P5_LINK_OFFSET LINKMODE_OFFSET /* Port 5 link type offset */

#define MDCIOCR (0x004 + SWMACCR_BASE) /* MDC/MDIO Command */

#define MDCIOSR (0x008 + SWMACCR_BASE) /* MDC/MDIO Status */

#define PPMAR (0x010 + SWMACCR_BASE)   /* Per port matching action */

#define PATP0 (0x014 + SWMACCR_BASE)   /* Pattern for port 0 */

#define MASKP0 (0x02C + SWMACCR_BASE)  /* Mask for port 0 */

#define CSCR (0x048 + SWMACCR_BASE)	   /* Checksum Control Register */

#define SELIPG_MASK (0x3 << 18) /* Define min. IPG between backpressure data */

#define SELIPG_11 (2 << 18)		/* 11, unit: byte-time */

#define CF_FCDSC_OFFSET (4)		  /* Flow control DSC tolerance, default: 24 pages ( also minimum value ) */

#define CF_FCDSC_MASK (0x7f << 4) /* Flow control DSC tolerance, default: 24 pages ( also minimum value ) */

#define CF_RXIPG_MASK (0xf << 0)  /* Min. IPG limitation for RX receiving packetMinimum value is 6. Maximum value is 12. */

#define COMMAND_READ (0 << 31)	  /* 0:Read Access, 1:Write Access */

#define COMMAND_WRITE (1 << 31)	  /* 0:Read Access, 1:Write Access */

#define PHYADD_OFFSET (24)		  /* PHY Address, said, PHY ID */

#define REGADD_OFFSET (16)		  /* PHY Register */

#define MDC_STATUS (1 << 31) /* 0: Process Done, 1: In progress */

#define PITCR (0x000 + PCRAM_BASE)	  /* Port Interface Type Control Register */

#define P0GMIICR (0x04C + PCRAM_BASE) /* Port-0 GMII Configuration Register */

#define P5GMIICR (0x050 + PCRAM_BASE) /* Port-5 GMII Configuration Register */

#define Port4_TypeCfg_SerDes (1 << 8)

#define Port3_TypeCfg_SerDes (1 << 6)

#define Port2_TypeCfg_SerDes (1 << 4)

#define Port1_TypeCfg_SerDes (1 << 2)

#define ExtPHYID_OFFSET (26)	   /* External PHY ID */

#define ForceSpeed100M (1 << 19)  /* Force speed 100M */

#define ForceSpeed1000M (2 << 19) /* Force speed 1G */

#define ForceDuplex (1 << 18)	  /* Force Duplex */

#define AutoNegoSts_MASK (0x1f << 18)

#define PauseFlowControl_MASK (3 << 16)	 /* Mask for per-port 802.3 PAUSE flow control ability control */

#define PauseFlowControlEtxDrx (1 << 16) /* force: enable TX, disable RX */

#define PauseFlowControlDtxErx (2 << 16) /* force: disable TX, enable RX */

#define MIIcfg_RXER (1 << 13)	 /* MII interface Parameter setup */

#define STP_PortST_MASK (3 << 4)	   /* Mask Spanning Tree Protocol Port State Control */

#define STP_PortST_DISABLE (0 << 4)	   /* Disable State */

#define STP_PortST_BLOCKING (1 << 4)   /* Blocking State */

#define STP_PortST_LEARNING (2 << 4)   /* Learning State */

#define STP_PortST_FORWARDING (3 << 4) /* Forwarding State */

#define MacSwReset (1 << 3)			   /* 0: reset state, 1: normal state */

#define Conf_done (1 << 6) /*Port5 configuration is done to enable the frame reception and transmission.	*/

#define CFG_GMAC_MASK (3 << 23)			/* The register default reflect the HW power on strapping value of H/W pin. */

#define RGMII_RCOMP_MASK (3 << 0)	 /* RGMII Input Timing compensation control */

#define RGMII_RCOMP_0NS (0 << 0)	 /* Rcomp 0.0 ns */

#define RGMII_RCOMP_2DOT5NS (3 << 0) /* Rcomp 3.0 ns */

#define RGMII_TCOMP_MASK (7 << 2)	 /* RGMII Output Timing compensation control */

#define RGMII_TCOMP_0NS (0 << 2)	 /* Tcomp 0.0 ns */

#define RGMII_TCOMP_7NS (7 << 2)	 /* Tcomp 7.0 ns */

#define EEECR (0x60 + PCRAM_BASE) /* EEE ability Control Register ( 0xBB80_4160 ) */

#define RMACR (0x08 + ALE_BASE)		 /* Reserved Multicast Address Address Mapping */

#define FFCR (0x28 + ALE_BASE)		 /*Frame Forwarding Configuratoin Register */

#define MADDR00 (1 << 0)	/* BPDU (Bridge Group Address) */

#define Enable_ST (1 << 5)	  /* Enable Spanning Tree Protocol. 0: disable, 1: enable */

#define EN_STP Enable_ST	  /* Alias Name */

#define NAPTF2CPU (1 << 14)								 /*	Trap packets not in TCP/UDP/ICMP format and \
										   destined to the interface required to do NAPT */

#define MultiPortModeP_OFFSET (5)						 /* Multicast Port Mode : Internal (0) or External (1) */

#define MultiPortModeP_MASK (0x1ff)						 /* {Ext3~Ext1,Port0~Port5} 0:Internal, 1:External */

#define MCAST_PORT_EXT_MODE_OFFSET MultiPortModeP_OFFSET /* Alias Name */

#define MCAST_PORT_EXT_MODE_MASK MultiPortModeP_MASK	 /* Alias Name */

#define WANRouteMode_MASK (3 << 3)

#define WAN_ROUTE_MASK WANRouteMode_MASK

#define ENFRAGTOACLPT (1 << 11)			   /* Enable fragment packet checked by ACL and protocol trapper */

#define EnNATT2LOG (1 << 10)			   /* Enable trapping attack packets for logging */

#define IPMltCstCtrl_Enable (1 << 3)	/* Enable IP Multicast table lookup */

#define EN_MCAST IPMltCstCtrl_Enable	/* Alias Name for Enable Multicast Table */

#define EnUnkUC2CPU (1 << 1)			/* Enable Unknown Unicast Packet Trap to CPU port */

#define EnUnkMC2CPU (1 << 0)			/* Enable Unknown Multicast Packet Trap to CPU port */

#define EN_UNUNICAST_TOCPU EnUnkUC2CPU	/* Alias Name */

#define EN_UNMCAST_TOCPU EnUnkMC2CPU	/* Alias Name */

#define SBFCTR (0x4500 + SWCORE_BASE) /* System Based Flow Control Threshold Register */

#define IQFCTCR (0x0E0 + SBFCTR) /* Input Queue Flow Control Threshold Configuration Register */

#define IQ_DSC_FCON_OFFSET (8)		  /* Offset for input Queue Flow control turn OFF descriptor threshold */

#define IQ_DSC_FCON_MASK (0xff << 8)  /* Mask for input Queue Flow control turn OFF descriptor threshold */

#define IQ_DSC_FCOFF_OFFSET (0)		  /* Offset for input Queue Flow control turn ON descriptor threshold */

#define IQ_DSC_FCOFF_MASK (0xff << 0) /* Mask for input Queue Flow control turn ON descriptor threshold */

#define QOSFCR (0x00 + OQNCR_BASE)		  /* QoS Function Control Register */

#define PBPCR (0x14 + OQNCR_BASE)		  /* Port Based Priority Control Register Address Mapping */

#define DSCPCR0 (0x34 + OQNCR_BASE)		  /*DSCP Priority Control Register Address Mapping. */

#define DSCPCR1 (0x38 + OQNCR_BASE)		  /*DSCP Priority Control Register Address Mapping. */

#define DSCPCR2 (0x3C + OQNCR_BASE)		  /*DSCP Priority Control Register Address Mapping. */

#define DSCPCR3 (0x40 + OQNCR_BASE)		  /*DSCP Priority Control Register Address Mapping. */

#define DSCPCR4 (0x44 + OQNCR_BASE)		  /*DSCP Priority Control Register Address Mapping. */

#define DSCPCR5 (0x48 + OQNCR_BASE)		  /*DSCP Priority Control Register Address Mapping. */

#define DSCPCR6 (0x4C + OQNCR_BASE)		  /*DSCP Priority Control Register Address Mapping. */

#define QIDDPCR (0x50 + OQNCR_BASE)		  /*Queue ID Decision Priority Register Address Mapping*/

#define BC_withPIFG_MASK (1 << 0) /* Bandwidth Conrol Include/Exclude Preamble&IFG. 0:exclude; 1:include */

#define IBWC_ODDPORT_OFFSET (16)		 /* ODD-port Ingress Bandwidth Control Offset */

#define IBWC_ODDPORT_MASK (0xFFFF << 16) /* ODD-port Ingress Bandwidth Control MASK */

#define IBWC_EVENPORT_OFFSET (0)		 /* EVEN-port Ingress Bandwidth Control Offset */

#define IBWC_EVENPORT_MASK (0xFFFF << 0) /* EVEN-port Ingress Bandwidth Control MASK */

#define PBP_PRI_OFFSET 0			/*Output queue decision priority assign for Port Based Priority*/

#define BP8021Q_PRI_OFFSET 4		/*Output queue decision priority assign for 1Q Based Priority*/

#define DSCP_PRI_OFFSET 8			/*Output queue decision priority assign for DSCP Based Priority*/

#define ACL_PRI_OFFSET 12			/*Output queue decision priority assign for ACL Based Priority*/

#define NAPT_PRI_OFFSET 16			/*Output queue decision priority assign for NAPT Based Priority*/

#define PSCR (SWCORE_BASE + 0x4800)

#define WFQRCRP0 (0x0B0 + PSCR)			 /* Weighted Fair Queue Rate Control Register of Port 0 */

#define ELBPCR (0x104 + PSCR)			 /* Leaky Bucket Parameter Control Register */

#define ELBTTCR (0x108 + PSCR)			 /* Leaky Bucket Token Threshold Control Register */

#define ILBPCR1 (0x10C + PSCR)			 /* Ingress Leaky Bucket Parameter Control Register1 */

#define ILBPCR2 (0x110 + PSCR)			 /* Ingress Leaky Bucket Parameter Control Register2 */

#define ILB_CURRENT_TOKEN (0x114 + PSCR) /* The current token of the Leaky bucket 2Bytes per port(Port 0~Port5) */

#define APR_OFFSET (0)		   /* Average Packet Rate, in times of 64Kbps  CNT1 */

#define APR_MASK (0x3FFF << 0) /* Average Packet Rate, in times of 64Kbps  CNT1 */

#define Token_OFFSET (8)	   /* Token used for adding budget in each time slot. */

#define Token_MASK (0xff << 8) /* Token used for adding budget in each time slot. */

#define Tick_OFFSET (0)		   /* Tick used for time slot size unit */

#define Tick_MASK (0xff << 0)  /* Tick used for time slot size unit */

#define L2_OFFSET (0) /* leaky Bucket Token Hi-threshold register */

#define UpperBound_OFFSET (16)		   /* Ingress BWC Parameter Upper bound Threshold (unit: 400bytes) */

#define LowerBound_OFFSET (0)		   /* Ingress BWC Parameter Lower Bound Threshold (unit: 400 bytes) */

#define ILB_feedToken_OFFSET (8)	   /* Token is used for adding budget in each time slot */

#define ILB_feedToken_MASK (0xff << 8) /* Token is used for adding budget in each time slot */

#define ILB_Tick_OFFSET (0)			   /* Tick is used for time slot size unit. */

#define ILB_Tick_MASK (0xff << 0)	   /* Tick is used for time slot size unit. */

#define VCR0 (0x00 + 0x4A00 + SWCORE_BASE)	  /* Vlan Control register*/

#define PBVCR0 (0x1C + 0x4A00 + SWCORE_BASE)  /* Protocol-Based VLAN Control Register 0      */

#define EnVlanInF_MASK (0x1ff << 0)					   /* Enable Vlan Ingress Filtering */

#define EN_ALL_PORT_VLAN_INGRESS_FILTER EnVlanInF_MASK /* Alias Name */

#define RTL8651_PORTSTA_DISABLED 0x00

#define RTL8651_PORTSTA_BLOCKING 0x01

#define RTL8651_PORTSTA_LISTENING 0x02

#define RTL8651_PORTSTA_LEARNING 0x03

#define RTL8651_PORTSTA_FORWARDING 0x04

#define RTL8651_BC_FULL 0x00

#define LEDCREG (SWCORE_BASE + 0x4300) /* LED control */

#define BW_FULL_RATE 0

#define BW_128K 1

#define BW_256K 2

#define BW_512K 3

#define BW_1M 4

#define BW_2M 5

#define BW_4M 6

#define BW_8M 7

#define ALLOW_L2_CHKSUM_ERR (1 << 0)	/* Allow L2 checksum error */

#define ALLOW_L3_CHKSUM_ERR (1 << 1)	/* Allow L3 checksum error */

#define ALLOW_L4_CHKSUM_ERR (1 << 2)	/* Allow L4 checksum error */

#define EN_ETHER_L3_CHKSUM_REC (1 << 3) /* Enable L3 checksum recalculation*/

#define EN_ETHER_L4_CHKSUM_REC (1 << 4) /* Enable L4 checksum recalculation*/

#define PIN_MUX_SEL 0xb8000040

#define PIN_MUX_SEL2 0xb8000044

#define HW_STRAP (SYSTEM_BASE + 0x0008)


static uint8 fidHashTable[] = {0x00, 0x0f, 0xf0, 0xff};

int32 rtl865x_wanPortMask;
int32 rtl865x_lanPortMask = RTL865X_PORTMASK_UNASIGNED;

int32 rtl865x_maxPreAllocRxSkb = RTL865X_PREALLOC_SKB_UNASIGNED;
int32 rtl865x_rxSkbPktHdrDescNum = RTL865X_PREALLOC_SKB_UNASIGNED;
int32 rtl865x_txSkbPktHdrDescNum = RTL865X_PREALLOC_SKB_UNASIGNED;
int32 miiPhyAddress;
rtl8651_tblAsic_ethernet_t rtl8651AsicEthernetTable[9]; // RTL8651_PORT_NUMBER+rtl8651_totalExtPortNum

/* For Bandwidth control - RTL865xB Backward compatible only */
#define _RTL865XB_BANDWIDTHCTRL_X1 (1 << 0)
#define _RTL865XB_BANDWIDTHCTRL_X4 (1 << 1)
#define _RTL865XB_BANDWIDTHCTRL_X8 (1 << 2)
#define _RTL865XB_BANDWIDTHCTRL_CFGTYPE 2 /* Ingress (0) and Egress (1) : 2 types of configuration */
static int32 _rtl865xB_BandwidthCtrlMultiplier = _RTL865XB_BANDWIDTHCTRL_X1;
static uint32 _rtl865xB_BandwidthCtrlPerPortConfiguration[RTL8651_PORT_NUMBER][_RTL865XB_BANDWIDTHCTRL_CFGTYPE /* Ingress (0), Egress (1) */];
static uint32 _rtl865xC_BandwidthCtrlNum[] = {
	0,		 /* BW_FULL_RATE */
	131072,	 /* BW_128K */
	262144,	 /* BW_256K */
	524288,	 /* BW_512K */
	1048576, /* BW_1M */
	2097152, /* BW_2M */
	4194304, /* BW_4M */
	8388608	 /* BW_8M */
};

#define RTL865XC_INGRESS_16KUNIT 16384
#define RTL865XC_EGRESS_64KUNIT 65535

int eee_enabled = 0;

#define QNUM_IDX_123 0
#define QNUM_IDX_45 1
#define QNUM_IDX_6 2

static void _rtl8651_syncToAsicEthernetBandwidthControl(void);

uint32 rtl8651_filterDbIndex(ether_addr_t *macAddr, uint16 fid)
{
	return (macAddr->octet[0] ^ macAddr->octet[1] ^
			macAddr->octet[2] ^ macAddr->octet[3] ^
			macAddr->octet[4] ^ macAddr->octet[5] ^ fidHashTable[fid]) &
		   0xFF;
}

int32 rtl8651_setAsicL2Table(uint32 row, uint32 column, rtl865x_tblAsicDrv_l2Param_t *l2p)
{
	rtl865xc_tblAsic_l2Table_t entry;

	if ((row >= RTL8651_L2TBL_ROW) || (column >= RTL8651_L2TBL_COLUMN) || (l2p == NULL))
		return FAILED;
	if (l2p->macAddr.octet[5] != ((row ^ (fidHashTable[l2p->fid]) ^ l2p->macAddr.octet[0] ^ l2p->macAddr.octet[1] ^ l2p->macAddr.octet[2] ^ l2p->macAddr.octet[3] ^ l2p->macAddr.octet[4]) & 0xff))
		return FAILED;

	memset(&entry, 0, sizeof(entry));
	entry.mac47_40 = l2p->macAddr.octet[0];
	entry.mac39_24 = (l2p->macAddr.octet[1] << 8) | l2p->macAddr.octet[2];
	entry.mac23_8 = (l2p->macAddr.octet[3] << 8) | l2p->macAddr.octet[4];

	if (l2p->memberPortMask > RTL8651_PHYSICALPORTMASK) // this MAC is on extension port
		entry.extMemberPort = (l2p->memberPortMask >> RTL8651_PORT_NUMBER);

	entry.memberPort = l2p->memberPortMask & RTL8651_PHYSICALPORTMASK;
	entry.toCPU = l2p->cpu == TRUE ? 1 : 0;
	entry.isStatic = l2p->isStatic == TRUE ? 1 : 0;
	entry.nxtHostFlag = l2p->nhFlag == TRUE ? 1 : 0;

	/* RTL865xC: modification of age from ( 2 -> 3 -> 1 -> 0 ) to ( 3 -> 2 -> 1 -> 0 ). modification of granularity 100 sec to 150 sec. */
	entry.agingTime = (l2p->ageSec > 300) ? 0x03 : (l2p->ageSec <= 300 && l2p->ageSec > 150) ? 0x02
											   : (l2p->ageSec <= 150 && l2p->ageSec > 0)	 ? 0x01
																							 : 0x00;

	entry.srcBlock = (l2p->srcBlk == TRUE) ? 1 : 0;
	entry.fid = l2p->fid;
	entry.auth = l2p->auth;
	return _rtl8651_forceAddAsicEntry(TYPE_L2_SWITCH_TABLE, row << 2 | column, &entry);
}

int32 rtl8651_delAsicL2Table(uint32 row, uint32 column)
{
	rtl865xc_tblAsic_l2Table_t entry;

	if (row >= RTL8651_L2TBL_ROW || column >= RTL8651_L2TBL_COLUMN)
		return FAILED;

	memset(&entry, 0, sizeof(entry));
	return _rtl8651_forceAddAsicEntry(TYPE_L2_SWITCH_TABLE, row << 2 | column, &entry);
}

ether_addr_t cachedDA;
int32 rtl8651_getAsicL2Table(uint32 row, uint32 column, rtl865x_tblAsicDrv_l2Param_t *l2p)
{
	rtl865xc_tblAsic_l2Table_t entry;

	if ((row >= RTL8651_L2TBL_ROW) || (column >= RTL8651_L2TBL_COLUMN) || (l2p == NULL))
		return FAILED;

	/*	RTL865XC should fix this problem.WRITE_MEM32(TEACR,READ_MEM32(TEACR)|0x1); ASIC patch: disable L2 Aging while reading L2 table */
	_rtl8651_readAsicEntry(TYPE_L2_SWITCH_TABLE, row << 2 | column, &entry);
	// WRITE_MEM32(TEACR,READ_MEM32(TEACR)&0x1); ASIC patch: enable L2 Aging aftrer reading L2 table */

	if (entry.agingTime == 0 && entry.isStatic == 0)
		return FAILED;
	l2p->macAddr.octet[0] = entry.mac47_40;
	l2p->macAddr.octet[1] = entry.mac39_24 >> 8;
	l2p->macAddr.octet[2] = entry.mac39_24 & 0xff;
	l2p->macAddr.octet[3] = entry.mac23_8 >> 8;
	l2p->macAddr.octet[4] = entry.mac23_8 & 0xff;
	l2p->macAddr.octet[5] = row ^ l2p->macAddr.octet[0] ^ l2p->macAddr.octet[1] ^ l2p->macAddr.octet[2] ^ l2p->macAddr.octet[3] ^ l2p->macAddr.octet[4] ^ (fidHashTable[entry.fid]);
	l2p->cpu = entry.toCPU == 1 ? TRUE : FALSE;
	l2p->srcBlk = entry.srcBlock == 1 ? TRUE : FALSE;
	l2p->nhFlag = entry.nxtHostFlag == 1 ? TRUE : FALSE;
	l2p->isStatic = entry.isStatic == 1 ? TRUE : FALSE;
	l2p->memberPortMask = (entry.extMemberPort << RTL8651_PORT_NUMBER) | entry.memberPort;

	/* RTL865xC: modification of age from ( 2 -> 3 -> 1 -> 0 ) to ( 3 -> 2 -> 1 -> 0 ). modification of granularity 100 sec to 150 sec. */
	l2p->ageSec = entry.agingTime * 150;

	l2p->fid = entry.fid;
	l2p->auth = entry.auth;
	return SUCCESS;
}

int32 rtl8651_clearAsicL2Table(void)
{
	rtl8651_clearSpecifiedAsicTable(TYPE_L2_SWITCH_TABLE, RTL8651_L2TBL_ROW * RTL8651_L2TBL_COLUMN);
	rtl8651_clearSpecifiedAsicTable(TYPE_RATE_LIMIT_TABLE, RTL8651_RATELIMITTBL_SIZE);
	return SUCCESS;
}

inline int32 convert_setAsicL2Table(uint32 row, uint32 column, ether_addr_t *mac, int8 cpu,
									int8 srcBlk, uint32 mbr, uint32 ageSec, int8 isStatic, int8 nhFlag, int8 fid, int8 auth)
{
	rtl865x_tblAsicDrv_l2Param_t l2;

	memset(&l2, 0, sizeof(rtl865x_tblAsicDrv_l2Param_t));

	l2.ageSec = ageSec;
	l2.cpu = cpu;
	l2.isStatic = isStatic;
	l2.memberPortMask = mbr;
	l2.nhFlag = nhFlag;
	l2.srcBlk = srcBlk;
	l2.fid = fid;
	l2.auth = auth;
	memcpy(&l2.macAddr, mac, 6);
	return rtl8651_setAsicL2Table(row, column, &l2);
}

/*
 * <<RTL8651 version B Bug>>
 * RTL8651 L2 entry bug:
 *		For each L2 entry added by driver table as a static entry, the aging time
 *		will not be updated by ASIC
 * Bug fixed:
 *		To patch this bug, set the entry is a dynamic entry and turn on the 'nhFlag',
 *		then the aging time of this entry will be updated and once aging time expired,
 *		it won't be removed by ASIC automatically.
 */
int32 rtl8651_setAsicL2Table_Patch(uint32 row, uint32 column, ether_addr_t *mac, int8 cpu,
								   int8 srcBlk, uint32 mbr, uint32 ageSec, int8 isStatic, int8 nhFlag, int8 fid, int8 auth)
{
	if (mac->octet[0] & 0x1)
	{
		return convert_setAsicL2Table(
			row,
			column,
			mac,
			cpu,
			FALSE,
			mbr,
			ageSec,
			isStatic, /* No one will be broadcast/multicast source */
			nhFlag,	  /* No one will be broadcast/multicast source */
			fid,
			TRUE);
	}
	else
	{
		int8 dStatic = isStatic /*, dnhFlag=(isStatic==TRUE? TRUE: FALSE)*/;
		int8 dnhFlag = nhFlag;
		return convert_setAsicL2Table(
			row,
			column,
			mac,
			cpu,
			srcBlk,
			mbr,
			ageSec,
			dStatic,
			dnhFlag,
			fid,
			auth);
	}
}

static int32 _rtl8651_initAsicPara(rtl8651_tblAsic_InitPara_t *para)
{
	memset(&rtl8651_tblAsicDrvPara, 0, sizeof(rtl8651_tblAsic_InitPara_t));

	if (para)
	{
		/* Parameter != NULL, check its correctness */
		if (para->externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT1234_RTL8212)
		{
			ASICDRV_ASSERT(para->externalPHYId[1] != 0);
			ASICDRV_ASSERT(para->externalPHYId[2] != 0);
			ASICDRV_ASSERT(para->externalPHYId[3] != 0);
			ASICDRV_ASSERT(para->externalPHYId[4] != 0);
			ASICDRV_ASSERT(para->externalPHYId[2] == (para->externalPHYId[1] + 1));
			ASICDRV_ASSERT(para->externalPHYId[4] == (para->externalPHYId[3] + 1));
		}
		if (para->externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT5_RTL8211B)
		{
			ASICDRV_ASSERT(para->externalPHYId[5] != 0);
		}

		/* ============= Check passed : set it =============  */
		memcpy(&rtl8651_tblAsicDrvPara, para, sizeof(rtl8651_tblAsic_InitPara_t));
	}

	return SUCCESS;
}

void Set_GPHYWB(unsigned int phyid, unsigned int page, unsigned int reg, unsigned int mask, unsigned int val)
{
	unsigned int data = 0;
	unsigned int wphyid = 0;	 // start
	unsigned int wphyid_end = 1; // end

	if (phyid == 999)
	{
		wphyid = 0;
		wphyid_end = 5; // total phyid=0~4
	}
	else
	{
		wphyid = phyid;
		wphyid_end = phyid + 1;
	}

	for (; wphyid < wphyid_end; wphyid++)
	{
		// change page
		if (page >= 31)
		{
			rtl8651_setAsicEthernetPHYReg(wphyid, 31, 7);
			rtl8651_setAsicEthernetPHYReg(wphyid, 30, page);
		}
		else
		{
			rtl8651_setAsicEthernetPHYReg(wphyid, 31, page);
		}

		if (mask != 0)
		{
			rtl8651_getAsicEthernetPHYReg(wphyid, reg, &data);
			data = data & mask;
		}
		rtl8651_setAsicEthernetPHYReg(wphyid, reg, data | val);

		// switch to page 0
		rtl8651_setAsicEthernetPHYReg(wphyid, 31, 0);
	}
}


unsigned int Get_P0_PhyMode(void)
{
/*
	00: External  phy
	01: embedded phy
	10: olt
	11: deb_sel
*/
#define GET_BITVAL(v, bitpos, pat) ((v & ((unsigned int)pat << bitpos)) >> bitpos)
#define RANG1 1
#define RANG2 3
#define RANG3 7
#define RANG4 0xf

	unsigned int v = REG32(HW_STRAP);
	unsigned int mode = GET_BITVAL(v, 6, RANG1) * 2 + GET_BITVAL(v, 7, RANG1);

	return (mode & 3);
}

unsigned int Get_P0_MiiMode(void)
{
/*
	0: MII-PHY
	1: MII-MAC
	2: GMII-MAC
	3: RGMII
*/
#define GET_BITVAL(v, bitpos, pat) ((v & ((unsigned int)pat << bitpos)) >> bitpos)
#define RANG1 1
#define RANG2 3
#define RANG3 7
#define RANG4 0xf

	unsigned int v = REG32(HW_STRAP);
	unsigned int mode = GET_BITVAL(v, 27, RANG2);

	return mode;
}

unsigned int Get_P0_RxDelay(void)
{
#define GET_BITVAL(v, bitpos, pat) ((v & ((unsigned int)pat << bitpos)) >> bitpos)
#define RANG1 1
#define RANG2 3
#define RANG3 7
#define RANG4 0xf

	unsigned int v = REG32(HW_STRAP);
	unsigned int val = GET_BITVAL(v, 29, RANG3);
	return val;
}

unsigned int Get_P0_TxDelay(void)
{
#define GET_BITVAL(v, bitpos, pat) ((v & ((unsigned int)pat << bitpos)) >> bitpos)
#define RANG1 1
#define RANG2 3
#define RANG3 7
#define RANG4 0xf

	unsigned int v = REG32(HW_STRAP);
	unsigned int val = GET_BITVAL(v, 17, RANG1);
	return val;
}

int Setting_RTL8196E_PHY(void)
{
	int i;

	for (i = 0; i < 5; i++)
		REG32(PCRP0 + i * 4) |= (EnForceMode);

	// write page1, reg16, bit[15:13] Iq Current 110:175uA (default 100: 125uA)
	Set_GPHYWB(999, 1, 16, 0xffff - (0x7 << 13), 0x6 << 13);

	// disable power saving mode in A-cut only
	if (REG32(REVR) == 0x8196e000)
		Set_GPHYWB(999, 0, 0x18, 0xffff - (1 << 15), 0 << 15);

	/* B-cut and later,
		just increase a little power in long RJ45 cable case for Green Ethernet feature.
	 */
	else
	{
		// adtune_lb setting
		Set_GPHYWB(999, 0, 22, 0xffff - (0x7 << 4), 0x4 << 4);
		// Setting SNR lb and hb
		Set_GPHYWB(999, 0, 21, 0xffff - (0xff << 0), 0xc2 << 0);
		// auto bais current
		Set_GPHYWB(999, 1, 19, 0xffff - (0x1 << 0), 0x0 << 0);
		Set_GPHYWB(999, 0, 22, 0xffff - (0x1 << 3), 0x0 << 3);
	}

	// fix Ethernet IOT issue
	if (((REG32(BOND_OPTION) & BOND_ID_MASK) != BOND_8196ES) &&
		((REG32(BOND_OPTION) & BOND_ID_MASK) != BOND_8196ES1) &&
		((REG32(BOND_OPTION) & BOND_ID_MASK) != BOND_8196ES2) &&
		((REG32(BOND_OPTION) & BOND_ID_MASK) != BOND_8196ES3))
	{
		Set_GPHYWB(999, 0, 26, 0xffff - (0x1 << 14), 0x0 << 14);
		Set_GPHYWB(999, 0, 17, 0xffff - (0xf << 8), 0xe << 8);
	}

	/* 100M half duplex enhancement */
	/* fix SmartBits half duplex backpressure IOT issue */
	REG32(MACCR) = (REG32(MACCR) & ~(CF_RXIPG_MASK | SELIPG_MASK)) | (0x05 | SELIPG_11);

	/* enlarge "Flow control DSC tolerance" from 24 pages to 48 pages
		to prevent the hardware may drop incoming packets
		after flow control triggered and Pause frame sent */
	REG32(MACCR) = (REG32(MACCR) & ~CF_FCDSC_MASK) | (0x30 << CF_FCDSC_OFFSET);

	for (i = 0; i < 5; i++)
		REG32(PCRP0 + i * 4) &= ~(EnForceMode);

	return 0;
}

void enable_EEE(void)
{

	int i;

	for (i = 0; i < RTL8651_PHY_NUMBER; i++)
		REG32(PCRP0 + i * 4) |= (EnForceMode);
	// enable 100M EEE and 10M EEE
	Set_GPHYWB(999, 4, 16, 0xffff - (0x3 << 12), 0x3 << 12);

	// enable MAC EEE
	REG32(EEECR) = 0x0E739CE7;

	for (i = 0; i < RTL8651_PHY_NUMBER; i++)
		REG32(PCRP0 + i * 4) &= ~(EnForceMode);
}

void disable_EEE(void)
{
	int i;

	for (i = 0; i < RTL8651_PHY_NUMBER; i++)
		REG32(PCRP0 + i * 4) |= (EnForceMode);

	// disable EEE MAC
	REG32(EEECR) = 0;

	// disable 100M EEE and 10M EEE
	Set_GPHYWB(999, 4, 16, 0xffff - (0x3 << 12), 0x0 << 12);

	for (i = 0; i < RTL8651_PHY_NUMBER; i++)
		REG32(PCRP0 + i * 4) &= ~(EnForceMode);
}

/*patch for LED showing*/

#define REG32_ANDOR(x, y, z) (REG32(x) = (REG32(x) & (y)) | (z))

/**
 * rtl8651_setAsicMulticastEnable - Enable/disable L2 multicast/broadcast processing
 * @enable: TRUE to enable multicast/broadcast handling, FALSE to disable
 *
 * Controls the ASIC multicast/broadcast frame processing mode. Despite its name,
 * this function controls L2 MAC-level multicast/broadcast handling, NOT L3 IP
 * multicast routing.
 *
 * When enabled (IPMltCstCtrl_Enable):
 *   - Broadcast frames (FF:FF:FF:FF:FF:FF) are properly forwarded
 *   - Multicast MAC addresses (01:xx:xx:xx:xx:xx) are handled correctly
 *   - Required for ARP broadcasts, DHCP, mDNS, IGMP snooping
 *
 * When disabled (IPMltCstCtrl_Disable):
 *   - All multicast/broadcast frames follow basic L2 forwarding
 *   - May result in CRC errors on broadcast transmission
 *
 * This function was originally in rtl865x_asicL3.c but has been moved to L2
 * as it is required for basic L2 switch operation, independent of L3 routing.
 *
 * Return: SUCCESS (0) always
 */
int32 rtl8651_setAsicMulticastEnable(uint32 enable)
{
	if (enable == TRUE)
	{
		WRITE_MEM32(FFCR, READ_MEM32(FFCR) | EN_MCAST);
	}
	else
	{
		WRITE_MEM32(FFCR, READ_MEM32(FFCR) & ~EN_MCAST);
	}

	return SUCCESS;
}

/**
 * rtl8651_setAsicMulticastPortInternal - Configure port as internal or external
 * @port: Port number (0-5 for physical ports, 6 for CPU port)
 * @isInternal: TRUE for internal port (LAN/CPU), FALSE for external port (WAN)
 *
 * Configures whether a port should be treated as internal or external for
 * multicast/broadcast frame forwarding. This is a Layer 2 configuration that
 * affects how broadcast and multicast frames are forwarded between ports.
 *
 * Internal ports (typical: LAN ports, CPU port):
 *   - Part of the same broadcast domain
 *   - Broadcast/multicast frames are forwarded between internal ports
 *   - Used for normal LAN switching operation
 *
 * External ports (typical: WAN port):
 *   - Separate broadcast domain
 *   - May require different multicast/broadcast handling
 *   - Isolates WAN traffic from LAN broadcast domain
 *
 * For a simple L2 switch or bridge, all ports should typically be set to
 * internal (TRUE) to allow proper broadcast forwarding for ARP resolution.
 *
 * This function configures the MCAST_PORT_EXT_MODE bit in SWTCR0 register.
 * Originally in rtl865x_asicL3.c, moved to L2 as it's fundamental for L2 operation.
 *
 * Return: SUCCESS (0) on success, FAILED (-1) if port number is invalid
 */
int32 rtl8651_setAsicMulticastPortInternal(uint32 port, int8 isInternal)
{
	if (port >= RTL8651_PORT_NUMBER + rtl8651_totalExtPortNum)
	{
		return FAILED;
	}

	if (isInternal == TRUE)
	{
		WRITE_MEM32(SWTCR0, READ_MEM32(SWTCR0) | (((1 << port) & MCAST_PORT_EXT_MODE_MASK) << MCAST_PORT_EXT_MODE_OFFSET));
	}
	else
	{
		WRITE_MEM32(SWTCR0, READ_MEM32(SWTCR0) & ~(((1 << port) & MCAST_PORT_EXT_MODE_MASK) << MCAST_PORT_EXT_MODE_OFFSET));
	}

	return SUCCESS;
}

/*=========================================
 * init Layer2 Asic
 * rtl865x_initAsicL2 mainly configure basic&L2 Asic.
 * =========================================*/
int32 rtl865x_initAsicL2(rtl8651_tblAsic_InitPara_t *para)
{
	int32 index;

	unsigned int P0phymode, P0miimode, P0txdly, P0rxdly;

	// bond check
	// rtl865x_platform_check();

	/*==============================
	 *port
	  ==============================*/

	if ((rtl865x_probeSdramSize()) > (16 << 20))
	{
	}

	ASICDRV_INIT_CHECK(_rtl8651_initAsicPara(para));

	rtl8651_getChipVersion(RtkHomeGatewayChipName, sizeof(RtkHomeGatewayChipName), &RtkHomeGatewayChipRevisionID);
	rtl8651_getChipNameID(&RtkHomeGatewayChipNameID);

	printk(KERN_INFO "rtl819x: Realtek RTL8196E SoC detected (rev %d)\n", RtkHomeGatewayChipRevisionID);

	if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT1234_RTL8212)
	{

		printk("\nEnable Port1~Port4 GigaPort.\n\n");
		/* Patch for 'RGMII port does not get descritpors'. Set to MII PHY mode first and later we'll change to RGMII mode again. */
		rtl865xC_setAsicEthernetMIIMode(0, LINK_MII_PHY);

		/*
			# According to Hardware SD: David & Maxod,

			Set Port5_GMII Configuration Register.
			- RGMII Output Timing compensation control : 0 ns
			- RGMII Input Timing compensation control : 0 ns
		*/
		rtl865xC_setAsicEthernetRGMIITiming(0, RGMII_TCOMP_0NS, RGMII_RCOMP_0NS);

		/* Set P1 - P4 to SerDes Interface. */
		WRITE_MEM32(PITCR, Port4_TypeCfg_SerDes | Port3_TypeCfg_SerDes | Port2_TypeCfg_SerDes | Port1_TypeCfg_SerDes);
	}
	else if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT5_RTL8211B)
	{
		/* Patch for 'RGMII port does not get descritpors'. Set to MII PHY mode first and later we'll change to RGMII mode again. */
		rtl865xC_setAsicEthernetMIIMode(RTL8651_MII_PORTNUMBER, LINK_MII_PHY);

		/*
			# According to Hardware SD: David & Maxod,

			Set Port5_GMII Configuration Register.
			- RGMII Output Timing compensation control : 0 ns
			- RGMII Input Timing compensation control : 0 ns
		*/
		rtl865xC_setAsicEthernetRGMIITiming(RTL8651_MII_PORTNUMBER, RGMII_TCOMP_0NS, RGMII_RCOMP_0NS);
	}

	Setting_RTL8196E_PHY();

	/* 	2006.12.12
		We turn on bit.10 (ENATT2LOG).

		* Current implementation of unnumbered pppoe in multiple session
		When wan type is multiple-session, and one session is unnumbered pppoe, WAN to unnumbered LAN is RP --> NPI.
		And user adds ACL rule to trap dip = unnumbered LAN to CPU.

		However, when pktOpApp of this ACL rule is set, it seems that this toCPU ACL does not work.
		Therefore, we turn on this bit (ENATT2LOG) to trap pkts (WAN --> unnumbered LAN) to CPU.

	*/
	WRITE_MEM32(SWTCR1, READ_MEM32(SWTCR1) | EnNATT2LOG);

	/*
	 * Turn on ENFRAG2ACLPT for Rate Limit. For those packets which need to be trapped to CPU, we turn on
	 * this bit to tell ASIC ACL and Protocol Trap to process these packets. If this bit is not turnned on, packets
	 * which need to be trapped to CPU will not be processed by ASIC ACL and Protocol Trap.
	 * NOTE: 	If this bit is turned on, the backward compatible will disable.
	 *																- chhuang
	 */
	WRITE_MEM32(SWTCR1, READ_MEM32(SWTCR1) | ENFRAGTOACLPT);

	/*
	 * Cannot turn on EnNAP8651B due to:
	 * If turn on, NAT/LP/ServerPort will reference nexthop. This will result in referecing wrong L2 entry when
	 * the destination host is in the same subnet as WAN.
	 */

	/*Although chip is in 8650 compatible mode,
	some 865XB features are independent to compatibility register*/
	/*Initialize them here if needed*/

	{
		int rev;
		char chipVersion[16];
		rtl8651_getChipVersion(chipVersion, sizeof(chipVersion), &rev);
		if (chipVersion[strlen(chipVersion) - 1] == 'B' || chipVersion[strlen(chipVersion) - 1] == 'C')
		{
			rtl8651_totalExtPortNum = 3;						// this replaces all RTL8651_EXTPORT_NUMBER defines
			rtl8651_allExtPortMask = 0x7 << RTL8651_MAC_NUMBER; // this replaces all RTL8651_EXTPORTMASK defines
		}
	}
	// Disable layer2, layer3 and layer4 function
	// Layer 2 enabled automatically when a VLAN is added
	// Layer 3 enabled automatically when a network interface is added.
	// Layer 4 enabled automatically when an IP address is setup.
	rtl8651_setAsicOperationLayer(1);
	rtl8651_clearAsicCommTable();
	rtl8651_clearAsicL2Table();
	// rtl8651_clearAsicAllTable();//MAY BE OMITTED. FULL_RST clears all tables already.
	rtl8651_setAsicSpanningEnable(FALSE);

	/* Init PHY LED style */
	/*
		#LED = direct mode
		set mode 0x0
		swwb 0xbb804300 21-20 0x2 19-18 $mode 17-16 $mode 15-14 $mode 13-12 $mode 11-10 $mode 9-8 $mode
	*/
	REG32(PIN_MUX_SEL) = (REG32(PIN_MUX_SEL) & ~((3 << 8) | (3 << 10) | (3 << 3) | (1 << 15))) | (1 << 3); // MII mode + UART1 TXD
	REG32(PIN_MUX_SEL2) &= ~((3 << 0) | (3 << 3) | (3 << 6) | (3 << 9) | (3 << 12) | (7 << 15));	   // S0-S3, P0-P1
	REG32(LEDCREG) = (2 << 20) | (0 << 18) | (0 << 16) | (0 << 14) | (0 << 12) | (0 << 10) | (0 << 8); // P0-P5

	miiPhyAddress = -1; /* not ready to use mii port 5 */

	memset(&rtl8651AsicEthernetTable[0], 0, (RTL8651_PORT_NUMBER + rtl8651_totalExtPortNum) * sizeof(rtl8651_tblAsic_ethernet_t));
	/* Record the PHYIDs of physical ports. Default values are 0. */
	rtl8651AsicEthernetTable[0].phyId = 0; /* Default value of port 0's embedded phy id -- 0 */
	rtl8651AsicEthernetTable[0].isGPHY = FALSE;

	if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT1234_RTL8212)
	{
		rtl8651AsicEthernetTable[1].phyId = rtl8651_tblAsicDrvPara.externalPHYId[1];
		rtl8651AsicEthernetTable[2].phyId = rtl8651_tblAsicDrvPara.externalPHYId[2];
		rtl8651AsicEthernetTable[3].phyId = rtl8651_tblAsicDrvPara.externalPHYId[3];
		rtl8651AsicEthernetTable[4].phyId = rtl8651_tblAsicDrvPara.externalPHYId[4];
		rtl8651AsicEthernetTable[1].isGPHY = TRUE;
		rtl8651AsicEthernetTable[2].isGPHY = TRUE;
		rtl8651AsicEthernetTable[3].isGPHY = TRUE;
		rtl8651AsicEthernetTable[4].isGPHY = TRUE;
	}
	else
	{										   /* USE internal 10/100 PHY */
		rtl8651AsicEthernetTable[1].phyId = 1; /* Default value of port 1's embedded phy id -- 1 */
		rtl8651AsicEthernetTable[2].phyId = 2; /* Default value of port 2's embedded phy id -- 2 */
		rtl8651AsicEthernetTable[3].phyId = 3; /* Default value of port 3's embedded phy id -- 3 */
		rtl8651AsicEthernetTable[4].phyId = 4; /* Default value of port 4's embedded phy id -- 4 */
		rtl8651AsicEthernetTable[1].isGPHY = FALSE;
		rtl8651AsicEthernetTable[2].isGPHY = FALSE;
		rtl8651AsicEthernetTable[3].isGPHY = FALSE;
		rtl8651AsicEthernetTable[4].isGPHY = FALSE;
	}

	if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT5_RTL8211B)
	{
		rtl8651AsicEthernetTable[RTL8651_MII_PORTNUMBER].phyId = rtl8651_tblAsicDrvPara.externalPHYId[5];
		rtl8651AsicEthernetTable[RTL8651_MII_PORTNUMBER].isGPHY = TRUE;
		rtl8651_setAsicEthernetMII(rtl8651AsicEthernetTable[RTL8651_MII_PORTNUMBER].phyId,
								   P5_LINK_RGMII,
								   TRUE);
	}

	/* Initialize MIB counters */
	rtl8651_clearAsicCounter();

	rtl865xC_setNetDecisionPolicy(NETIF_VLAN_BASED); /* Net interface Multilayer-Decision-Based Control -- Set to VLAN-Based mode. */

	WRITE_MEM32(VCR0, READ_MEM32(VCR0) & (~EN_ALL_PORT_VLAN_INGRESS_FILTER)); /* Disable VLAN ingress filter of all ports */ /* Please reference to the maintis bug 2656# */
	WRITE_MEM32(SWTCR0, READ_MEM32(SWTCR0) & ~WAN_ROUTE_MASK);																 // Set WAN route toEnable (Allow traffic from WAN port to WAN port)
	WRITE_MEM32(SWTCR0, READ_MEM32(SWTCR0) | NAPTF2CPU);																	 // When packet destination to switch. Just send to CPU
	WRITE_MEM32(SWTCR0, (READ_MEM32(SWTCR0) & (~LIMDBC_MASK)) | LIMDBC_VLAN);												 // When packet destination to switch. Just send to CPU
	WRITE_MEM32(FFCR, READ_MEM32(FFCR) & ~EN_UNUNICAST_TOCPU);
	WRITE_MEM32(FFCR, READ_MEM32(FFCR) | EN_UNMCAST_TOCPU);
	WRITE_MEM32(CSCR, READ_MEM32(CSCR) & ~ALLOW_L2_CHKSUM_ERR); // Don't allow chcksum error pkt be forwarded.
	WRITE_MEM32(CSCR, READ_MEM32(CSCR) & ~ALLOW_L3_CHKSUM_ERR);
	WRITE_MEM32(CSCR, READ_MEM32(CSCR) & ~ALLOW_L4_CHKSUM_ERR);
	WRITE_MEM32(CSCR, READ_MEM32(CSCR) | EN_ETHER_L3_CHKSUM_REC); // Enable L3 checksum Re-calculation
	WRITE_MEM32(CSCR, READ_MEM32(CSCR) | EN_ETHER_L4_CHKSUM_REC); // Enable L4 checksum Re-calculation

	// Set all Protocol-Based Reg. to 0

	for (index = 0; index < 32; index++)
		WRITE_MEM32(PBVCR0 + index * 4, 0x00000000);

	for (index = 0; index < RTL8651_PORT_NUMBER + rtl8651_totalExtPortNum; index++)
	{

		if (rtl8651_setAsicMulticastSpanningTreePortState(index, RTL8651_PORTSTA_FORWARDING))
			return FAILED;
		rtl865xC_setAsicSpanningTreePortState(index, RTL8651_PORTSTA_FORWARDING);
		rtl8651_setAsicEthernetBandwidthControl(index, TRUE, RTL8651_BC_FULL);
		rtl8651_setAsicEthernetBandwidthControl(index, FALSE, RTL8651_BC_FULL);
	}

	/* Initiate Bandwidth control backward compatible mode : Set all of them to FULL-Rate */
	{
		int32 portIdx, typeIdx;
		_rtl865xB_BandwidthCtrlMultiplier = _RTL865XB_BANDWIDTHCTRL_X1;
		for (portIdx = 0; portIdx < RTL8651_PORT_NUMBER; portIdx++)
		{
			for (typeIdx = 0; typeIdx < _RTL865XB_BANDWIDTHCTRL_CFGTYPE; typeIdx++)
			{
				_rtl865xB_BandwidthCtrlPerPortConfiguration[portIdx][typeIdx] = BW_FULL_RATE;
			}
		}
		/* Sync the configuration to ASIC */
		_rtl8651_syncToAsicEthernetBandwidthControl();
	}

	/* ==================================================================================================
		Embedded PHY patch -- According to the designer, internal PHY's parameters need to be adjusted.
	 ================================================================================================== */
	if (RTL865X_PHY6_DSP_BUG) /*modified by Mark*/
	{
		rtl8651_setAsicEthernetPHYReg(6, 9, 0x0505);
		rtl8651_setAsicEthernetPHYReg(6, 4, 0x1F10);
		rtl8651_setAsicEthernetPHYReg(6, 0, 0x1200);
	}

	/* ===============================
		=============================== */
	{
		uint32 port;
		uint32 maxPort;

		maxPort = (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT5_RTL8211B) ? RTL8651_MAC_NUMBER : RTL8651_PHY_NUMBER;

		for (port = 0; port < maxPort; port++)
		{
			rtl8651_setAsicFlowControlRegister(port, TRUE);
			rtl865xC_setAsicPortPauseFlowControl(port, TRUE, TRUE);
		}
	}

	/* ===============================
		EEE setup
		=============================== */
	eee_enabled = 0;

	if (eee_enabled)
	{
		enable_EEE();
	}
	else
	{
		disable_EEE();
	}

	/* ===============================
		(1) Handling port 0.
		=============================== */
	rtl8651_restartAsicEthernetPHYNway(0); /* Restart N-way of port 0 to let embedded phy patch take effect. */

	/* ===============================
		(2) Handling port 1 - port 4.
		=============================== */
	if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT1234_RTL8212)
	{
	}
	else
	{
		/* Restart N-way of port 1 - port 4 to let embedded phy patch take effect. */
		{
			uint32 port;

			/* Restart N-way of port 1 - port 4 */
			for (port = 1; port < RTL8651_PHY_NUMBER; port++)
			{
				rtl8651_restartAsicEthernetPHYNway(port);
			}
		}
	}

	/* ===============================
		(3) Handling port 5.
		=============================== */

	/* =====================
		QoS-related patch
		===================== */
	{
#define DEFAULT_ILB_UBOUND 0x3FBE /*added by Mark for suggested Leacky Bucket value*/
#define DEFAULT_ILB_LBOUND 0x3FBC

		uint32 token, tick, hiThreshold, i;
		rtl8651_getAsicLBParameter(&token, &tick, &hiThreshold);
		hiThreshold = 0x400; /* New default vlue. */
		rtl8651_setAsicLBParameter(token, tick, hiThreshold);
		/*Mantis(2307): Ingress leaky bucket need to be initized with suggested value . added by mark*/
		WRITE_MEM32(ILBPCR1, DEFAULT_ILB_UBOUND << UpperBound_OFFSET | DEFAULT_ILB_LBOUND << LowerBound_OFFSET);
		for (i = 0; i <= (RTL8651_PHY_NUMBER / 2); i++) /*Current Token Register is 2 bytes per port*/
			WRITE_MEM32(ILB_CURRENT_TOKEN + 4 * i, DEFAULT_ILB_UBOUND << UpperBound_OFFSET | DEFAULT_ILB_UBOUND);
	}

	/*
		Init QUEUE Number configuration for RTL865xC : For Port 0~5 and CPU Port - All ports have 1 queue for each.
	*/
	{
		/* DSP bug (PHY-ID for DSP controller is set same as PHY 0 ) in RTL865xC A-Cut */
		if (RTL865X_PHY6_DSP_BUG)
			/* correct the default value of input queue flow control threshold */
			WRITE_MEM32(IQFCTCR, 0xC8 << IQ_DSC_FCON_OFFSET | 0x96 << IQ_DSC_FCOFF_OFFSET);

		if (RTL865X_IQFCTCR_DEFAULT_VALUE_BUG)
		{
			rtl8651_setAsicSystemInputFlowControlRegister(0xc8, 0x96); /* Configure the ASIC Input Queue Flow control threshold to the default value ( ASIC default value is opposite from correct ) */
		}
	}

	/* set default include IFG */
	WRITE_MEM32(QOSFCR, BC_withPIFG_MASK);

	{
		rtl8651_setAsicPriorityDecision(2, 1, 1, 1, 1);

		WRITE_MEM32(PBPCR, 0);

		/*	clear dscp priority assignment, otherwise, pkt with dscp value 0 will be assign priority 1		*/
		WRITE_MEM32(DSCPCR0, 0);
		WRITE_MEM32(DSCPCR1, 0);
		WRITE_MEM32(DSCPCR2, 0);
		WRITE_MEM32(DSCPCR3, 0);
		WRITE_MEM32(DSCPCR4, 0);
		WRITE_MEM32(DSCPCR5, 0);
		WRITE_MEM32(DSCPCR6, 0);
	}

#define GMII_PIN_MUX 0xf00
	// WRITE_MEM32(PIN_MUX_SEL_2, 0);

	WRITE_MEM32(PCRP0, READ_MEM32(PCRP0) & ~MacSwReset);
	WRITE_MEM32(PCRP1, READ_MEM32(PCRP1) & ~MacSwReset);
	WRITE_MEM32(PCRP2, READ_MEM32(PCRP2) & ~MacSwReset);
	WRITE_MEM32(PCRP3, READ_MEM32(PCRP3) & ~MacSwReset);
	WRITE_MEM32(PCRP4, READ_MEM32(PCRP4) & ~MacSwReset);
	WRITE_MEM32(PCRP0, READ_MEM32(PCRP0) | ((0 << ExtPHYID_OFFSET) | EnablePHYIf | MacSwReset)); /* Jumbo Frame */
	WRITE_MEM32(PCRP1, READ_MEM32(PCRP1) | ((1 << ExtPHYID_OFFSET) | EnablePHYIf | MacSwReset)); /* Jumbo Frame */
	WRITE_MEM32(PCRP2, READ_MEM32(PCRP2) | ((2 << ExtPHYID_OFFSET) | EnablePHYIf | MacSwReset)); /* Jumbo Frame */
	WRITE_MEM32(PCRP3, READ_MEM32(PCRP3) | ((3 << ExtPHYID_OFFSET) | EnablePHYIf | MacSwReset)); /* Jumbo Frame */
	WRITE_MEM32(PCRP4, READ_MEM32(PCRP4) | ((4 << ExtPHYID_OFFSET) | EnablePHYIf | MacSwReset)); /* Jumbo Frame */
	WRITE_MEM32(PCRP0, (REG32(PCRP0) & (0xFFFFFFFF - (MacSwReset))));
	WRITE_MEM32(PCRP0, (REG32(PCRP0) | (0 << ExtPHYID_OFFSET) | EnablePHYIf | MacSwReset));

	{

		P0phymode = 1;

		if (((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES) ||
			((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES1) ||
			((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES2) ||
			((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES3))
		{
			P0phymode = Get_P0_PhyMode();
		}

		if (P0phymode == 1) // embedded phy
		{
			REG32(PCRP0) |= (0 << ExtPHYID_OFFSET) | EnablePHYIf | MacSwReset;
		}
		else // external phy
		{
			P0miimode = Get_P0_MiiMode();

			REG32(PCRP0) |= (0x06 << ExtPHYID_OFFSET) | MIIcfg_RXER | EnablePHYIf | MacSwReset; // external

			if (P0miimode == 0)
				REG32_ANDOR(P0GMIICR, ~(3 << 23), LINK_MII_PHY << 23);
			else if (P0miimode == 1)
				REG32_ANDOR(P0GMIICR, ~(3 << 23), LINK_MII_MAC << 23);
			else if (P0miimode == 2)
				REG32_ANDOR(P0GMIICR, ~(3 << 23), LINK_MII_MAC << 23); // GMII
			else if (P0miimode == 3)
				REG32_ANDOR(P0GMIICR, ~(3 << 23), LINK_RGMII << 23);

			if (P0miimode == 3)
			{
				P0txdly = Get_P0_TxDelay();
				P0rxdly = Get_P0_RxDelay();
				REG32_ANDOR(P0GMIICR, ~((1 << 4) | (3 << 0)), (P0txdly << 4) | (P0rxdly << 0));
			}

			if (P0miimode == 0)
				REG32_ANDOR(PCRP0, ~AutoNegoSts_MASK, EnForceMode | ForceLink | ForceSpeed100M | ForceDuplex);
			else if (P0miimode == 1)
				REG32_ANDOR(PCRP0, ~AutoNegoSts_MASK, EnForceMode | ForceLink | ForceSpeed100M | ForceDuplex);
			else if (P0miimode == 2)
				REG32_ANDOR(PCRP0, ~AutoNegoSts_MASK, EnForceMode | ForceLink | ForceSpeed1000M | ForceDuplex);
			else if (P0miimode == 3)
				REG32_ANDOR(PCRP0, ~AutoNegoSts_MASK, EnForceMode | ForceLink | ForceSpeed1000M | ForceDuplex);

			REG32(PITCR) |= (1 << 0); // 00: embedded , 01L GMII/MII/RGMII

			if ((P0miimode == 2) || (P0miimode == 3))
			{
				REG32(MACCR) |= (1 << 12); // giga link
			}
			REG32(P0GMIICR) |= (Conf_done);
		}
	}

	if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT5_RTL8211B)
	{
		WRITE_MEM32(PCRP5, ((READ_MEM32(PCRP5)) | (rtl8651AsicEthernetTable[5].phyId << ExtPHYID_OFFSET) | EnablePHYIf)); /* Jumbo Frame */
	}

	if (RTL865X_PHY6_DSP_BUG)
		WRITE_MEM32(PCRP6, (READ_MEM32(PCRP6) | (6 << ExtPHYID_OFFSET) | EnablePHYIf));
	/* Set PHYID 6 to PCRP6. (By default, PHYID of PCRP6 is 0. It will collide with PHYID of port 0. */

	/*disable pattern match*/
	{
		int pnum;
		for (pnum = 0; pnum < RTL8651_PORT_NUMBER; pnum++)
		{
			rtl8651_setAsicPortPatternMatch(pnum, 0, 0, 0x2);
		}
	}

	if (((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES) ||
		((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES1) ||
		((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES2) ||
		((REG32(BOND_OPTION) & BOND_ID_MASK) == BOND_8196ES3))
	{
		uint32 statCtrlReg0;

		for (index = 1; index < 5; index++)
		{
			/* read current PHY reg 0 value */
			rtl8651_getAsicEthernetPHYReg(index, 0, &statCtrlReg0);

			REG32(PCRP0 + (index * 4)) |= EnForceMode;
			statCtrlReg0 |= POWER_DOWN;

			/* write PHY reg 0 */
			rtl8651_setAsicEthernetPHYReg(index, 0, statCtrlReg0);
		}
	}

#if defined(PATCH_GPIO_FOR_LED)
	REG32(PIN_MUX_SEL2) |= (0x3FFF);
#endif

	/*
	 * Initialize L2 multicast/broadcast handling (CRITICAL for L2 operation)
	 *
	 * Enable ASIC multicast/broadcast frame processing. This is essential for
	 * basic L2 switch operation and must be configured even when L3 routing
	 * is disabled.
	 *
	 * Without this initialization:
	 *   - ARP broadcasts will fail with CRC errors
	 *   - Ethernet multicast frames will not be forwarded correctly
	 *   - DHCP, mDNS, and other broadcast-based protocols will not work
	 *
	 * All ports are configured as 'internal' to form a single broadcast domain,
	 * allowing proper ARP resolution and multicast forwarding between all ports.
	 *
	 * Note: Despite the 'multicast' naming, these functions control L2 MAC-level
	 * broadcast/multicast handling, NOT L3 IP multicast routing.
	 */
	rtl8651_setAsicMulticastEnable(TRUE);
	for (index = 0; index < RTL8651_PORT_NUMBER + rtl8651_totalExtPortNum; index++)
	{
		if (rtl8651_setAsicMulticastPortInternal(index, TRUE) != SUCCESS)
		{
			rtlglue_printf("Warning: Failed to init multicast for port %d\n", index);
		}
	}

	return SUCCESS;
}

int32 rtl8651_setAsicPortPatternMatch(uint32 port, uint32 pattern, uint32 patternMask, int32 operation)
{
	// not for ext port
	if (port >= RTL8651_PORT_NUMBER)
		return FAILED;

	if (pattern == 0 && patternMask == 0)
	{
		// bit 0~13 is reseved...
		// if((READ_MEM32(PPMAR)&0x2000)==0) //system pattern match not enabled.
		// return SUCCESS;
		WRITE_MEM32(PPMAR, READ_MEM32(PPMAR) & ~(1 << (port + 26)));
		if ((READ_MEM32(PPMAR) & 0xfc000000) == 0)
			WRITE_MEM32(PPMAR, READ_MEM32(PPMAR) & ~(1 << 13)); // turn off system pattern match switch.

		return SUCCESS;
	}
	if (operation > 3)
		return FAILED;																						// valid operations: 0(drop), 1(mirror to cpu),2(fwd to cpu), 3(to mirror port)
	WRITE_MEM32(PPMAR, READ_MEM32(PPMAR) | ((1 << (port + 26)) | (1 << 13)));								// turn on system pattern match and turn on pattern match on indicated port.
	WRITE_MEM32(PPMAR, (READ_MEM32(PPMAR) & (~(0x3 << (14 + 2 * port)))) | (operation << (14 + 2 * port))); // specify operation
	WRITE_MEM32(PATP0 + 4 * port, pattern);
	WRITE_MEM32(MASKP0 + 4 * port, patternMask);
	return SUCCESS;
}

/*
@func int32		| rtl8651_setAsicSpanningEnable 	| Enable/disable ASIC spanning tree support
@parm int8		| spanningTreeEnabled | TRUE to indicate spanning tree is enabled; FALSE to indicate spanning tree is disabled.
@rvalue SUCCESS	| 	Success
@comm
Global switch to enable or disable ASIC spanning tree support.
If ASIC spanning tree support is enabled, further configuration would be refered by ASIC to prcoess packet forwarding / MAC learning.
If ASIC spanning tree support is disabled, all MAC learning and packet forwarding would be done regardless of port state.
Note that the configuration does not take effect for spanning tree BPDU CPU trapping. It is set in <p rtl8651_setAsicResvMcastAddrToCPU()>.
@xref <p rtl8651_setAsicMulticastSpanningTreePortState()>, <p rtl865xC_setAsicSpanningTreePortState()>, <p rtl8651_getAsicMulticastSpanningTreePortState()>, <p rtl865xC_getAsicSpanningTreePortState()>
 */
int32 rtl8651_setAsicSpanningEnable(int8 spanningTreeEnabled)
{
	if (spanningTreeEnabled == TRUE)
	{
		WRITE_MEM32(MSCR, READ_MEM32(MSCR) | (EN_STP));
		WRITE_MEM32(RMACR, READ_MEM32(RMACR) | MADDR00);
	}
	else
	{
		WRITE_MEM32(MSCR, READ_MEM32(MSCR) & ~(EN_STP));
		WRITE_MEM32(RMACR, READ_MEM32(RMACR) & ~MADDR00);
	}
	return SUCCESS;
}

/*
@func int32		| rtl8651_getAsicSpanningEnable 	| Getting the ASIC spanning tree support status
@parm int8*		| spanningTreeEnabled | The pointer to get the status of ASIC spanning tree configuration status.
@rvalue FAILED	| 	Failed
@rvalue SUCCESS	| 	Success
@comm
Get the ASIC global switch to enable or disable ASIC spanning tree support.
The switch can be set by calling <p rtl8651_setAsicSpanningEnable()>
@xref <p rtl8651_setAsicSpanningEnable()>, <p rtl8651_setAsicMulticastSpanningTreePortState()>, <p rtl865xC_setAsicSpanningTreePortState()>, <p rtl8651_getAsicMulticastSpanningTreePortState()>, <p rtl865xC_getAsicSpanningTreePortState()>
 */

/*
@func int32		| rtl865xC_setAsicSpanningTreePortState 	| Configure Spanning Tree Protocol Port State
@parm uint32 | port | port number under consideration
@parm uint32 | portState | Spanning tree port state: RTL8651_PORTSTA_DISABLED, RTL8651_PORTSTA_BLOCKING, RTL8651_PORTSTA_LISTENING, RTL8651_PORTSTA_LEARNING, RTL8651_PORTSTA_FORWARDING
@rvalue SUCCESS	| 	Success
@rvalue FAILED | Failed
@comm
Config IEEE 802.1D spanning tree port sate into ASIC.
 */
int32 rtl865xC_setAsicSpanningTreePortState(uint32 port, uint32 portState)
{
	uint32 offset = port * 4;

	if (port >= RTL865XC_PORT_NUMBER)
		return FAILED;

	switch (portState)
	{
	case RTL8651_PORTSTA_DISABLED:
		WRITE_MEM32(PCRP0 + offset, (READ_MEM32(PCRP0 + offset) & (~STP_PortST_MASK)) | STP_PortST_DISABLE);
		break;
	case RTL8651_PORTSTA_BLOCKING:
	case RTL8651_PORTSTA_LISTENING:
		WRITE_MEM32(PCRP0 + offset, (READ_MEM32(PCRP0 + offset) & (~STP_PortST_MASK)) | STP_PortST_BLOCKING);
		break;
	case RTL8651_PORTSTA_LEARNING:
		WRITE_MEM32(PCRP0 + offset, (READ_MEM32(PCRP0 + offset) & (~STP_PortST_MASK)) | STP_PortST_LEARNING);
		break;
	case RTL8651_PORTSTA_FORWARDING:
		WRITE_MEM32(PCRP0 + offset, (READ_MEM32(PCRP0 + offset) & (~STP_PortST_MASK)) | STP_PortST_FORWARDING);
		break;
	default:
		return FAILED;
	}

	TOGGLE_BIT_IN_REG_TWICE(PCRP0 + offset, EnForceMode);
	return SUCCESS;
}

/*
@func int32		| rtl865xC_getAsicSpanningTreePortState 	| Retrieve Spanning Tree Protocol Port State
@parm uint32 | port | port number under consideration
@parm uint32 | portState | pointer to memory to store the port state
@rvalue SUCCESS	| 	Success
@rvalue FAILED | Failed
@comm
Possible spanning tree port state: RTL8651_PORTSTA_DISABLED, RTL8651_PORTSTA_BLOCKING, RTL8651_PORTSTA_LISTENING, RTL8651_PORTSTA_LEARNING, RTL8651_PORTSTA_FORWARDING
 */

/*
@func int32		| rtl8651_setAsicMulticastSpanningTreePortState 	| Configure Multicast Spanning Tree Protocol Port State
@parm uint32 | port | port number under consideration
@parm uint32 | portState | Spanning tree port state: RTL8651_PORTSTA_DISABLED, RTL8651_PORTSTA_BLOCKING, RTL8651_PORTSTA_LISTENING, RTL8651_PORTSTA_LEARNING, RTL8651_PORTSTA_FORWARDING
@rvalue SUCCESS	| 	Success
@rvalue FAILED | Failed
@comm
In RTL865xC platform, Multicast spanning tree configuration is set by this API.
@xref  <p rtl865xC_setAsicSpanningTreePortState()>
 */
int32 rtl8651_setAsicMulticastSpanningTreePortState(uint32 port, uint32 portState)
{

	return SUCCESS;
}

/*
@func int32		| rtl8651_getAsicMulticastSpanningTreePortState 	| Retrieve Spanning Tree Protocol Port State
@parm uint32 | port | port number under consideration
@parm uint32 | portState | pointer to memory to store the port state
@rvalue SUCCESS	| 	Success
@rvalue FAILED | Failed
@comm
In RTL865xC platform, Multicast spanning tree configuration is gotten by this API.
@xref  <p rtl865xC_getAsicSpanningTreePortState()>
 */

/*=========================================
 * ASIC DRIVER API: MDC/MDIO Control
 *=========================================*/

int32 rtl8651_getAsicEthernetPHYReg(uint32 phyId, uint32 regId, uint32 *rData)
{
	uint32 status;

	WRITE_MEM32(MDCIOCR, COMMAND_READ | (phyId << PHYADD_OFFSET) | (regId << REGADD_OFFSET));

	do
	{
		status = READ_MEM32(MDCIOSR);
	} while ((status & MDC_STATUS) != 0);

	status &= 0xffff;
	*rData = status;

	return SUCCESS;
}

int32 rtl8651_setAsicEthernetPHYReg(uint32 phyId, uint32 regId, uint32 wData)
{
	WRITE_MEM32(MDCIOCR, COMMAND_WRITE | (phyId << PHYADD_OFFSET) | (regId << REGADD_OFFSET) | wData);

	while ((READ_MEM32(MDCIOSR) & MDC_STATUS) != 0)
		; /* wait until command complete */

	return SUCCESS;
}


int32 rtl8651_restartAsicEthernetPHYNway(uint32 port)
{
	uint32 statCtrlReg0, phyid;

	/* port number validation */
	if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT5_RTL8211B)
	{
		if (port > RTL8651_MAC_NUMBER)
		{
			return FAILED;
		}
	}
	else
	{
		if (port > RTL8651_PHY_NUMBER)
		{
			return FAILED;
		}
	}

	/* PHY id determination */
	phyid = rtl8651AsicEthernetTable[port].phyId;

	/* read current PHY reg 0 */
	rtl8651_getAsicEthernetPHYReg(phyid, 0, &statCtrlReg0);

	/* enable 'restart Nway' bit */
	statCtrlReg0 |= RESTART_AUTONEGO;

	/* write PHY reg 0 */
	rtl8651_setAsicEthernetPHYReg(phyid, 0, statCtrlReg0);

	return SUCCESS;
}

int32 rtl865xC_setAsicPortPauseFlowControl(uint32 port, uint8 rxEn, uint8 txEn)
{
	uint32 offset = port << 2;
	uint32 pauseFC = 0;

	if (rxEn != 0)
		pauseFC |= PauseFlowControlDtxErx;
	if (txEn != 0)
		pauseFC |= PauseFlowControlEtxDrx;

	WRITE_MEM32(PCRP0 + offset, (~(PauseFlowControl_MASK) & (READ_MEM32(PCRP0 + offset))) | pauseFC);

	TOGGLE_BIT_IN_REG_TWICE(PCRP0 + offset, EnForceMode);
	return SUCCESS;
}

/*=========================================
 * ASIC DRIVER API: ETHERNET MII
 *=========================================*/
int32 rtl865xC_setAsicEthernetMIIMode(uint32 port, uint32 mode)
{
	if (port != 0 && port != RTL8651_MII_PORTNUMBER)
		return FAILED;
	if (mode != LINK_RGMII && mode != LINK_MII_MAC && mode != LINK_MII_PHY)
		return FAILED;

	if (port == 0)
	{
		/* MII port MAC interface mode configuration */
		WRITE_MEM32(P0GMIICR, (READ_MEM32(P0GMIICR) & ~CFG_GMAC_MASK) | (mode << LINKMODE_OFFSET));
	}
	else
	{
		/* MII port MAC interface mode configuration */
		WRITE_MEM32(P5GMIICR, (READ_MEM32(P5GMIICR) & ~CFG_GMAC_MASK) | (mode << LINKMODE_OFFSET));
	}
	return SUCCESS;
}

int32 rtl865xC_setAsicEthernetRGMIITiming(uint32 port, uint32 Tcomp, uint32 Rcomp)
{
	if (port != 0 && port != RTL8651_MII_PORTNUMBER)
		return FAILED;
	if (Tcomp < RGMII_TCOMP_0NS || Tcomp > RGMII_TCOMP_7NS || Rcomp < RGMII_RCOMP_0NS || Rcomp > RGMII_RCOMP_2DOT5NS)
		return FAILED;

	if (port == 0)
	{
		WRITE_MEM32(P0GMIICR, (((READ_MEM32(P0GMIICR) & ~RGMII_TCOMP_MASK) | Tcomp) & ~RGMII_RCOMP_MASK) | Rcomp);
	}
	else
	{
		WRITE_MEM32(P5GMIICR, (((READ_MEM32(P5GMIICR) & ~RGMII_TCOMP_MASK) | Tcomp) & ~RGMII_RCOMP_MASK) | Rcomp);
	}

	return SUCCESS;
}

/* For backward-compatible issue, this API is used to set MII port 5. */
int32 rtl8651_setAsicEthernetMII(uint32 phyAddress, int32 mode, int32 enabled)
{
	/* Input validation */
	if (phyAddress < 0 || phyAddress > 31)
		return FAILED;
	if (mode != P5_LINK_RGMII && mode != P5_LINK_MII_MAC && mode != P5_LINK_MII_PHY)
		return FAILED;

	/* Configure driver level information about mii port 5 */
	if (enabled)
	{
		if (miiPhyAddress >= 0 && miiPhyAddress != phyAddress)
			return FAILED;

		miiPhyAddress = phyAddress;
	}
	else
	{
		miiPhyAddress = -1;
	}

	/* MII port MAC interface mode configuration */
	WRITE_MEM32(P5GMIICR, (READ_MEM32(P5GMIICR) & ~CFG_GMAC_MASK) | (mode << P5_LINK_OFFSET));

	return SUCCESS;
}

/*=========================================
 * ASIC DRIVER API: Packet Scheduling Control Register
 *=========================================*/
/*
@func int32 | rtl8651_setAsicPriorityDecision | set priority selection
@parm uint32 | portpri | output queue decision priority assign for Port Based Priority.
@parm uint32 | dot1qpri | output queue decision priority assign for 1Q Based Priority.
@parm uint32 | dscppri | output queue decision priority assign for DSCP Based Priority
@parm uint32 | aclpri | output queue decision priority assign for ACL Based Priority.
@parm uint32 | natpri | output queue decision priority assign for NAT Based Priority.
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_setAsicPriorityDecision(uint32 portpri, uint32 dot1qpri, uint32 dscppri, uint32 aclpri, uint32 natpri)
{
	/* Invalid input parameter */
	if ((portpri < 0) || (portpri > 0xF) || (dot1qpri < 0) || (dot1qpri > 0xF) ||
		(dscppri < 0) || (dscppri > 0xF) || (aclpri < 0) || (aclpri > 0xF) ||
		(natpri < 0) || (natpri > 0xF))
		return FAILED;

	WRITE_MEM32(QIDDPCR, (portpri << PBP_PRI_OFFSET) | (dot1qpri << BP8021Q_PRI_OFFSET) |
							 (dscppri << DSCP_PRI_OFFSET) | (aclpri << ACL_PRI_OFFSET) |
							 (natpri << NAPT_PRI_OFFSET));

	return SUCCESS;
}

/*
@func int32 | rtl8651_setAsicLBParameter | set Leaky Bucket Paramters
@parm uint32 | token | Token is used for adding budget in each time slot.
@parm uint32 | tick | Tick is used for time slot size slot.
@parm uint32 | hiThreshold | leaky bucket token high-threshold register
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_setAsicLBParameter(uint32 token, uint32 tick, uint32 hiThreshold)
{
	WRITE_MEM32(ELBPCR, (READ_MEM32(ELBPCR) & ~(Token_MASK | Tick_MASK)) | (token << Token_OFFSET) | (tick << Tick_OFFSET));
	WRITE_MEM32(ELBTTCR, (READ_MEM32(ELBTTCR) & ~0xFFFF /*L2_MASK*/) | (hiThreshold << L2_OFFSET));
	WRITE_MEM32(ILBPCR2, (READ_MEM32(ILBPCR2) & ~(ILB_feedToken_MASK | ILB_Tick_MASK)) | (token << ILB_feedToken_OFFSET) | (tick << ILB_Tick_OFFSET));
	return SUCCESS;
}

/*
@func int32 | rtl8651_getAsicLBParameter | get Leaky Bucket Paramters
@parm uint32* | pToken | pointer to return token
@parm uint32* | pTick | pointer to return tick
@parm uint32* | pHiThreshold | pointer to return hiThreshold
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_getAsicLBParameter(uint32 *pToken, uint32 *pTick, uint32 *pHiThreshold)
{
	uint32 regValue;

	regValue = READ_MEM32(ELBPCR);

	if (pToken != NULL)
		*pToken = (regValue & Token_MASK) >> Token_OFFSET;
	if (pTick != NULL)
		*pTick = (regValue & Tick_MASK) >> Tick_OFFSET;
	if (pHiThreshold != NULL)
		*pHiThreshold = (READ_MEM32(ELBTTCR) & 0xFF) >> L2_OFFSET;

	return SUCCESS;
}

/*
@func int32 | rtl8651_setAsicPortIngressBandwidth | set per-port total ingress bandwidth
@parm enum PORTID | port | the port number
@parm uint32 | bandwidth | the total ingress bandwidth (unit: 16Kbps), 0:disable
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_setAsicPortIngressBandwidth(enum PORTID port, uint32 bandwidth)
{
	uint32 reg1;

	/* For ingress bandwidth control, its only for PHY0 to PHY5 */
	if ((port < PHY0) || (port > PHY5))
		return FAILED;

	reg1 = IBCR0 + ((port / 2) * 0x04); /* offset to get corresponding register */

	if (port % 2)
	{ /* ODD-port */
		WRITE_MEM32(reg1, ((READ_MEM32(reg1) & ~(IBWC_ODDPORT_MASK)) | ((bandwidth << IBWC_ODDPORT_OFFSET) & IBWC_ODDPORT_MASK)));
	}
	else
	{ /* EVEN-port */
		WRITE_MEM32(reg1, ((READ_MEM32(reg1) & ~(IBWC_EVENPORT_MASK)) | ((bandwidth << IBWC_EVENPORT_OFFSET) & IBWC_EVENPORT_MASK)));
	}

	return SUCCESS;
}

/*
@func int32 | rtl8651_getAsicPortIngressBandwidth | get per-port total ingress bandwidth
@parm enum PORTID | port | the port number
@parm uint32* | pBandwidth | pointer to the returned total ingress bandwidth (unit: 16Kbps), 0:disable
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_getAsicPortIngressBandwidth(enum PORTID port, uint32 *pBandwidth)
{
	uint32 reg1, regValue;

	/* For ingress bandwidth control, its only for PHY0 to PHY5 */
	if ((port < PHY0) || (port > PHY5))
		return FAILED;

	reg1 = IBCR0 + ((port / 2) * 0x04); /* offset to get corresponding register */

	regValue = READ_MEM32(reg1);

	if (pBandwidth != NULL)
	{
		*pBandwidth = (port % 2) ?
								 /* Odd port */ ((regValue & IBWC_ODDPORT_MASK) >> IBWC_ODDPORT_OFFSET)
								 :
								 /* Even port */ ((regValue & IBWC_EVENPORT_MASK) >> IBWC_EVENPORT_OFFSET);
	}

	return SUCCESS;
}

/*
@func int32 | rtl8651_setAsicPortEgressBandwidth | set per-port total egress bandwidth
@parm enum PORTID | port | the port number
@parm uint32 | bandwidth | the total egress bandwidth (unit: 64kbps). 0x3FFF: disable
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_setAsicPortEgressBandwidth(enum PORTID port, uint32 bandwidth)
{
	uint32 reg1;

	if ((port < PHY0) || (port > CPU))
		return FAILED;

	reg1 = WFQRCRP0 + (port * 0xC); /* offset to get corresponding register */
	WRITE_MEM32(reg1, (READ_MEM32(reg1) & ~(APR_MASK)) | (bandwidth << APR_OFFSET));

	return SUCCESS;
}

/*
@func int32 | rtl8651_getAsicPortEgressBandwidth | get per-port total egress bandwidth
@parm enum PORTID | port | the port number
@parm uint32* | pBandwidth | pointer to the returned total egress bandwidth (unit: 64kbps). 0x3FFF: disable
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_getAsicPortEgressBandwidth(enum PORTID port, uint32 *pBandwidth)
{
	uint32 reg1, regValue;

	if ((port < PHY0) || (port > CPU))
		return FAILED;

	reg1 = WFQRCRP0 + (port * 0xC); /* offset to get corresponding register */
	regValue = READ_MEM32(reg1);

	if (pBandwidth != NULL)
		*pBandwidth = (regValue & APR_MASK) >> APR_OFFSET;

	return SUCCESS;
}

/*
@func int32 | rtl8651_setAsicOutputQueueNumber | set output queue number for a specified port
@parm enum PORTID | port | the port number (valid: physical ports(0~5) and CPU port(6) )
@parm enum QUEUENUM | qnum | the output queue number
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */
int32 rtl8651_setAsicOutputQueueNumber(enum PORTID port, enum QUEUENUM qnum)
{
	/* Invalid input parameter */

	enum QUEUENUM orgQnum;

	if ((port < PHY0) || (port > CPU) || (qnum < QNUM1) || (qnum > QNUM6))
		return FAILED;

	orgQnum = (READ_MEM32(QNUMCR) >> (3 * port)) & 0x7;
	WRITE_MEM32(QNUMCR, (READ_MEM32(QNUMCR) & ~(0x7 << (3 * port))) | (qnum << (3 * port)));

	return SUCCESS;
}

/* 	note: the dynamic mechanism: adjust the flow control threshold value according to the number of Ethernet link up ports.
	buffer threshold setting:
	sys on = 208, share on = 192 for link port <=3
	0xbb804504 = 0x00c000d0
	0xbb804508 = 0x00b000c0

	sys on = 172, share on = 98 , for link port > 3
	0xbb804504 = 0x00A000AC
	0xbb804508 = 0x004A0062

	1. default threshold setting is link port <=3
	2. got link change interrupt and link port > 3, then change threhosld for link port > 3
	3. got link change interrupt and link port <= 3, then change threhosld for link port <= 3
 */

/*
@func int32 | rtl865xC_waitForOutputQueueEmpty | wait until output queue empty
@rvalue SUCCESS |
@comm
	The function will not return until all the output queue is empty.
 */

/*
@func int32 | rtl8651_resetAsicOutputQueue | reset output queue
@rvalue SUCCESS |
@comm
 *	When reset is done, all queue pointer will be reset to the initial base address.
 *
 *
 *	_rtl8651_syncToAsicEthernetBandwidthControl()
 *
 *	Sync SW bandwidth control () configuration to ASIC:
 *
 *
 *		_rtl865xB_BandwidthCtrlPerPortConfiguration -----> Translate from RTL865xB Index to ACTUAL
 *														 	 token count in RTL865xC
 *																		|
 *																---------
 *																|
 *		_rtl865xB_BandwidthCtrlMultiplier	---- Translate using         ---->*
 *										 RTL865xB's mechanism		|
 *																|
 *											---------------------
 *											|
 *											-- > Actual Token count which need to set to ASIC.
 *												 => Set it to ASIC if value in SW is different from ASIC.
 *
 */
static void _rtl8651_syncToAsicEthernetBandwidthControl(void)
{
	uint32 port;
	uint32 cfgTypeIdx;
	int32 retval;

	for (port = 0; port < RTL8651_PORT_NUMBER; port++)
	{
		for (cfgTypeIdx = 0; cfgTypeIdx < _RTL865XB_BANDWIDTHCTRL_CFGTYPE; cfgTypeIdx++)
		{
			uint32 currentSwBandwidthCtrlBasicSetting;
			uint32 currentSwBandwidthCtrlMultiplier;
			uint32 currentSwBandwidthCtrlSetting;
			uint32 currentAsicBandwidthCtrlSetting;

			/*
				We would check for rate and _rtl865xB_BandwidthCtrlMultiplier for the rate-multiply.

				In RTL865xB, the bits definition is as below.

				SWTECR

				bit 14(x8)		bit 15 (x4)		Result
				=============================================
				0				0				x1
				0				1				x4
				1				0				x8
				1				1				x8
			*/
			if (_rtl865xB_BandwidthCtrlMultiplier & _RTL865XB_BANDWIDTHCTRL_X8)
			{ /* case {b'10, b'11} */
				currentSwBandwidthCtrlMultiplier = 8;
			}
			else if (_rtl865xB_BandwidthCtrlMultiplier & _RTL865XB_BANDWIDTHCTRL_X4)
			{ /* case {b'01} */
				currentSwBandwidthCtrlMultiplier = 4;
			}
			else
			{ /* case {b'00} */
				currentSwBandwidthCtrlMultiplier = 1;
			}

			/* Calculate Current SW configuration : 0 : Full Rate */
			/* Mix BASIC setting and Multiplier -> to get the ACTUAL bandwidth setting */

			currentSwBandwidthCtrlBasicSetting = ((_rtl865xC_BandwidthCtrlNum[_rtl865xB_BandwidthCtrlPerPortConfiguration[port][cfgTypeIdx]]) * (currentSwBandwidthCtrlMultiplier));
			currentSwBandwidthCtrlSetting = (cfgTypeIdx == 0) ?
															  /* Ingress */
												(((currentSwBandwidthCtrlBasicSetting % RTL865XC_INGRESS_16KUNIT) < (RTL865XC_INGRESS_16KUNIT >> 1)) ? (currentSwBandwidthCtrlBasicSetting / RTL865XC_INGRESS_16KUNIT) : ((currentSwBandwidthCtrlBasicSetting / RTL865XC_INGRESS_16KUNIT) + 1))
															  :
															  /* Egress */
												(((currentSwBandwidthCtrlBasicSetting % RTL865XC_EGRESS_64KUNIT) < (RTL865XC_EGRESS_64KUNIT >> 1)) ? (currentSwBandwidthCtrlBasicSetting / RTL865XC_EGRESS_64KUNIT) : ((currentSwBandwidthCtrlBasicSetting / RTL865XC_EGRESS_64KUNIT) + 1));

			/* Get Current ASIC configuration */
			retval = (cfgTypeIdx == 0) ?
									   /* Ingress */
						 (rtl8651_getAsicPortIngressBandwidth(port,
															  &currentAsicBandwidthCtrlSetting))
									   :
									   /* Egress */
						 (rtl8651_getAsicPortEgressBandwidth(port,
															 &currentAsicBandwidthCtrlSetting));

			if (retval != SUCCESS)
			{
				assert(0);
				goto out;
			}

			/* SYNC configuration to HW if the configuration is different */
			if ((!((currentSwBandwidthCtrlSetting) == 0 && (currentAsicBandwidthCtrlSetting == 0x3fff)) /* for FULL Rate case */) ||
				(currentSwBandwidthCtrlSetting != currentAsicBandwidthCtrlSetting))
			{
				retval = (cfgTypeIdx == 0) ?
										   /* Ingress */
							 (rtl8651_setAsicPortIngressBandwidth(port,
																  (currentSwBandwidthCtrlSetting == 0) ? (0 /* For Ingress Bandwidth control, 0 means "disabled" */) : (currentSwBandwidthCtrlSetting)))
										   :
										   /* Egress */
							 (rtl8651_setAsicPortEgressBandwidth(port,
																 (currentSwBandwidthCtrlSetting == 0) ? (0x3fff /* For Egress Bandwidth control, 0x3fff means "disabled" */) : (currentSwBandwidthCtrlSetting)));

				if (retval != SUCCESS)
				{
					assert(0);
					goto out;
				}
			}
		}
	}
out:
	return;
}

/*
@func int32 | rtl8651_setAsicEthernetBandwidthControl | set ASIC per-port total ingress bandwidth
@parm uint32 | port | the port number
@parm int8 | input | Ingress or egress control to <p port>
@parm uint32 | rate | rate to set.
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
The <p rate> can be set to several different values:
BW_FULL_RATE
BW_128K
BW_256K
BW_512K
BW_1M
BW_2M
BW_4M
BW_8M

Note: This function is backward compatible to RTL865xB.
 */
int32 rtl8651_setAsicEthernetBandwidthControl(uint32 port, int8 input, uint32 rate)
{
	uint32 *currentConfig_p;

	if (port >= RTL8651_PORT_NUMBER)
	{
		goto err;
	}

	switch (rate)
	{
	case BW_FULL_RATE:
	case BW_128K:
	case BW_256K:
	case BW_512K:
	case BW_1M:
	case BW_2M:
	case BW_4M:
	case BW_8M:
		break;
	default:
		goto err;
	}

	currentConfig_p = &(_rtl865xB_BandwidthCtrlPerPortConfiguration[port][(input) ? 0 /* Ingress */ : 1 /* Egress */]);

	/* We just need to re-config HW when it's updated */
	if (*currentConfig_p != rate)
	{
		/* Update configuration table */
		*currentConfig_p = rate;

		/* sync the configuration to ASIC */
		_rtl8651_syncToAsicEthernetBandwidthControl();
	}

	return SUCCESS;
err:
	return FAILED;
}

int32 rtl8651_setAsicFlowControlRegister(uint32 port, uint32 enable)
{
	uint32 phyid, statCtrlReg4;

	if (rtl8651_tblAsicDrvPara.externalPHYProperty & RTL8651_TBLASIC_EXTPHYPROPERTY_PORT5_RTL8211B)
	{
		if (port > RTL8651_MAC_NUMBER)
		{
			return FAILED;
		}
	}
	else
	{
		if (port > RTL8651_PHY_NUMBER)
		{
			return FAILED;
		}
	}
	/* phy id determination */
	phyid = rtl8651AsicEthernetTable[port].phyId;

	/* Read */
	rtl8651_getAsicEthernetPHYReg(phyid, 4, &statCtrlReg4);

	if (enable && (statCtrlReg4 & CAPABLE_PAUSE) == 0)
	{
		statCtrlReg4 |= CAPABLE_PAUSE;
	}
	else if (enable == 0 && (statCtrlReg4 & CAPABLE_PAUSE))
	{
		statCtrlReg4 &= ~CAPABLE_PAUSE;
	}
	else
		return SUCCESS; /* The configuration does not change. Do nothing. */

	rtl8651_setAsicEthernetPHYReg(phyid, 4, statCtrlReg4);

	/* restart N-way. */
	rtl8651_restartAsicEthernetPHYNway(port);

	return SUCCESS;
}


/*
@func int32 | rtl8651_setAsicSystemInputFlowControlRegister | Set System input queue flow control register
@parm uint32 | fcON		| Threshold for Flow control OFF
@parm uint32 | fcOFF		| Threshold for Flow control ON
@rvalue SUCCESS |
@comm
Set input-queue flow control threshold on RTL865xC platform.
 */
int32 rtl8651_setAsicSystemInputFlowControlRegister(uint32 fcON, uint32 fcOFF)
{
	/* Check the correctness */
	if ((fcON > (IQ_DSC_FCON_MASK >> IQ_DSC_FCON_OFFSET)) ||
		(fcOFF > (IQ_DSC_FCOFF_MASK >> IQ_DSC_FCOFF_OFFSET)))
	{
		return FAILED;
	}

	/* Write the flow control threshold value into ASIC */
	WRITE_MEM32(IQFCTCR,
				((READ_MEM32(IQFCTCR) & ~(IQ_DSC_FCON_MASK | IQ_DSC_FCOFF_MASK)) |
				 (fcON << IQ_DSC_FCON_OFFSET) |
				 (fcOFF << IQ_DSC_FCOFF_OFFSET)));
	return SUCCESS;
}

#define MULTICAST_STORM_CONTROL 1
#define BROADCAST_STORM_CONTROL 2
#define RTL865XC_MAXALLOWED_BYTECOUNT 30360 /* Used for BSCR in RTL865xC. Means max allowable byte count for 10Mbps port */

/*
@func int32 | rtl8651_setAsic802D1xMacBaseAbility | set 802.1x mac based ability
@parm enum PORTID | port | the port number (physical port: 0~5, extension port: 6~8)
@parm uint32* | isEnable | 1: enabled, 0: disabled.
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */

/*
@func int32 | rtl8651_setAsic802D1xMacBaseDirection | set 802.1x mac based direction
@parm enum uint32 | dir | OperCOnntrolledDirections for MAC-Based ACCESS Control. 0:BOTH, 1:IN
@rvalue SUCCESS |
@rvalue FAILED | invalid parameter
@comm
 */

/*
@func int32 | rtl8651_updateAsicLinkAggregatorLMPR | Arrange the table which maps hashed index to port.
@parm	uint32	|	portMask |  Specify the port mask for the aggregator.
@rvalue SUCCESS | Update the mapping table successfully.
@rvalue FAILED | When the port mask is invalid, return FAILED
@comm
RTL865x provides an aggregator port. This API updates the table which maps hashed index to port.
If portmask = 0: clear all aggregation port mappings.
Rearrange policy is round-robin. ie. if port a,b,c is in portmask, then hash block 0~7's port number is a,b,c,a,b,c,a,b
*/

int32 rtl8651_setAsicEthernetLinkStatus(uint32 port, int8 linkUp)
{
	int8 notify;
	//	uint32 portmask;

	if (port >= (RTL8651_PORT_NUMBER + rtl8651_totalExtPortNum))
	{
		return FAILED;
	}

	notify = (rtl8651AsicEthernetTable[port].linkUp != ((linkUp == TRUE) ? TRUE : FALSE)) ? TRUE : FALSE;

	rtl8651AsicEthernetTable[port].linkUp = (linkUp == TRUE) ? TRUE : FALSE;

	return SUCCESS;
}
