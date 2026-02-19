// SPDX-License-Identifier: GPL-2.0
/*
 * rtl8196e_ring.c - TX/RX descriptor ring management.
 *
 * Allocates and manages two RX rings (pkthdr + mbuf) and one TX ring backed by
 * pools of struct rtl_pktHdr and struct rtl_mBuf descriptors in KSEG1 (uncached)
 * memory.  Handles SKB lifecycle, DMA cache coherency, and NAPI buffer recycling.
 */
#include <linux/slab.h>
#include <linux/errno.h>
#include <linux/etherdevice.h>
#include <linux/if_ether.h>
#include <linux/skbuff.h>
#include <linux/kernel.h>
#include <asm/io.h>
#include "rtl8196e_ring.h"
#include "rtl8196e_regs.h"

struct rtl8196e_ring {
	u32 *tx_ring;
	u32 *rx_pkthdr_ring;
	u32 *rx_mbuf_ring;
	void *tx_ring_alloc;
	void *rx_pkthdr_ring_alloc;
	void *rx_mbuf_ring_alloc;
	struct rtl_pktHdr *pkthdr_pool;
	struct rtl_mBuf *mbuf_pool;
	void *pkthdr_alloc;
	void *mbuf_alloc;
	struct rtl_mBuf *rx_mbuf_base;
	unsigned int tx_cnt;
	unsigned int rx_cnt;
	unsigned int rx_mbuf_cnt;
	unsigned int tx_prod;
	unsigned int tx_cons;
	unsigned int rx_idx;
	unsigned int last_tx_submit;
	unsigned int rx_debug_once;
	unsigned int rx_debug_bad;
	size_t buf_size;
	struct rtl8196e_rx_buf *rx_bufs;
};

/* Allocate @size bytes, store the original pointer in *orig_out, return KSEG1 address. */
static void *rtl8196e_alloc_uncached(size_t size, void **orig_out)
{
	void *p = kmalloc(size, GFP_ATOMIC);
	if (!p)
		return NULL;
	if (orig_out)
		*orig_out = p;
	return rtl8196e_uncached_addr(p);
}

/* Extract the descriptor pointer from a raw ring entry (strip ownership and wrap bits). */
static struct rtl_pktHdr *rtl8196e_desc_ptr(u32 entry)
{
	return (struct rtl_pktHdr *)(entry & ~(RTL8196E_DESC_OWNED_BIT | RTL8196E_DESC_WRAP));
}

