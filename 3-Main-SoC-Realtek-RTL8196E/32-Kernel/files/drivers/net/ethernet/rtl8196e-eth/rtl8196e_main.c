// SPDX-License-Identifier: GPL-2.0
/*
 * rtl8196e_main.c - RTL8196E Ethernet driver core.
 *
 * Covers: net_device lifecycle, NAPI poll, interrupt handler, TX path,
 * ethtool statistics, and platform probe/remove.
 * Targets a single physical port (port 4) on the Lidl Silvercrest Zigbee gateway.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/of.h>
#include <linux/string.h>
#include <linux/interrupt.h>
#include <linux/timer.h>
#include <linux/errno.h>
#include <linux/ethtool.h>
#include <linux/mfd/syscon.h>
#include <asm/cacheflush.h>
#include <asm/mach-realtek/imem.h>
#include "rtl8196e_dt.h"
#include "rtl8196e_hw.h"
#include "rtl8196e_ring.h"
#include "rtl8196e_regs.h"

#define RTL8196E_DRV_NAME "rtl8196e-eth"
#define RTL8196E_DRV_VERSION "2.2"

#define RTL8196E_TX_DESC      128
#define RTL8196E_RX_DESC      128
#define RTL8196E_RX_MBUF_DESC 128
#define RTL8196E_CLUSTER_SIZE 1700

#define RTL8196E_TX_STOP_THRESH 4
#define RTL8196E_TX_WAKE_THRESH 16

static unsigned int link_poll_ms;
module_param(link_poll_ms, uint, 0644);
MODULE_PARM_DESC(link_poll_ms, "Link poll interval in ms (0=disabled)");

static unsigned int rtl8196e_debug;
module_param(rtl8196e_debug, uint, 0644);
MODULE_PARM_DESC(rtl8196e_debug, "Enable extra debug logging (default=0)");

static unsigned int rtl8196e_force_trap;
module_param(rtl8196e_force_trap, uint, 0644);
MODULE_PARM_DESC(rtl8196e_force_trap, "Force all unknown traffic to CPU (debug)");

static unsigned int rtl8196e_cpu_port_mask = RTL8196E_CPU_PORT_MASK;
module_param(rtl8196e_cpu_port_mask, uint, 0644);
MODULE_PARM_DESC(rtl8196e_cpu_port_mask, "CPU port mask for VLAN/L2 (default=0x20)");

struct rtl8196e_priv {
	struct net_device *ndev;
	struct napi_struct napi;
	struct rtl8196e_hw hw;
	struct rtl8196e_ring *ring;
	struct rtl8196e_dt_iface iface;
	struct timer_list link_timer;
	struct timer_list dbg_timer;
	u16 vlan_id;
	u16 portmask;
	int phy_port;
	int phy_id;
	unsigned int link_poll_ms;
	u32 l2_check_ok;
	u32 l2_check_fail;
	int l2_check_last;
	u32 tx_debug_once;
	u32 tx_dbg_portmask;
	u32 tx_dbg_vid;
	u32 tx_dbg_len;
	u32 tx_dbg_submit;
	u32 dbg_tx_idx;
	u32 dbg_irqs;
};

/* Return the port number (0-5) for the lowest set bit in mask, or -EINVAL. */
static int rtl8196e_port_from_mask(u16 mask)
{
	int port;

	for (port = 0; port < 6; port++) {
		if (mask & (1 << port))
			return port;
	}

	return -EINVAL;
}

/* Periodic link poll timer: update carrier state and reschedule. */
static void rtl8196e_link_timer_fn(struct timer_list *t)
{
	struct rtl8196e_priv *priv = from_timer(priv, t, link_timer);
	bool link;

	if (!netif_running(priv->ndev))
		return;

	link = rtl8196e_hw_link_up(&priv->hw, priv->phy_port);
	if (link)
		netif_carrier_on(priv->ndev);
	else
		netif_carrier_off(priv->ndev);

	if (priv->link_poll_ms)
		mod_timer(&priv->link_timer, jiffies + msecs_to_jiffies(priv->link_poll_ms));
}

