// SPDX-License-Identifier: GPL-2.0
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/string.h>
#include "rtl8196e_hw.h"

static inline void rtl8196e_writel(u32 val, u32 reg)
{
	*(volatile u32 *)(reg) = val;
}

static inline u32 rtl8196e_readl(u32 reg)
{
	return *(volatile u32 *)(reg);
}

static int rtl8196e_mdio_wait_ready(void)
{
	int i;

	for (i = 0; i < 1000; i++) {
		if ((rtl8196e_readl(MDCIOSR) & MDC_STATUS) == 0)
			return 0;
		udelay(10);
	}

	return -ETIMEDOUT;
}

static int rtl8196e_mdio_read(int phy, int reg, u16 *val)
{
	int ret;

	rtl8196e_writel(COMMAND_READ | (phy << PHYADD_OFFSET) | (reg << REGADD_OFFSET), MDCIOCR);
	ret = rtl8196e_mdio_wait_ready();
	if (ret)
		return ret;

	*val = rtl8196e_readl(MDCIOSR) & 0xffff;
	return 0;
}

static int rtl8196e_mdio_write(int phy, int reg, u16 val)
{
	rtl8196e_writel(COMMAND_WRITE | (phy << PHYADD_OFFSET) | (reg << REGADD_OFFSET) | val, MDCIOCR);
	return rtl8196e_mdio_wait_ready();
}

static int rtl8196e_table_wait_ready(void)
{
	int i;

	for (i = 0; i < 1000; i++) {
		if ((rtl8196e_readl(TBL_ACCESS_CTRL) & TBL_ACCESS_BUSY) == 0)
			return 0;
		udelay(10);
	}

	return -ETIMEDOUT;
}

static int rtl8196e_tlu_start(void)
{
	u32 tlu;
	int i;

	tlu = rtl8196e_readl(TLU_CTRL);
	rtl8196e_writel(tlu | TLU_CTRL_START, TLU_CTRL);
	for (i = 0; i < 1000; i++) {
		if (rtl8196e_readl(TLU_CTRL) & TLU_CTRL_READY)
			return 0;
		udelay(10);
	}

	return -ETIMEDOUT;
}

static void rtl8196e_tlu_stop(void)
{
	u32 tlu;

	tlu = rtl8196e_readl(TLU_CTRL);
	rtl8196e_writel(tlu & ~(TLU_CTRL_START | TLU_CTRL_READY), TLU_CTRL);
}

static int rtl8196e_table_write(u32 type, u32 index, const u32 *words, u32 nwords)
{
	u32 addr = ASIC_TABLE_BASE + (type << 16) + (index << 5);
	u32 swtcr;
	int ret;
	bool tlu_ok = true;
	u32 i;

	if (!words || nwords == 0 || nwords > 8)
		return -EINVAL;

	ret = rtl8196e_table_wait_ready();
	if (ret)
		return ret;

	ret = rtl8196e_tlu_start();
	if (ret)
		tlu_ok = false;

	swtcr = rtl8196e_readl(SWTCR0);
	rtl8196e_writel(swtcr | SWTCR0_TLU_START, SWTCR0);
	for (i = 0; i < 1000; i++) {
		if (rtl8196e_readl(SWTCR0) & SWTCR0_TLU_BUSY)
			break;
		udelay(10);
	}

	for (i = 0; i < nwords; i++)
		rtl8196e_writel(words[i], TBL_ACCESS_DATA + (i * 4));
	for (; i < 8; i++)
		rtl8196e_writel(0, TBL_ACCESS_DATA + (i * 4));

	rtl8196e_writel(addr, TBL_ACCESS_ADDR);
	rtl8196e_writel(TBL_ACCESS_CMD_WRITE, TBL_ACCESS_CTRL);

	ret = rtl8196e_table_wait_ready();
	rtl8196e_writel(swtcr & ~(SWTCR0_TLU_START | SWTCR0_TLU_BUSY), SWTCR0);
	if (ret)
		goto out_stop;

	if (rtl8196e_readl(TBL_ACCESS_STAT) & 0x1)
		ret = -EIO;

out_stop:
	if (tlu_ok)
		rtl8196e_tlu_stop();

	return ret;
}