/* Allocate and initialise TX/RX descriptor rings with pre-allocated SKB buffers. */
struct rtl8196e_ring *rtl8196e_ring_create(unsigned int tx_cnt,
					   unsigned int rx_cnt,
					   unsigned int rx_mbuf_cnt,
					   size_t buf_size)
{
	struct rtl8196e_ring *ring;
	unsigned int i;
	unsigned int pkthdr_cnt;
	unsigned int mbuf_cnt;
	size_t alloc_size;

	ring = kzalloc(sizeof(*ring), GFP_KERNEL);
	if (!ring)
		return NULL;

	if (rx_mbuf_cnt < rx_cnt)
		goto err;

	ring->tx_cnt = tx_cnt;
	ring->rx_cnt = rx_cnt;
	ring->rx_mbuf_cnt = rx_mbuf_cnt;
	ring->buf_size = buf_size;

	ring->tx_ring = rtl8196e_alloc_uncached(tx_cnt * sizeof(u32), &ring->tx_ring_alloc);
	ring->rx_pkthdr_ring = rtl8196e_alloc_uncached(rx_cnt * sizeof(u32), &ring->rx_pkthdr_ring_alloc);
	ring->rx_mbuf_ring = rtl8196e_alloc_uncached(rx_mbuf_cnt * sizeof(u32), &ring->rx_mbuf_ring_alloc);

	if (!ring->tx_ring || !ring->rx_pkthdr_ring || !ring->rx_mbuf_ring)
		goto err;

	pkthdr_cnt = tx_cnt + rx_cnt;
	mbuf_cnt = tx_cnt + rx_mbuf_cnt;

	alloc_size = pkthdr_cnt * sizeof(struct rtl_pktHdr) + L1_CACHE_BYTES;
	ring->pkthdr_alloc = kmalloc(alloc_size, GFP_ATOMIC);
	if (!ring->pkthdr_alloc)
		goto err;
	ring->pkthdr_pool = (struct rtl_pktHdr *)ALIGN((unsigned long)ring->pkthdr_alloc, L1_CACHE_BYTES);

	alloc_size = mbuf_cnt * sizeof(struct rtl_mBuf) + L1_CACHE_BYTES;
	ring->mbuf_alloc = kmalloc(alloc_size, GFP_ATOMIC);
	if (!ring->mbuf_alloc)
		goto err;
	ring->mbuf_pool = (struct rtl_mBuf *)ALIGN((unsigned long)ring->mbuf_alloc, L1_CACHE_BYTES);
	ring->rx_mbuf_base = ring->mbuf_pool + tx_cnt;

	/* Init TX descriptors */
	for (i = 0; i < tx_cnt; i++) {
		struct rtl_pktHdr *ph = &ring->pkthdr_pool[i];
		struct rtl_mBuf *mb = &ring->mbuf_pool[i];

		memset(ph, 0, sizeof(*ph));
		memset(mb, 0, sizeof(*mb));

		ph->ph_mbuf = mb;
		ph->ph_flags = PKTHDR_USED | PKT_OUTGOING;
		ph->ph_type = PKTHDR_ETHERNET;
		ph->ph_portlist = 0;

		mb->m_pkthdr = ph;
		mb->m_flags = MBUF_USED | MBUF_EXT | MBUF_PKTHDR | MBUF_EOR;
		mb->m_data = NULL;
		mb->m_extbuf = NULL;
		mb->m_extsize = 0;
		mb->skb = NULL;

		ring->tx_ring[i] = (u32)ph | RTL8196E_DESC_RISC_OWNED;

		dma_cache_wback_inv((unsigned long)ph, sizeof(*ph));
		dma_cache_wback_inv((unsigned long)mb, sizeof(*mb));
	}
	if (tx_cnt)
		ring->tx_ring[tx_cnt - 1] |= RTL8196E_DESC_WRAP;

	/* Allocate RX buffer shadow array */
	ring->rx_bufs = kcalloc(rx_cnt, sizeof(*ring->rx_bufs), GFP_KERNEL);
	if (!ring->rx_bufs)
		goto err;

	/* Init RX descriptors */
	for (i = 0; i < rx_cnt; i++) {
		struct rtl_pktHdr *ph = &ring->pkthdr_pool[tx_cnt + i];
		struct rtl_mBuf *mb = &ring->mbuf_pool[tx_cnt + i];
		struct sk_buff *skb;

		memset(ph, 0, sizeof(*ph));
		memset(mb, 0, sizeof(*mb));

		ph->ph_mbuf = mb;
		ph->ph_flags = PKTHDR_USED | PKT_INCOMING;
		ph->ph_type = PKTHDR_ETHERNET;
		ph->ph_portlist = 0;

		mb->m_pkthdr = ph;
		mb->m_flags = MBUF_USED | MBUF_EXT | MBUF_PKTHDR | MBUF_EOR;
		mb->m_len = 0;
		mb->m_extsize = buf_size;

		skb = netdev_alloc_skb(NULL, NET_SKB_PAD + buf_size);
		if (!skb)
			goto err;
		skb_reserve(skb, NET_SKB_PAD);

		mb->m_data = skb->data;
		mb->m_extbuf = skb->data;
		mb->skb = NULL;

		ring->rx_bufs[i].skb = skb;

		ring->rx_pkthdr_ring[i] = (u32)ph | RTL8196E_DESC_SWCORE_OWNED;
		ring->rx_mbuf_ring[i] = (u32)mb | RTL8196E_DESC_SWCORE_OWNED;

		dma_cache_wback_inv((unsigned long)skb->head,
				    NET_SKB_PAD + buf_size);
		dma_cache_wback_inv((unsigned long)ph, sizeof(*ph));
		dma_cache_wback_inv((unsigned long)mb, sizeof(*mb));
	}
	if (rx_cnt)
		ring->rx_pkthdr_ring[rx_cnt - 1] |= RTL8196E_DESC_WRAP;
	if (rx_mbuf_cnt)
		ring->rx_mbuf_ring[rx_mbuf_cnt - 1] |= RTL8196E_DESC_WRAP;

	/* Flush descriptor structures */
	dma_cache_wback_inv((unsigned long)ring->pkthdr_pool, pkthdr_cnt * sizeof(struct rtl_pktHdr));
	dma_cache_wback_inv((unsigned long)ring->mbuf_pool, mbuf_cnt * sizeof(struct rtl_mBuf));

	return ring;

err:
	rtl8196e_ring_destroy(ring);
	return NULL;
}