/* Debug timer: dump TX/RX descriptor state and key IRQ registers to dmesg. */
static void rtl8196e_dbg_timer_fn(struct timer_list *t)
{
	struct rtl8196e_priv *priv = from_timer(priv, t, dbg_timer);
	struct rtl8196e_ring *ring = priv->ring;
	u32 idx = priv->dbg_tx_idx;
	u32 rx_idx;
	u32 entry = 0;
	u32 rx_entry = 0;
	u32 rx_mbuf_entry = 0;
	struct rtl_pktHdr *ph = NULL;
	struct rtl_pktHdr *rx_ph = NULL;
	struct rtl_mBuf *rx_mb = NULL;
	u32 isr, imr, icr;

	if (!rtl8196e_debug || !ring)
		return;

	if (idx < rtl8196e_ring_tx_count(ring))
		entry = rtl8196e_ring_tx_entry(ring, idx);

	rx_idx = rtl8196e_ring_rx_index(ring);
	rx_entry = rtl8196e_ring_rx_pkthdr_entry(ring, rx_idx);
	rx_mbuf_entry = rtl8196e_ring_rx_mbuf_entry(ring, rx_idx);

	isr = rtl8196e_readl(CPUIISR);
	imr = rtl8196e_readl(CPUIIMR);
	icr = rtl8196e_readl(CPUICR);

	if (entry)
		ph = (struct rtl_pktHdr *)(entry & ~(RTL8196E_DESC_OWNED_BIT | RTL8196E_DESC_WRAP));
	if (ph)
		dma_cache_inv((unsigned long)ph, sizeof(*ph));

	netdev_info(priv->ndev,
		    "dbg: CPUICR=0x%08x CPUIIMR=0x%08x CPUIISR=0x%08x\n",
		    icr, imr, isr);
	netdev_info(priv->ndev,
		    "dbg: CPUTPDCR0=0x%08x CPURPDCR0=0x%08x CPURMDCR0=0x%08x\n",
		    rtl8196e_readl(CPUTPDCR0),
		    rtl8196e_readl(CPURPDCR0),
		    rtl8196e_readl(CPURMDCR0));
	netdev_info(priv->ndev,
		    "dbg: CPUQDM0=0x%08x CPUQDM2=0x%08x CPUQDM4=0x%08x\n",
		    rtl8196e_readl(CPUQDM0),
		    rtl8196e_readl(CPUQDM2),
		    rtl8196e_readl(CPUQDM4));

	if (ph) {
		netdev_info(priv->ndev,
			    "dbg: TX idx=%u entry=0x%08x own=%u len=%u flags=0x%04x port=0x%02x vid=%u\n",
			    idx, entry, entry & RTL8196E_DESC_OWNED_BIT ? 1 : 0,
			    ph->ph_len, ph->ph_flags, ph->ph_portlist, ph->ph_vlanId);
	}

	if (rx_entry) {
		rx_ph = (struct rtl_pktHdr *)(rx_entry & ~(RTL8196E_DESC_OWNED_BIT | RTL8196E_DESC_WRAP));
		if (!(rx_entry & RTL8196E_DESC_OWNED_BIT) && rx_ph)
			dma_cache_inv((unsigned long)rx_ph, sizeof(*rx_ph));
	}
	if (rx_mbuf_entry) {
		rx_mb = (struct rtl_mBuf *)(rx_mbuf_entry & ~(RTL8196E_DESC_OWNED_BIT | RTL8196E_DESC_WRAP));
		if (!(rx_mbuf_entry & RTL8196E_DESC_OWNED_BIT) && rx_mb)
			dma_cache_inv((unsigned long)rx_mb, sizeof(*rx_mb));
	}

	netdev_info(priv->ndev,
		    "dbg: RX idx=%u entry=0x%08x own=%u mbuf=0x%08x own=%u\n",
		    rx_idx,
		    rx_entry, rx_entry & RTL8196E_DESC_OWNED_BIT ? 1 : 0,
		    rx_mbuf_entry, rx_mbuf_entry & RTL8196E_DESC_OWNED_BIT ? 1 : 0);
	if (rx_ph && !(rx_entry & RTL8196E_DESC_OWNED_BIT)) {
		netdev_info(priv->ndev,
			    "dbg: RX ph len=%u flags=0x%04x port=0x%02x vid=%u\n",
			    rx_ph->ph_len, rx_ph->ph_flags, rx_ph->ph_portlist, rx_ph->ph_vlanId);
	}
}

