// SPDX-License-Identifier: GPL-2.0
#include <linux/device.h>
#include <linux/of.h>
#include <linux/of_net.h>
#include <linux/string.h>
#include <linux/if_ether.h>
#include "rtl8196e_dt.h"

static void rtl8196e_dt_defaults(struct rtl8196e_dt_iface *iface)
{
	strscpy(iface->ifname, "eth0", sizeof(iface->ifname));
	iface->vlan_id = 1;
	iface->member_ports = 0x10; /* port 4 */
	iface->untag_ports = 0x10;
	iface->mtu = 1500;
	iface->mac_set = false;
	iface->phy_id = 4;
	iface->phy_id_set = false;
	iface->link_poll_ms = 0;
	iface->link_poll_ms_set = false;
}

static struct device_node *rtl8196e_dt_find_iface(struct device_node *np)
{
	struct device_node *child;
	u32 reg;

	for_each_child_of_node(np, child) {
		if (!of_property_read_u32(child, "reg", &reg) && reg == 0)
			return child;
	}

	for_each_child_of_node(np, child) {
		if (of_node_name_eq(child, "interface@0"))
			return child;
	}

	return NULL;
}

int rtl8196e_dt_parse(struct device *dev, struct rtl8196e_dt_iface *iface)
{
	struct device_node *np = dev->of_node;
	struct device_node *if_np;
	const char *ifname;
	const u8 *mac;

	rtl8196e_dt_defaults(iface);

	if (!np)
		return -EINVAL;

	if (!of_property_read_u32(np, "link-poll-ms", &iface->link_poll_ms))
		iface->link_poll_ms_set = true;

	if_np = rtl8196e_dt_find_iface(np);
	if (!if_np) {
		dev_warn(dev, "no interface@0 node found, using defaults\n");
		return 0;
	}

	if (!of_property_read_string(if_np, "ifname", &ifname))
		strscpy(iface->ifname, ifname, sizeof(iface->ifname));

	mac = of_get_mac_address(if_np);
	if (mac) {
		memcpy(iface->mac, mac, ETH_ALEN);
		iface->mac_set = true;
	}

	of_property_read_u32(if_np, "vlan-id", &iface->vlan_id);
	of_property_read_u32(if_np, "member-ports", &iface->member_ports);
	of_property_read_u32(if_np, "untag-ports", &iface->untag_ports);
	of_property_read_u32(if_np, "mtu", &iface->mtu);
	if (!of_property_read_u32(if_np, "phy-id", &iface->phy_id))
		iface->phy_id_set = true;
	if (!of_property_read_u32(if_np, "link-poll-ms", &iface->link_poll_ms))
		iface->link_poll_ms_set = true;

	of_node_put(if_np);
	return 0;
}