/* Free all ring memory: release in-flight SKBs, descriptor pools, and ring arrays. */
void rtl8196e_ring_destroy(struct rtl8196e_ring *ring)
{
	unsigned int i;

	if (!ring)
		return;

	/* Free TX SKBs */
	if (ring->mbuf_pool) {
		for (i = 0; i < ring->tx_cnt; i++) {
			if (ring->mbuf_pool[i].skb) {
				dev_kfree_skb_any((struct sk_buff *)ring->mbuf_pool[i].skb);
				ring->mbuf_pool[i].skb = NULL;
			}
		}
	}

	/* Free RX SKBs */
	if (ring->rx_bufs) {
		for (i = 0; i < ring->rx_cnt; i++) {
			if (ring->rx_bufs[i].skb)
				dev_kfree_skb_any(ring->rx_bufs[i].skb);
		}
	}
	kfree(ring->rx_bufs);

	kfree(ring->tx_ring_alloc);
	kfree(ring->rx_pkthdr_ring_alloc);
	kfree(ring->rx_mbuf_ring_alloc);
	kfree(ring->pkthdr_alloc);
	kfree(ring->mbuf_alloc);
	kfree(ring);
}

/* Return the KSEG1 base address of the TX descriptor array. */
void *rtl8196e_ring_tx_desc_base(struct rtl8196e_ring *ring)
{
	return ring ? ring->tx_ring : NULL;
}

/* Return the KSEG1 base address of the RX pkthdr descriptor array. */
void *rtl8196e_ring_rx_pkthdr_base(struct rtl8196e_ring *ring)
{
	return ring ? ring->rx_pkthdr_ring : NULL;
}

/* Return the KSEG1 base address of the RX mbuf descriptor array. */
void *rtl8196e_ring_rx_mbuf_base(struct rtl8196e_ring *ring)
{
	return ring ? ring->rx_mbuf_ring : NULL;
}

/* Fill the next TX descriptor with @skb's data and hand ownership to the hardware. */
int rtl8196e_ring_tx_submit(struct rtl8196e_ring *ring, void *skb,
				   void *data, unsigned int len,
				   u16 vid, u16 portlist, u16 flags,
				   bool *was_empty)
{
	unsigned int next;
	struct rtl_pktHdr *ph;
	struct rtl_mBuf *mb;

	if (unlikely(!ring || !skb || !data || len == 0))
		return -EINVAL;

	if (len < ETH_ZLEN)
		len = ETH_ZLEN;
	if (unlikely(len > 1518))
		return -EINVAL;

	next = ring->tx_prod + 1;
	if (next >= ring->tx_cnt)
		next = 0;

	if (unlikely(next == ring->tx_cons))
		return -ENOSPC;

	if (was_empty)
		*was_empty = (ring->tx_prod == ring->tx_cons);

	ph = rtl8196e_desc_ptr(ring->tx_ring[ring->tx_prod]);
	mb = ph->ph_mbuf;
	ring->last_tx_submit = ring->tx_prod;

	mb->m_len = len;
	mb->m_extsize = len;
	mb->m_data = data;
	mb->m_extbuf = data;
	mb->skb = skb;

	ph->ph_len = len;
	ph->ph_vlanId = vid;
	ph->ph_portlist = portlist & 0x3f;
	ph->ph_srcExtPortNum = 0;
	ph->ph_flags = flags;

	/* Flush descriptors (packet data flushed by caller) */
	dma_cache_wback_inv((unsigned long)ph, sizeof(*ph));
	dma_cache_wback_inv((unsigned long)mb, sizeof(*mb));

	/* Hand over to hardware - atomic write preserving WRAP bit */
	wmb();
	ring->tx_ring[ring->tx_prod] = (u32)ph | RTL8196E_DESC_SWCORE_OWNED |
					(ring->tx_ring[ring->tx_prod] & RTL8196E_DESC_WRAP);
	wmb();

	ring->tx_prod = next;

	return 0;
}

/* Walk the TX consumer ring, free completed SKBs, return the number of packets reclaimed. */
int rtl8196e_ring_tx_reclaim(struct rtl8196e_ring *ring,
				    unsigned int *pkts,
				    unsigned int *bytes,
				    int napi_budget)
{
	unsigned int done_pkts = 0;
	unsigned int done_bytes = 0;

	if (unlikely(!ring))
		return 0;

	while (ring->tx_cons != ring->tx_prod) {
		u32 entry;
		struct rtl_pktHdr *ph;
		struct rtl_mBuf *mb;
		struct sk_buff *skb;

		dma_cache_inv((unsigned long)&ring->tx_ring[ring->tx_cons], sizeof(u32));
		rmb();
		entry = ring->tx_ring[ring->tx_cons];
		if (entry & RTL8196E_DESC_OWNED_BIT)
			break;

		ph = rtl8196e_desc_ptr(entry);
		dma_cache_inv((unsigned long)ph, sizeof(*ph));
		mb = ph->ph_mbuf;
		dma_cache_inv((unsigned long)mb, sizeof(*mb));

		skb = (struct sk_buff *)mb->skb;
		if (likely(skb)) {
			done_pkts++;
			done_bytes += skb->len;
			napi_consume_skb(skb, napi_budget);
			mb->skb = NULL;
		}

		ring->tx_cons++;
		if (ring->tx_cons >= ring->tx_cnt)
			ring->tx_cons = 0;
	}

	if (pkts)
		*pkts = done_pkts;
	if (bytes)
		*bytes = done_bytes;

	return done_pkts;
}