/* Bring the interface up: init HW, program rings, setup VLAN/NETIF/L2, enable IRQs. */
static int rtl8196e_open(struct net_device *ndev)
{
	struct rtl8196e_priv *priv = netdev_priv(ndev);
	int ret;
	bool link;

	rtl8196e_hw_init(&priv->hw);
	rtl8196e_hw_set_rx_rings(&priv->hw,
				   rtl8196e_ring_rx_pkthdr_base(priv->ring),
				   rtl8196e_ring_rx_mbuf_base(priv->ring));
	rtl8196e_hw_set_tx_ring(&priv->hw, rtl8196e_ring_tx_desc_base(priv->ring));
	ret = rtl8196e_hw_init_phy(&priv->hw, priv->phy_port, priv->phy_id);
	if (ret)
		return ret;
	ret = rtl8196e_hw_vlan_setup(&priv->hw, priv->vlan_id, 0,
				     priv->portmask | rtl8196e_cpu_port_mask,
				     priv->iface.untag_ports);
	if (ret) {
		netdev_err(ndev, "VLAN setup failed (%d)\n", ret);
		return ret;
	}
	ret = rtl8196e_hw_netif_setup(&priv->hw, ndev->dev_addr,
				      priv->vlan_id, ndev->mtu,
				      priv->portmask | rtl8196e_cpu_port_mask);
	if (ret) {
		netdev_err(ndev, "NETIF setup failed (%d)\n", ret);
		return ret;
	}
	rtl8196e_hw_l2_setup(&priv->hw);
	if (rtl8196e_force_trap) {
		netdev_warn(ndev, "L2 trap-all debug enabled\n");
		rtl8196e_hw_l2_trap_enable(&priv->hw);
	}
	ret = rtl8196e_hw_l2_add_cpu_entry(&priv->hw, ndev->dev_addr, 0, 0);
	if (ret) {
		priv->l2_check_last = ret;
		priv->l2_check_fail++;
		netdev_warn(ndev, "L2 toCPU entry failed (%d), enabling trap fallback\n", ret);
		rtl8196e_hw_l2_trap_enable(&priv->hw);
	} else {
		ret = rtl8196e_hw_l2_add_bcast_entry(&priv->hw, 0,
						     priv->portmask | rtl8196e_cpu_port_mask);
		if (ret)
			netdev_warn(ndev, "L2 broadcast entry failed (%d)\n", ret);
		ret = rtl8196e_hw_l2_check_cpu_entry(&priv->hw, ndev->dev_addr, 0);
		if (ret) {
			priv->l2_check_last = ret;
			priv->l2_check_fail++;
			netdev_warn(ndev, "L2 toCPU entry verify failed (%d), enabling trap fallback\n", ret);
			rtl8196e_hw_l2_trap_enable(&priv->hw);
		} else {
			priv->l2_check_last = 0;
			priv->l2_check_ok++;
			netdev_dbg(ndev, "L2 toCPU entry verified\n");
		}
	}
	rtl8196e_hw_start(&priv->hw);
	napi_enable(&priv->napi);
	rtl8196e_hw_enable_irqs(&priv->hw);

	netif_start_queue(ndev);
	link = rtl8196e_hw_link_up(&priv->hw, priv->phy_port);
	if (link)
		netif_carrier_on(ndev);
	else
		netif_carrier_off(ndev);
	if (priv->link_poll_ms)
		mod_timer(&priv->link_timer, jiffies + msecs_to_jiffies(priv->link_poll_ms));

	return 0;
}