static int rtl8196e_l2_write_entry(u32 index, u32 word0, u32 word1)
{
	u32 addr = ASIC_TABLE_BASE + (index << 5);
	u32 swtcr;
	int ret;
	bool tlu_ok = true;
	int i;

	ret = rtl8196e_table_wait_ready();
	if (ret)
		return ret;

	ret = rtl8196e_tlu_start();
	if (ret)
		tlu_ok = false;

	/* Optional SWTCR0 handshake (seen on some vendor flows) */
	swtcr = rtl8196e_readl(SWTCR0);
	rtl8196e_writel(swtcr | SWTCR0_TLU_START, SWTCR0);
	for (i = 0; i < 1000; i++) {
		if (rtl8196e_readl(SWTCR0) & SWTCR0_TLU_BUSY)
			break;
		udelay(10);
	}

	rtl8196e_writel(word0, TBL_ACCESS_DATA);
	rtl8196e_writel(word1, TBL_ACCESS_DATA + 0x04);
	rtl8196e_writel(addr, TBL_ACCESS_ADDR);
	rtl8196e_writel(TBL_ACCESS_CMD_WRITE, TBL_ACCESS_CTRL);

	ret = rtl8196e_table_wait_ready();
	rtl8196e_writel(swtcr & ~(SWTCR0_TLU_START | SWTCR0_TLU_BUSY), SWTCR0);
	if (ret)
		goto out_stop;

	if (rtl8196e_readl(TBL_ACCESS_STAT) & 0x1)
		ret = -EIO;

out_stop:
	if (tlu_ok)
		rtl8196e_tlu_stop();

	if (!ret) {
		/* Direct mirror write (some silicon revisions only latch from table RAM) */
		rtl8196e_writel(word0, addr + 0x00);
		rtl8196e_writel(word1, addr + 0x04);
		rtl8196e_writel(0, addr + 0x08);
		rtl8196e_writel(0, addr + 0x0c);
		rtl8196e_writel(0, addr + 0x10);
		rtl8196e_writel(0, addr + 0x14);
		rtl8196e_writel(0, addr + 0x18);
		rtl8196e_writel(0, addr + 0x1c);
	}

	return ret;
}

static int rtl8196e_vlan_write_entry(u32 index, u32 word0)
{
	u32 words[3] = { word0, 0, 0 };

	return rtl8196e_table_write(RTL8196E_TBL_VLAN, index, words, 3);
}

static int rtl8196e_vlan_clear_table(void)
{
	u32 index;
	int ret;

	for (index = 0; index < RTL8196E_VLAN_TABLE_SIZE; index++) {
		ret = rtl8196e_vlan_write_entry(index, 0);
		if (ret)
			return ret;
	}

	return 0;
}

static int rtl8196e_netif_clear_table(void)
{
	u32 words[4] = { 0, 0, 0, 0 };
	u32 index;
	int ret;

	for (index = 0; index < RTL8196E_NETIF_TABLE_SIZE; index++) {
		ret = rtl8196e_table_write(RTL8196E_TBL_NETIF, index, words, 4);
		if (ret)
			return ret;
	}

	return 0;
}

static int rtl8196e_l2_clear_table(void)
{
	u32 index;
	int ret;

	for (index = 0; index < 1024; index++) {
		ret = rtl8196e_l2_write_entry(index, 0, 0);
		if (ret)
			return ret;
	}

	return 0;
}

static int rtl8196e_l2_read_entry(u32 index, u32 *word0, u32 *word1)
{
	u32 addr = ASIC_TABLE_BASE + (index << 5);
	u32 a[8];
	u32 b[8];
	int i;
	int j;
	int ret;
	if (!word0 || !word1)
		return -EINVAL;

	ret = rtl8196e_table_wait_ready();
	if (ret)
		return ret;

	for (i = 0; i < 10; i++) {
		for (j = 0; j < 8; j++)
			a[j] = rtl8196e_readl(addr + (j * 4));
		for (j = 0; j < 8; j++)
			b[j] = rtl8196e_readl(addr + (j * 4));
		if (memcmp(a, b, sizeof(a)) == 0) {
			*word0 = a[0];
			*word1 = a[1];
			return 0;
		}
	}
	return -EIO;
}