/* NAPI RX poll: process up to @budget received packets and hand them to the stack. */
int rtl8196e_ring_rx_poll(struct rtl8196e_ring *ring, int budget,
				 struct napi_struct *napi,
				 struct net_device *dev)
{
	int work_done = 0;

	if (unlikely(!ring))
		return 0;

	while (work_done < budget) {
		u32 entry = ring->rx_pkthdr_ring[ring->rx_idx];
		struct rtl_pktHdr *ph;
		struct rtl_mBuf *mb;
		struct rtl8196e_rx_buf *rxb;
		struct sk_buff *skb, *new_skb;
		unsigned int len;
		unsigned int mbuf_index;

		if (entry & RTL8196E_DESC_OWNED_BIT)
			break;

		ph = rtl8196e_desc_ptr(entry);
		dma_cache_inv((unsigned long)ph, sizeof(*ph));
		mb = ph->ph_mbuf;
		dma_cache_inv((unsigned long)mb, sizeof(*mb));

		rxb = &ring->rx_bufs[ring->rx_idx];
		skb = rxb->skb;
		if (unlikely(!skb))
			goto rearm;

		len = ph->ph_len;
		if (unlikely(len < ETH_ZLEN || len > ring->buf_size))
			goto rearm_bad;

		/* Invalidate cache on packet data */
		dma_cache_inv((unsigned long)skb->data, len);

		/* Allocate a fresh SKB for the descriptor (NAPI-optimized) */
		new_skb = napi_alloc_skb(napi, ring->buf_size);
		if (unlikely(!new_skb))
			goto rearm;

		/* Set length on received SKB and hand to stack */
		skb_put(skb, len);
		skb->dev = dev;
		dev->stats.rx_packets++;
		dev->stats.rx_bytes += len;
		skb->protocol = eth_type_trans(skb, dev);
		skb->ip_summed = CHECKSUM_UNNECESSARY;
		if (unlikely(ring->rx_debug_once == 0)) {
			ring->rx_debug_once = 1;
			netdev_dbg(dev, "rx first len=%u flags=0x%04x port=0x%02x vid=%u\n",
				    len, ph->ph_flags, ph->ph_portlist, ph->ph_vlanId);
		}

		/* Install new SKB in descriptor */
		mb->m_data = new_skb->data;
		mb->m_extbuf = new_skb->data;
		mb->m_extsize = ring->buf_size;
		mb->m_len = 0;
		mb->skb = NULL;
		rxb->skb = new_skb;
		ph->ph_len = 0;
		ph->ph_flags = PKTHDR_USED | PKT_INCOMING;

		napi_gro_receive(napi, skb);
		work_done++;
		goto rearm;

rearm_bad:
		if (unlikely(ring->rx_debug_bad < 3)) {
			ring->rx_debug_bad++;
			netdev_warn(dev, "rx bad len=%u flags=0x%04x port=0x%02x vid=%u\n",
				    len, ph->ph_flags, ph->ph_portlist, ph->ph_vlanId);
		}

rearm:
		mbuf_index = (unsigned int)(mb - ring->rx_mbuf_base);
		if (likely(mbuf_index < ring->rx_mbuf_cnt)) {
			/* Atomic write preserving WRAP bit */
			ring->rx_mbuf_ring[mbuf_index] = (u32)mb | RTL8196E_DESC_SWCORE_OWNED |
							  (ring->rx_mbuf_ring[mbuf_index] & RTL8196E_DESC_WRAP);
		}

		ring->rx_pkthdr_ring[ring->rx_idx] =
			(u32)ph | (ring->rx_pkthdr_ring[ring->rx_idx] & RTL8196E_DESC_WRAP) | RTL8196E_DESC_SWCORE_OWNED;

		if (likely(rxb->skb))
			dma_cache_wback_inv((unsigned long)rxb->skb->head,
					    NET_SKB_PAD + ring->buf_size);
		dma_cache_wback_inv((unsigned long)ph, sizeof(*ph));
		dma_cache_wback_inv((unsigned long)mb, sizeof(*mb));

		ring->rx_idx++;
		if (ring->rx_idx >= ring->rx_cnt)
			ring->rx_idx = 0;
	}