/* Bring the interface down: stop queue, disable IRQs, stop HW, cancel timers. */
static int rtl8196e_stop(struct net_device *ndev)
{
	struct rtl8196e_priv *priv = netdev_priv(ndev);

	netif_stop_queue(ndev);
	rtl8196e_hw_disable_irqs(&priv->hw);
	rtl8196e_hw_stop(&priv->hw);
	napi_disable(&priv->napi);
	del_timer_sync(&priv->link_timer);
	del_timer_sync(&priv->dbg_timer);
	netif_carrier_off(ndev);

	return 0;
}

/* Transmit a packet: linearize if needed, flush data cache, submit to TX ring. */
static __iram netdev_tx_t rtl8196e_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct rtl8196e_priv *priv = netdev_priv(ndev);
	bool was_empty = false;
	int ret;
	int free_count;

	if (unlikely(!priv->ring || !priv->portmask)) {
		dev_kfree_skb_any(skb);
		ndev->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}

	if (unlikely(skb_is_nonlinear(skb))) {
		if (skb_linearize(skb)) {
			dev_kfree_skb_any(skb);
			ndev->stats.tx_dropped++;
			return NETDEV_TX_OK;
		}
	}

	/*
	 * Reclaim completed TX descriptors on every xmit call.
	 * With TX_ALL_DONE IRQ disabled, this is the only reclaim path
	 * for pure TX traffic (no RX IRQ to trigger NAPI reclaim).
	 * When RX traffic is present, NAPI poll handles most reclaim
	 * in batch; this call is then a fast no-op (cons == prod).
	 */
	{
		unsigned int rpkts = 0, rbytes = 0;
		rtl8196e_ring_tx_reclaim(priv->ring, &rpkts, &rbytes, 0);
	}

	/* Flush packet data (descriptor flushes done inside tx_submit) */
	{
		unsigned int flush_len = skb->len < ETH_ZLEN ? ETH_ZLEN : skb->len;
		dma_cache_wback_inv((unsigned long)skb->data, flush_len);
	}

	ret = rtl8196e_ring_tx_submit(priv->ring, skb, skb->data, skb->len,
					     priv->vlan_id, priv->portmask,
					     PKTHDR_USED | PKT_OUTGOING,
					     &was_empty);

	if (unlikely(priv->tx_debug_once == 0)) {
		priv->tx_debug_once = 1;
		priv->tx_dbg_portmask = priv->portmask;
		priv->tx_dbg_vid = priv->vlan_id;
		priv->tx_dbg_len = skb->len;
		priv->tx_dbg_submit = (ret == 0);
		priv->dbg_tx_idx = rtl8196e_ring_last_tx_submit(priv->ring);
		netdev_dbg(ndev, "xmit first packet len=%u portmask=0x%x vid=%u\n",
			    skb->len, priv->portmask, priv->vlan_id);
		if (rtl8196e_debug)
			mod_timer(&priv->dbg_timer, jiffies + msecs_to_jiffies(200));
	}
	if (unlikely(ret < 0)) {
		unsigned int pkts = 0, bytes = 0;

		if (net_ratelimit())
			netdev_warn(ndev, "xmit submit failed (%d), reclaiming\n", ret);
		rtl8196e_ring_tx_reclaim(priv->ring, &pkts, &bytes, 0);
		ret = rtl8196e_ring_tx_submit(priv->ring, skb, skb->data, skb->len,
					     priv->vlan_id, priv->portmask,
					     PKTHDR_USED | PKT_OUTGOING,
					     &was_empty);
		if (ret < 0) {
			netif_stop_queue(ndev);
			return NETDEV_TX_BUSY;
		}
	}

	rtl8196e_ring_kick_tx(was_empty);

	ndev->stats.tx_packets++;
	ndev->stats.tx_bytes += skb->len;

	free_count = rtl8196e_ring_tx_free_count(priv->ring);
	if (unlikely(free_count < RTL8196E_TX_STOP_THRESH))
		netif_stop_queue(ndev);

	return NETDEV_TX_OK;
}

