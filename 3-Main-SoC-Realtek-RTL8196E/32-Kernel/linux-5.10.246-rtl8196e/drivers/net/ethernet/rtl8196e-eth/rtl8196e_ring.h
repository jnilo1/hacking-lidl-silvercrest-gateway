/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTL8196E_RING_H
#define RTL8196E_RING_H

#include <linux/types.h>
#include <linux/netdevice.h>
#include "rtl8196e_desc.h"

struct rtl8196e_pool;
struct rtl8196e_ring;

struct rtl8196e_ring *rtl8196e_ring_create(struct rtl8196e_pool *pool,
					   unsigned int tx_cnt,
					   unsigned int rx_cnt,
					   unsigned int rx_mbuf_cnt,
					   size_t buf_size);
void rtl8196e_ring_destroy(struct rtl8196e_ring *ring);

void *rtl8196e_ring_tx_desc_base(struct rtl8196e_ring *ring);
void *rtl8196e_ring_rx_pkthdr_base(struct rtl8196e_ring *ring);
void *rtl8196e_ring_rx_mbuf_base(struct rtl8196e_ring *ring);

int rtl8196e_ring_tx_submit(struct rtl8196e_ring *ring, void *skb,
				   void *data, unsigned int len,
				   u16 vid, u16 portlist, u16 flags,
				   bool *was_empty);

int rtl8196e_ring_tx_reclaim(struct rtl8196e_ring *ring,
				    unsigned int *pkts,
				    unsigned int *bytes);

int rtl8196e_ring_rx_poll(struct rtl8196e_ring *ring, int budget,
				 struct napi_struct *napi,
				 struct net_device *dev);

int rtl8196e_ring_tx_free_count(struct rtl8196e_ring *ring);

void rtl8196e_ring_kick_tx(bool was_empty);
void rtl8196e_ring_tx_reset(struct rtl8196e_ring *ring);
unsigned int rtl8196e_ring_last_tx_submit(struct rtl8196e_ring *ring);
unsigned int rtl8196e_ring_tx_count(struct rtl8196e_ring *ring);
u32 rtl8196e_ring_tx_entry(struct rtl8196e_ring *ring, unsigned int idx);
unsigned int rtl8196e_ring_rx_index(struct rtl8196e_ring *ring);
u32 rtl8196e_ring_rx_pkthdr_entry(struct rtl8196e_ring *ring, unsigned int idx);
u32 rtl8196e_ring_rx_mbuf_entry(struct rtl8196e_ring *ring, unsigned int idx);

#endif /* RTL8196E_RING_H */