int rtl8196e_hw_init(struct rtl8196e_hw *hw)
{
	u32 clk;
	int ret;

	(void)hw;
	/* Ensure switch core clock is active (vendor sequence) */
	clk = rtl8196e_readl(SYS_CLK_MAG);
	rtl8196e_writel(clk | CM_PROTECT, SYS_CLK_MAG);
	clk = rtl8196e_readl(SYS_CLK_MAG);
	rtl8196e_writel(clk & ~CM_ACTIVE_SWCORE, SYS_CLK_MAG);
	mdelay(300);
	clk = rtl8196e_readl(SYS_CLK_MAG);
	rtl8196e_writel(clk | CM_ACTIVE_SWCORE, SYS_CLK_MAG);
	clk = rtl8196e_readl(SYS_CLK_MAG);
	rtl8196e_writel(clk & ~CM_PROTECT, SYS_CLK_MAG);
	mdelay(50);

	/* MEMCR init is mandatory */
	rtl8196e_writel(0, MEMCR);
	rtl8196e_writel(0x7f, MEMCR);

	/* Full reset of switch core */
	rtl8196e_writel(FULL_RST, SIRR);
	mdelay(300);

	/* Map all RX queues to ring 0 (safe default) */
	rtl8196e_writel(0, CPUQDM0);
	rtl8196e_writel(0, CPUQDM2);
	rtl8196e_writel(0, CPUQDM4);

	ret = rtl8196e_l2_clear_table();
	if (ret)
		pr_warn("rtl8196e-eth: L2 table clear failed (%d)\n", ret);

	/* Clear pending interrupts */
	rtl8196e_writel(rtl8196e_readl(CPUIISR), CPUIISR);

	return 0;
}

static int rtl8196e_set_pvid(u32 port, u32 pvid)
{
	u32 reg;
	u32 offset;

	if (port >= 9 || pvid >= 4096)
		return -EINVAL;

	offset = (port * 2) & ~0x3;
	reg = rtl8196e_readl(PVCR0 + offset);
	if (port & 0x1)
		reg = ((pvid & 0xfff) << 16) | (reg & ~0xfff0000);
	else
		reg = (pvid & 0xfff) | (reg & ~0xfff);
	rtl8196e_writel(reg, PVCR0 + offset);

	return 0;
}

static int rtl8196e_set_port_netif(u32 port, u32 netif)
{
	u32 reg;
	u32 offset;

	if (port >= 9 || netif > 7)
		return -EINVAL;

	offset = port * 3;
	reg = rtl8196e_readl(PLITIMR);
	reg &= ~(0x7 << offset);
	reg |= (netif & 0x7) << offset;
	rtl8196e_writel(reg, PLITIMR);

	return 0;
}

int rtl8196e_hw_vlan_setup(struct rtl8196e_hw *hw, u16 vid, u8 fid,
			   u32 member_ports, u32 untag_ports)
{
	u32 word0;
	int ret;
	u32 port;

	(void)hw;
	if (vid == 0 || vid >= 4096)
		return -EINVAL;

	ret = rtl8196e_vlan_clear_table();
	if (ret)
		pr_warn("rtl8196e-eth: VLAN table clear failed (%d)\n", ret);

	/* Big-endian MSB-first table layout (rtl865xc_tblAsic_vlanTable_t) */
	word0 = ((vid & 0xfff) << 20);
	word0 |= ((fid & 0x3) << 18);
	word0 |= (((untag_ports >> 6) & 0x7) << 15);
	word0 |= ((untag_ports & 0x3f) << 9);
	word0 |= (((member_ports >> 6) & 0x7) << 6);
	word0 |= (member_ports & 0x3f);

	ret = rtl8196e_vlan_write_entry(0, word0);
	if (ret)
		return ret;

	for (port = 0; port < 9; port++) {
		if (!(member_ports & (1 << port)))
			continue;
		ret = rtl8196e_set_pvid(port, vid);
		if (ret)
			pr_warn("rtl8196e-eth: set PVID failed (port=%u ret=%d)\n", port, ret);
	}

	return 0;
}