/* TX watchdog handler: reclaim in-flight SKBs, reset the TX ring, and restart. */
static void rtl8196e_tx_timeout(struct net_device *ndev, unsigned int txqueue)
{
	struct rtl8196e_priv *priv = netdev_priv(ndev);
	unsigned int pkts = 0, bytes = 0;

	netdev_warn(ndev, "TX timeout\n");

	if (!priv->ring)
		return;

	netif_stop_queue(ndev);
	rtl8196e_hw_disable_irqs(&priv->hw);
	rtl8196e_hw_stop(&priv->hw);

	rtl8196e_ring_tx_reclaim(priv->ring, &pkts, &bytes, 0);
	rtl8196e_ring_tx_reset(priv->ring);
	rtl8196e_hw_set_tx_ring(&priv->hw, rtl8196e_ring_tx_desc_base(priv->ring));

	rtl8196e_hw_start(&priv->hw);
	rtl8196e_hw_enable_irqs(&priv->hw);

	netif_wake_queue(ndev);
}

/* NAPI poll: drain RX ring up to budget, reclaim completed TX, wake queue if stalled. */
static __iram int rtl8196e_poll(struct napi_struct *napi, int budget)
{
	struct rtl8196e_priv *priv = container_of(napi, struct rtl8196e_priv, napi);
	unsigned int pkts = 0, bytes = 0;
	int work_done;

	work_done = rtl8196e_ring_rx_poll(priv->ring, budget, napi, priv->ndev);

	rtl8196e_ring_tx_reclaim(priv->ring, &pkts, &bytes, budget);

	if (unlikely(pkts && netif_queue_stopped(priv->ndev))) {
		int free_count = rtl8196e_ring_tx_free_count(priv->ring);

		if (free_count >= RTL8196E_TX_WAKE_THRESH)
			netif_wake_queue(priv->ndev);
	}

	if (work_done < budget) {
		if (napi_complete_done(napi, work_done)) {
			rtl8196e_writel(PKTHDR_DESC_RUNOUT_IP_ALL | MBUF_DESC_RUNOUT_IP_ALL, CPUIISR);
			rtl8196e_hw_enable_irqs(&priv->hw);
		}
	}

	return work_done;
}

/* Interrupt handler: read and clear CPUIISR, update link state, schedule NAPI. */
static __iram irqreturn_t rtl8196e_isr(int irq, void *dev_id)
{
	struct net_device *ndev = dev_id;
	struct rtl8196e_priv *priv = netdev_priv(ndev);
	u32 status;
	bool link;

	status = rtl8196e_readl(CPUIISR);
	if (rtl8196e_debug && priv->dbg_irqs < 3) {
		netdev_info(ndev, "dbg: ISR status=0x%08x\n", status);
		priv->dbg_irqs++;
	}
	rtl8196e_writel(status, CPUIISR);
	status &= rtl8196e_readl(CPUIIMR);
	if (unlikely(!status))
		return IRQ_NONE;

	if (unlikely(status & LINK_CHANGE_IP)) {
		link = rtl8196e_hw_link_up(&priv->hw, priv->phy_port);
		if (link)
			netif_carrier_on(ndev);
		else
			netif_carrier_off(ndev);
	}

	if (likely(status & (RX_DONE_IP_ALL | PKTHDR_DESC_RUNOUT_IP_ALL))) {
		if (likely(napi_schedule_prep(&priv->napi))) {
			rtl8196e_hw_disable_irqs(&priv->hw);
			__napi_schedule(&priv->napi);
		}
	}

	return IRQ_HANDLED;
}

static const struct net_device_ops rtl8196e_netdev_ops = {
	.ndo_open = rtl8196e_open,
	.ndo_stop = rtl8196e_stop,
	.ndo_start_xmit = rtl8196e_start_xmit,
	.ndo_tx_timeout = rtl8196e_tx_timeout,
	.ndo_set_mac_address = eth_mac_addr,
};

/* ethtool: return the number of driver-specific statistics. */
static int rtl8196e_get_sset_count(struct net_device *ndev, int sset)
{
	(void)ndev;
	if (sset == ETH_SS_STATS)
		return 7;
	return -EOPNOTSUPP;
}