	return work_done;
}

/* Return the number of free TX descriptor slots available for new submissions. */
int rtl8196e_ring_tx_free_count(struct rtl8196e_ring *ring)
{
	int used;

	if (!ring || ring->tx_cnt == 0)
		return 0;

	if (ring->tx_prod >= ring->tx_cons)
		used = ring->tx_prod - ring->tx_cons;
	else
		used = ring->tx_cnt - ring->tx_cons + ring->tx_prod;

	return (int)ring->tx_cnt - 1 - used;
}

/* Pulse the TXFD bit in CPUICR to trigger the TX DMA fetch engine. */
void rtl8196e_ring_kick_tx(bool was_empty)
{
	u32 icr;

	icr = *(volatile u32 *)CPUICR;
	*(volatile u32 *)CPUICR = icr | TXFD;
	wmb();
	(void)*(volatile u32 *)CPUICR;
	*(volatile u32 *)CPUICR = icr;
	mb();
	(void)*(volatile u32 *)CPUICR;
}

/* Reinitialise the TX ring after a watchdog timeout, freeing any in-flight SKBs. */
void rtl8196e_ring_tx_reset(struct rtl8196e_ring *ring)
{
	unsigned int i;

	if (!ring)
		return;

	for (i = 0; i < ring->tx_cnt; i++) {
		struct rtl_pktHdr *ph = &ring->pkthdr_pool[i];
		struct rtl_mBuf *mb = &ring->mbuf_pool[i];

		if (mb->skb) {
			dev_kfree_skb_any((struct sk_buff *)mb->skb);
			mb->skb = NULL;
		}

		memset(ph, 0, sizeof(*ph));
		memset(mb, 0, sizeof(*mb));

		ph->ph_mbuf = mb;
		ph->ph_flags = PKTHDR_USED | PKT_OUTGOING;
		ph->ph_type = PKTHDR_ETHERNET;
		ph->ph_portlist = 0;

		mb->m_pkthdr = ph;
		mb->m_flags = MBUF_USED | MBUF_EXT | MBUF_PKTHDR | MBUF_EOR;
		mb->m_data = NULL;
		mb->m_extbuf = NULL;
		mb->m_extsize = 0;

		ring->tx_ring[i] = (u32)ph | RTL8196E_DESC_RISC_OWNED;

		dma_cache_wback_inv((unsigned long)ph, sizeof(*ph));
		dma_cache_wback_inv((unsigned long)mb, sizeof(*mb));
	}

	if (ring->tx_cnt)
		ring->tx_ring[ring->tx_cnt - 1] |= RTL8196E_DESC_WRAP;

	ring->tx_prod = 0;
	ring->tx_cons = 0;
	ring->last_tx_submit = 0;
}

/* Return the ring index of the last successfully submitted TX descriptor (for debug). */
unsigned int rtl8196e_ring_last_tx_submit(struct rtl8196e_ring *ring)
{
	if (!ring)
		return 0;
	return ring->last_tx_submit;
}

/* Return the total capacity (number of slots) of the TX ring. */
unsigned int rtl8196e_ring_tx_count(struct rtl8196e_ring *ring)
{
	if (!ring)
		return 0;
	return ring->tx_cnt;
}

/* Return the raw descriptor entry at @idx in the TX ring (for debug). */
u32 rtl8196e_ring_tx_entry(struct rtl8196e_ring *ring, unsigned int idx)
{
	if (!ring || idx >= ring->tx_cnt)
		return 0;
	return ring->tx_ring[idx];
}

/* Return the current RX consumer index. */
unsigned int rtl8196e_ring_rx_index(struct rtl8196e_ring *ring)
{
	if (!ring)
		return 0;
	return ring->rx_idx;
}

/* Return the raw pkthdr descriptor entry at @idx in the RX ring (for debug). */
u32 rtl8196e_ring_rx_pkthdr_entry(struct rtl8196e_ring *ring, unsigned int idx)
{
	if (!ring || idx >= ring->rx_cnt)
		return 0;
	return ring->rx_pkthdr_ring[idx];
}

/* Return the raw mbuf descriptor entry at @idx in the RX mbuf ring (for debug). */
u32 rtl8196e_ring_rx_mbuf_entry(struct rtl8196e_ring *ring, unsigned int idx)
{
	if (!ring || idx >= ring->rx_mbuf_cnt)
		return 0;
	return ring->rx_mbuf_ring[idx];
}