int rtl8196e_hw_netif_setup(struct rtl8196e_hw *hw, const u8 *mac, u16 vid,
			    u16 mtu, u32 member_ports)
{
	u32 words[4];
	u64 mac48;
	u32 mac18_0;
	u32 mac47_19;
	u32 word0;
	u32 word1;
	u32 word2;
	u32 word3;
	u32 port;
	int ret;

	(void)hw;
	if (!mac || vid == 0 || vid >= 4096 || mtu < 576)
		return -EINVAL;

	ret = rtl8196e_netif_clear_table();
	if (ret)
		pr_warn("rtl8196e-eth: NETIF table clear failed (%d)\n", ret);

	mac48 = ((u64)mac[0] << 40) | ((u64)mac[1] << 32) | ((u64)mac[2] << 24) |
		((u64)mac[3] << 16) | ((u64)mac[4] << 8) | mac[5];
	mac18_0 = (u32)(mac48 & 0x7ffff);
	mac47_19 = (u32)((mac48 >> 19) & 0x1fffffff);

	/* Big-endian MSB-first table layout (rtl865xc_tblAsic_netifTable_t) */
	word0 = (mac18_0 << 13) | ((vid & 0xfff) << 1) | 0x1;
	word1 = mac47_19;
	word2 = (mtu & 0x7) << 29;
	word3 = (mtu >> 3) & 0xfff;

	words[0] = word0;
	words[1] = word1;
	words[2] = word2;
	words[3] = word3;

	ret = rtl8196e_table_write(RTL8196E_TBL_NETIF, 0, words, 4);
	if (ret)
		return ret;

	for (port = 0; port < 9; port++) {
		if (!(member_ports & (1 << port)))
			continue;
		ret = rtl8196e_set_port_netif(port, 0);
		if (ret)
			pr_warn("rtl8196e-eth: set port netif failed (port=%u ret=%d)\n", port, ret);
	}

	return 0;
}

int rtl8196e_hw_init_phy(struct rtl8196e_hw *hw, int port, int phy_id)
{
	u32 pcr;
	u16 bmcr;
	int ret;

	(void)hw;
	if (port < 0 || phy_id < 0)
		return -EINVAL;

	pcr = rtl8196e_readl(PCRP0 + (port << 2));
	pcr |= EnablePHYIf | MacSwReset;
	rtl8196e_writel(pcr, PCRP0 + (port << 2));
	udelay(10);
	pcr &= ~MacSwReset;
	rtl8196e_writel(pcr, PCRP0 + (port << 2));

	ret = rtl8196e_mdio_read(phy_id, 0, &bmcr);
	if (ret)
		return ret;

	bmcr |= (1 << 12) | (1 << 9); /* AN enable + restart */
	return rtl8196e_mdio_write(phy_id, 0, bmcr);
}

bool rtl8196e_hw_link_up(struct rtl8196e_hw *hw, int port)
{
	u32 status;

	(void)hw;
	if (port < 0)
		return false;

	status = rtl8196e_readl(PSRP0 + (port << 2));
	return (status & PortStatusLinkUp) != 0;
}