/* ethtool: fill the statistics name strings array. */
static void rtl8196e_get_strings(struct net_device *ndev, u32 sset, u8 *data)
{
	static const char stats[][ETH_GSTRING_LEN] = {
		"rtl8196e_l2_check_ok",
		"rtl8196e_l2_check_fail",
		"rtl8196e_l2_check_last_result",
		"rtl8196e_tx_dbg_portmask",
		"rtl8196e_tx_dbg_vid",
		"rtl8196e_tx_dbg_len",
		"rtl8196e_tx_dbg_submit",
	};

	(void)ndev;
	if (sset != ETH_SS_STATS)
		return;

	memcpy(data, stats, sizeof(stats));
}

/* ethtool: fill the statistics values array. */
static void rtl8196e_get_ethtool_stats(struct net_device *ndev,
				       struct ethtool_stats *stats, u64 *data)
{
	struct rtl8196e_priv *priv = netdev_priv(ndev);

	(void)stats;
	data[0] = priv->l2_check_ok;
	data[1] = priv->l2_check_fail;
	data[2] = priv->l2_check_last;
	data[3] = priv->tx_dbg_portmask;
	data[4] = priv->tx_dbg_vid;
	data[5] = priv->tx_dbg_len;
	data[6] = priv->tx_dbg_submit;
}

static const struct ethtool_ops rtl8196e_ethtool_ops = {
	.get_sset_count = rtl8196e_get_sset_count,
	.get_strings = rtl8196e_get_strings,
	.get_ethtool_stats = rtl8196e_get_ethtool_stats,
};

/*
 * led_mode sysfs attribute: "bright" (default), "dim", or "off".
 *
 * "bright": LEDCREG = LEDMODE_DIRECT, DIRECTLCR = default (full brightness).
 * "dim":    LEDCREG = 0 (scan mode, ~25% brightness).
 * "off":    DIRECTLCR = 0 (completely off — disables LED output in HW).
 *
 * The LAN LED is hardwired to the switch ASIC LED_PORT0 output;
 * GPIO has no physical effect.  Only LEDCREG/DIRECTLCR control it.
 * The STATUS LED (GPIO-driven) should be set to 255, 60, or 0 to match.
 */
static ssize_t led_mode_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	if (rtl8196e_readl(DIRECTLCR) == 0)
		return sysfs_emit(buf, "off\n");

	return sysfs_emit(buf, "%s\n",
			  (rtl8196e_readl(LEDCREG) & LEDMODE_DIRECT) ? "bright" : "dim");
}

static ssize_t led_mode_store(struct device *dev,
			      struct device_attribute *attr,
			      const char *buf, size_t count)
{
	if (sysfs_streq(buf, "bright")) {
		rtl8196e_writel(DIRECTLCR_DEFAULT, DIRECTLCR);
		rtl8196e_writel(LEDMODE_DIRECT, LEDCREG);
	} else if (sysfs_streq(buf, "dim")) {
		rtl8196e_writel(DIRECTLCR_DEFAULT, DIRECTLCR);
		rtl8196e_writel(0, LEDCREG);
	} else if (sysfs_streq(buf, "off")) {
		rtl8196e_writel(0, DIRECTLCR);
	} else {
		return -EINVAL;
	}

	return count;
}

static DEVICE_ATTR_RW(led_mode);

/* Platform probe: allocate netdev, parse DT, create ring, request IRQ, register. */
static int rtl8196e_probe(struct platform_device *pdev)
{
	struct net_device *ndev;
	struct rtl8196e_priv *priv;
	int ret;
	int irq;

	ndev = alloc_etherdev(sizeof(*priv));
	if (!ndev)
		return -ENOMEM;

	platform_set_drvdata(pdev, ndev);
	priv = netdev_priv(ndev);
	priv->ndev = ndev;

	ret = rtl8196e_dt_parse(&pdev->dev, &priv->iface);
	if (ret)
		goto err_free;

	if (priv->iface.mac_set)
		ether_addr_copy(ndev->dev_addr, priv->iface.mac);
	else
		eth_hw_addr_random(ndev);

	strscpy(ndev->name, priv->iface.ifname, IFNAMSIZ);
	priv->vlan_id = priv->iface.vlan_id;
	priv->portmask = priv->iface.member_ports;
	priv->phy_port = rtl8196e_port_from_mask(priv->portmask);
	priv->phy_id = priv->iface.phy_id_set ? priv->iface.phy_id : priv->phy_port;
	priv->link_poll_ms = priv->iface.link_poll_ms_set ? priv->iface.link_poll_ms : link_poll_ms;
	if (priv->phy_port < 0) {
		ret = -EINVAL;
		goto err_free;
	}

	{
		struct regmap *syscon;

		syscon = syscon_regmap_lookup_by_phandle(pdev->dev.of_node,
							 "realtek,syscon");
		priv->hw.syscon = IS_ERR(syscon) ? NULL : syscon;
	}

	priv->ring = rtl8196e_ring_create(RTL8196E_TX_DESC,
					 RTL8196E_RX_DESC,
					 RTL8196E_RX_MBUF_DESC,
					 RTL8196E_CLUSTER_SIZE);
	if (!priv->ring) {
		ret = -ENOMEM;
		goto err_free;
	}

	timer_setup(&priv->link_timer, rtl8196e_link_timer_fn, 0);
	timer_setup(&priv->dbg_timer, rtl8196e_dbg_timer_fn, 0);

	netif_napi_add(ndev, &priv->napi, rtl8196e_poll, 64);
	ndev->netdev_ops = &rtl8196e_netdev_ops;
	ndev->ethtool_ops = &rtl8196e_ethtool_ops;
	ndev->watchdog_timeo = 10 * HZ;
	ndev->min_mtu = 68;
	ndev->max_mtu = priv->iface.mtu;
	ndev->mtu = priv->iface.mtu;
	ndev->features |= NETIF_F_RXCSUM;

	irq = platform_get_irq(pdev, 0);
	if (irq < 0) {
		ret = irq;
		goto err_ring;
	}

	ret = request_irq(irq, rtl8196e_isr, 0, RTL8196E_DRV_NAME, ndev);
	if (ret)
		goto err_ring;

	ret = register_netdev(ndev);
	if (ret)
		goto err_irq;

	device_create_file(&ndev->dev, &dev_attr_led_mode);

	dev_info(&pdev->dev, "rtl8196e-eth v" RTL8196E_DRV_VERSION " (J. Nilo)\n");
	return 0;

err_irq:
	free_irq(irq, ndev);
err_ring:
	rtl8196e_ring_destroy(priv->ring);
err_free:
	free_netdev(ndev);
	return ret;
}

/* Platform remove: unregister netdev, free IRQ, destroy ring, free netdev. */
static int rtl8196e_remove(struct platform_device *pdev)
{
	struct net_device *ndev = platform_get_drvdata(pdev);
	struct rtl8196e_priv *priv;
	int irq;

	if (!ndev)
		return 0;

	priv = netdev_priv(ndev);

	device_remove_file(&ndev->dev, &dev_attr_led_mode);
	unregister_netdev(ndev);

	irq = platform_get_irq(pdev, 0);
	if (irq >= 0)
		free_irq(irq, ndev);

	if (priv->ring)
		rtl8196e_ring_destroy(priv->ring);

	free_netdev(ndev);
	return 0;
}

static const struct of_device_id rtl8196e_of_match[] = {
	{ .compatible = "realtek,rtl8196e-mac" },
	{ }
};
MODULE_DEVICE_TABLE(of, rtl8196e_of_match);

static struct platform_driver rtl8196e_driver = {
	.probe = rtl8196e_probe,
	.remove = rtl8196e_remove,
	.driver = {
		.name = RTL8196E_DRV_NAME,
		.of_match_table = rtl8196e_of_match,
	},
};

module_platform_driver(rtl8196e_driver);

MODULE_AUTHOR("Jacques Nilo");
MODULE_DESCRIPTION("RTL8196E minimal Ethernet driver");
MODULE_VERSION(RTL8196E_DRV_VERSION);
MODULE_LICENSE("GPL");