void rtl8196e_hw_l2_setup(struct rtl8196e_hw *hw)
{
	u32 swtcr;
	u32 ffcr;
	u32 cscr;
	u32 mscr;
	u32 teacr;
	u32 swtcr1;
	u32 vcr0;
	u32 qnumcr;
	u32 port;
	u32 pcr;

	(void)hw;
	swtcr1 = rtl8196e_readl(SWTCR1);
	swtcr1 |= ENNATT2LOG | ENFRAGTOACLPT;
	rtl8196e_writel(swtcr1, SWTCR1);

	mscr = rtl8196e_readl(MSCR);
	mscr |= EN_L2;
	mscr &= ~(EN_L3 | EN_L4);
	rtl8196e_writel(mscr, MSCR);

	teacr = rtl8196e_readl(TEACR);
	teacr &= ~0x3; /* enable L2 aging, disable L4 aging */
	rtl8196e_writel(teacr, TEACR);

	swtcr = rtl8196e_readl(SWTCR0);
	swtcr &= ~LIMDBC_MASK;
	swtcr |= LIMDBC_VLAN;
	swtcr |= NAPTF2CPU;
	swtcr |= (MCAST_PORT_EXT_MODE_MASK << MCAST_PORT_EXT_MODE_OFFSET);
	rtl8196e_writel(swtcr, SWTCR0);

	vcr0 = rtl8196e_readl(VCR0);
	vcr0 &= ~EN_ALL_PORT_VLAN_INGRESS_FILTER;
	rtl8196e_writel(vcr0, VCR0);

	ffcr = rtl8196e_readl(FFCR);
	ffcr |= EN_MCAST | EN_UNMCAST_TOCPU;
	ffcr &= ~EN_UNUNICAST_TOCPU;
	rtl8196e_writel(ffcr, FFCR);

	cscr = rtl8196e_readl(CSCR);
	cscr &= ~(ALLOW_L2_CHKSUM_ERR | ALLOW_L3_CHKSUM_ERR | ALLOW_L4_CHKSUM_ERR);
	rtl8196e_writel(cscr, CSCR);

	/* Set all ports (0-6) to 1 output queue */
	qnumcr = rtl8196e_readl(QNUMCR);
	for (port = 0; port <= 6; port++) {
		qnumcr &= ~(0x7 << (3 * port));
		qnumcr |= (1 << (3 * port));
	}
	rtl8196e_writel(qnumcr, QNUMCR);

	/* Force STP state to forwarding on physical ports */
	for (port = 0; port < 6; port++) {
		pcr = rtl8196e_readl(PCRP0 + (port << 2));
		pcr &= ~STP_PortST_MASK;
		pcr |= STP_PortST_FORWARDING;
		rtl8196e_writel(pcr, PCRP0 + (port << 2));
	}
}

void rtl8196e_hw_l2_trap_enable(struct rtl8196e_hw *hw)
{
	u32 swtcr;
	u32 ffcr;
	u32 cscr;

	(void)hw;
	swtcr = rtl8196e_readl(SWTCR0);
	swtcr &= ~LIMDBC_MASK;
	swtcr |= LIMDBC_VLAN | NAPTF2CPU;
	rtl8196e_writel(swtcr, SWTCR0);

	ffcr = rtl8196e_readl(FFCR);
	ffcr |= EN_UNUNICAST_TOCPU | EN_UNMCAST_TOCPU | EN_MCAST;
	rtl8196e_writel(ffcr, FFCR);

	cscr = rtl8196e_readl(CSCR);
	cscr &= ~(ALLOW_L2_CHKSUM_ERR | ALLOW_L3_CHKSUM_ERR | ALLOW_L4_CHKSUM_ERR);
	rtl8196e_writel(cscr, CSCR);
}

int rtl8196e_hw_l2_add_cpu_entry(struct rtl8196e_hw *hw, const u8 *mac, u8 fid, u32 portmask)
{
	static const u8 fid_hash[] = { 0x00, 0x0f, 0xf0, 0xff };
	u32 row;
	u32 index;
	u32 word0;
	u32 word1;
	u32 member;

	(void)hw;
	if (!mac)
		return -EINVAL;

	fid &= 0x3;
	row = (mac[0] ^ mac[1] ^ mac[2] ^ mac[3] ^ mac[4] ^ mac[5] ^ fid_hash[fid]) & 0xff;
	index = (row << 2);

	word0 = ((u32)mac[1] << 24) | ((u32)mac[2] << 16) | ((u32)mac[3] << 8) | mac[4];
	member = ((portmask >> 6) & 0x7) << 14;
	member |= (portmask & 0x3f) << 8;
	word1 = (1 << 25) | /* auth */
		((u32)(fid & 0x3) << 23) |
		(1 << 22) | /* nhFlag */
		(0 << 21) | /* srcBlock */
		(3 << 19) | /* agingTime */
		(1 << 18) | /* isStatic */
		(1 << 17) | /* toCPU */
		member |
		(mac[0] & 0xff);

	return rtl8196e_l2_write_entry(index, word0, word1);
}

int rtl8196e_hw_l2_add_bcast_entry(struct rtl8196e_hw *hw, u8 fid, u32 portmask)
{
	static const u8 bcast[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

	return rtl8196e_hw_l2_add_cpu_entry(hw, bcast, fid, portmask);
}

int rtl8196e_hw_l2_check_cpu_entry(struct rtl8196e_hw *hw, const u8 *mac, u8 fid)
{
	static const u8 fid_hash[] = { 0x00, 0x0f, 0xf0, 0xff };
	u32 row;
	u32 index;
	u32 word0;
	u32 word1;
	u32 expected0;
	u32 expected1;
	u32 mask;
	int ret;
	int tries;

	(void)hw;
	if (!mac)
		return -EINVAL;

	fid &= 0x3;
	row = (mac[0] ^ mac[1] ^ mac[2] ^ mac[3] ^ mac[4] ^ mac[5] ^ fid_hash[fid]) & 0xff;
	index = (row << 2);

	expected0 = ((u32)mac[1] << 24) | ((u32)mac[2] << 16) | ((u32)mac[3] << 8) | mac[4];
	expected1 = (mac[0] & 0xff) |
		(1 << 17) | /* toCPU */
		(1 << 18) | /* isStatic */
		(1 << 22) | /* nhFlag */
		((u32)(fid & 0x3) << 23);
	mask = 0xff | (1 << 17) | (1 << 18) | (1 << 22) | (3 << 23);

	for (tries = 0; tries < 50; tries++) {
		ret = rtl8196e_l2_read_entry(index, &word0, &word1);
		if (ret)
			return ret;
		if (word0 == expected0 && (word1 & mask) == expected1)
			return 0;
		udelay(10);
	}

	pr_warn("rtl8196e-eth: L2 verify mismatch row=%u idx=%u exp0=0x%08x exp1=0x%08x got0=0x%08x got1=0x%08x\n",
		row, index, expected0, expected1, word0, word1);
	return -EIO;
}

void rtl8196e_hw_start(struct rtl8196e_hw *hw)
{
	u32 icr = TXCMD | RXCMD | BUSBURST_32WORDS | MBUF_2048BYTES | EXCLUDE_CRC;
	(void)hw;
	rtl8196e_writel(icr, CPUICR);
	/* Start TX/RX after rings and CPUICR are set */
	rtl8196e_writel(TRXRDY, SIRR);
}

void rtl8196e_hw_stop(struct rtl8196e_hw *hw)
{
	u32 icr = rtl8196e_readl(CPUICR);
	(void)hw;
	icr &= ~(TXCMD | RXCMD);
	rtl8196e_writel(icr, CPUICR);
	rtl8196e_writel(0, SIRR);
}

void rtl8196e_hw_set_rx_rings(struct rtl8196e_hw *hw, void *pkthdr, void *mbuf)
{
	(void)hw;
	rtl8196e_writel((u32)rtl8196e_uncached_addr(pkthdr), CPURPDCR0);
	rtl8196e_writel((u32)rtl8196e_uncached_addr(pkthdr), CPURPDCR1);
	rtl8196e_writel((u32)rtl8196e_uncached_addr(pkthdr), CPURPDCR2);
	rtl8196e_writel((u32)rtl8196e_uncached_addr(pkthdr), CPURPDCR3);
	rtl8196e_writel((u32)rtl8196e_uncached_addr(pkthdr), CPURPDCR4);
	rtl8196e_writel((u32)rtl8196e_uncached_addr(pkthdr), CPURPDCR5);
	rtl8196e_writel((u32)rtl8196e_uncached_addr(mbuf), CPURMDCR0);
}

void rtl8196e_hw_set_tx_ring(struct rtl8196e_hw *hw, void *pkthdr)
{
	(void)hw;
	rtl8196e_writel((u32)rtl8196e_uncached_addr(pkthdr), CPUTPDCR0);
}

void rtl8196e_hw_enable_irqs(struct rtl8196e_hw *hw)
{
	u32 mask = RX_DONE_IE_ALL | TX_ALL_DONE_IE_ALL | LINK_CHANGE_IE | PKTHDR_DESC_RUNOUT_IE_ALL;
	(void)hw;
	rtl8196e_writel(mask, CPUIIMR);
}

void rtl8196e_hw_disable_irqs(struct rtl8196e_hw *hw)
{
	(void)hw;
	rtl8196e_writel(0, CPUIIMR);
}
