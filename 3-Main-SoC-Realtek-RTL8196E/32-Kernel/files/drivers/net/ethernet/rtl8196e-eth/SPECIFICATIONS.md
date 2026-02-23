# RTL8196E Minimal Ethernet Driver (Linux 5.10) - Specification

## 1. Goals
- Clean, single-purpose driver targeting the RTL8196E SoC only.
- Single physical Ethernet port (port 4 on the Lidl Silvercrest gateway).
- Maximum performance (zero-copy RX via napi_alloc_skb, direct TX).
- Compatible with existing devicetree (`&ethernet` + `interface@0`).
- IPv4 and IPv6 handled entirely by the Linux network stack.
- NAPI polling, hardware interrupts, basic ethtool stats.
- No kernel patches required (pure in-tree driver, no external dependencies).

## 2. Non-goals
- QoS / multiple queues / netfilter offload / L3-L4 hardware acceleration.
- Multiple hardware VLANs (single netdev only).
- Scatter-gather (`NETIF_F_SG` disabled).
- XDP.

## 3. Hardware constraints (isolated in `rtl8196e_hw.*`)
- DMA uses KSEG1 addresses (0xAxxxxxxx via bit 29), not standard `dma_addr_t`.
- TX requires explicit cache flush: `dma_cache_wback_inv()`.
- RX/TX descriptor reads require cache invalidate: `dma_cache_inv()`.
- Two RX rings required: pkthdr (descriptors) + mbuf (buffers).
- Mandatory init sequence: MEMCR, full reset, PHY init, TRXRDY.
- L2 toCPU entry required for CPU packet reception.
- IRQ routed through SoC interrupt controller (GIMR bit 15).
- BIST skipped (must not block init).

## 4. RX buffer management (napi_alloc_skb)
- Hot path uses `napi_alloc_skb(napi, buf_size)` — NAPI-optimized allocation
  using a per-CPU page frag cache. Avoids locks, maximizes cache locality.
  Internally adds `NET_SKB_PAD` headroom and calls `skb_reserve`.
- Ring init uses `netdev_alloc_skb(NULL, ...)` (no NAPI context at probe time).
- Pre-allocated SKBs stored in shadow array `rx_bufs[]`
  (`struct rtl8196e_rx_buf { struct sk_buff *skb }`), one per RX descriptor.
- On each RX: the old SKB is handed to the stack, a new SKB is allocated
  with `napi_alloc_skb(napi, buf_size)`, and its `data` pointer is installed
  in the hardware descriptor.
- On destroy: `dev_kfree_skb_any()` for each shadow entry.
- No `page_pool`, no `build_skb()`, no PAGE_POOL Kconfig dependency.
- The `patches/net-core-skbuff.c.patch` (legacy rtl819x private buffer pool
  hooks) is applied to all builds but guarded with `#ifdef CONFIG_RTL819X`;
  it has no effect when `rtl8196e-eth` is selected.

## 5. Devicetree compatibility
- Parent node: `&ethernet` (compatible: `realtek,rtl8196e-mac`).
- Reads the first child `interface@0` (matched by `reg = <0>`):
  - `ifname` — interface name (default: `eth0`)
  - `local-mac-address` — MAC address (random if absent)
  - `vlan-id` — VLAN ID (default: 1)
  - `member-ports` — port bitmask (port 4 = `0x10`)
  - `untag-ports` — untag bitmask
  - `mtu` — MTU (default: 1500)
  - `phy-id` — PHY address for MDIO (default: same as port number)
  - `link-poll-ms` — link status polling interval (also on parent node)
- Extra interface nodes are ignored with a warning.

## 6. File architecture

| File | Role | Pure LOC |
|------|------|----------|
| `rtl8196e_main.c` | net_device, NAPI poll, ISR, TX xmit, ethtool, probe/remove | 501 |
| `rtl8196e_hw.c` | MMIO registers, init sequence, KSEG1 helpers, PHY/MDIO, VLAN/NETIF/L2 tables | 554 |
| `rtl8196e_ring.c` | TX/RX descriptor rings, napi_alloc_skb RX buffers, ownership, cache ops | 439 |
| `rtl8196e_dt.c` | Devicetree parsing (`interface@0` properties) | 68 |
| `rtl8196e_regs.h` | Register definitions (trimmed to what's used) | 120 |
| `rtl8196e_desc.h` | Hardware descriptor structures (`rtl_pktHdr`, `rtl_mBuf`) | 89 |
| `rtl8196e_ring.h` | Ring API | 38 |
| `rtl8196e_hw.h` | HW API | 27 |
| `rtl8196e_dt.h` | DT API | 19 |
| **Total** | | **1 855** |

Pure LOC = non-blank, non-comment lines.
For comparison, the legacy `rtl819x` driver (17 files) totals **9 664 pure LOC** — a **5.2× reduction**.

## 7. RX path (napi_alloc_skb)
- Two RX rings:
  - pkthdr ring (descriptors) — `RTL8196E_RX_DESC` (500) entries
  - mbuf ring (buffers) — `RTL8196E_RX_MBUF_DESC` (500) entries
- Buffer allocation via `napi_alloc_skb(napi, buf_size)` (NAPI-optimized).
- Data placed at `skb->data` (after NET_SKB_PAD headroom, added internally).
- NAPI poll (`rtl8196e_ring_rx_poll()`):
  1. Check descriptor ownership bit.
  2. Invalidate cache on pkthdr + mbuf descriptors.
  3. Invalidate cache on packet data (only `len` bytes).
  4. `napi_alloc_skb()` — allocate a fresh SKB for the descriptor.
  5. `skb_put()` on old SKB to set length.
  6. `eth_type_trans()`, `napi_gro_receive()`.
  7. Install fresh SKB's `data` pointer in mbuf descriptor.
  8. Rearm pkthdr + mbuf ownership bits (preserving WRAP).
  9. Flush cache on `skb->head` for `NET_SKB_PAD + buf_size` + descriptors.

## 8. TX path
- Single TX ring: `RTL8196E_TX_DESC` (600) entries.
- `rtl8196e_start_xmit()` → `rtl8196e_ring_tx_submit()`:
  - Non-linear SKBs linearized via `skb_linearize()`.
  - Short packets padded to `ETH_ZLEN`, oversized (>1518) rejected.
  - Packet data flushed before submit (`dma_cache_wback_inv` on `skb->data`).
  - Descriptor flushes (pkthdr + mbuf) inside `tx_submit`.
  - No spinlock: uniprocessor SoC, `start_xmit` runs with BH disabled.
  - Atomic ownership transfer (single write preserving WRAP bit).
- TX kick: `TXFD` pulse on every submit via `rtl8196e_ring_kick_tx()`.
  Hardware requires kick for every packet (conditional kick breaks boot).
- TX reclaim (`rtl8196e_ring_tx_reclaim()`):
  - Called from NAPI poll with `napi_budget > 0` (uses `napi_consume_skb`
    for batched SKB freeing).
  - Called from `start_xmit` on submit failure (emergency reclaim).
  - No TX timer — NAPI poll handles reclaim + queue wake via TX_DONE IRQs.
- Flow control:
  - `netif_stop_queue()` when free count < 16 (`RTL8196E_TX_STOP_THRESH`).
  - `netif_wake_queue()` when free count >= 64 (`RTL8196E_TX_WAKE_THRESH`),
    checked in NAPI poll after TX reclaim.
- No BQL (unnecessary overhead on single-queue 100 Mbps embedded SoC).
- TX timeout: full TX ring reset with SKB cleanup, re-init HW TX ring.

## 9. PHY / Link
- Minimal PHY init sequence extracted from legacy driver, isolated in `rtl8196e_hw.c`.
- Link status read from port registers.
- `netif_carrier_on/off` updated on link change IRQ and poll timer.
- Link poll timer interval configurable via DT (`link-poll-ms`) or module param.

## 10. Constants

| Constant | Value | Location |
|----------|-------|----------|
| `RTL8196E_TX_DESC` | 600 | `rtl8196e_main.c` |
| `RTL8196E_RX_DESC` | 500 | `rtl8196e_main.c` |
| `RTL8196E_RX_MBUF_DESC` | 500 | `rtl8196e_main.c` |
| `RTL8196E_CLUSTER_SIZE` | 1700 | `rtl8196e_main.c` (buf_size passed to ring) |
| `RTL8196E_TX_STOP_THRESH` | 16 | `rtl8196e_main.c` |
| `RTL8196E_TX_WAKE_THRESH` | 64 | `rtl8196e_main.c` |

## 11. Init sequence (in `rtl8196e_open()`)
1. Enable NAPI.
2. `rtl8196e_hw_init()`: clock enable, MEMCR (0 then 0x7f), FULL_RST + delay.
3. Set RX rings (pkthdr + mbuf base addresses) and TX ring base address.
4. `rtl8196e_hw_init_phy()`: PHY init for the configured port.
5. `rtl8196e_hw_vlan_setup()`: VLAN table entry.
6. `rtl8196e_hw_netif_setup()`: NETIF table entry (MAC, VLAN, MTU, port mask).
7. `rtl8196e_hw_l2_setup()`: L2 table init, STP forwarding.
8. `rtl8196e_hw_l2_add_cpu_entry()`: toCPU L2 entry for driver MAC.
9. `rtl8196e_hw_l2_add_bcast_entry()`: broadcast flood + CPU entry.
10. `rtl8196e_hw_start()`: CPUICR (TXCMD | RXCMD | BURST_32 | MBUF_2048 | EXCLUDE_CRC), TRXRDY.
11. `rtl8196e_hw_enable_irqs()`: CPUIIMR (RX_DONE | TX_DONE | LINK_CHANGE | RUNOUT).
12. Start queue, check link, start link poll timer.

## 12. Ethtool stats
7 stats exported via `ethtool -S`:
- `rtl8196e_l2_check_ok` — successful L2 toCPU entry verifications
- `rtl8196e_l2_check_fail` — failed L2 toCPU entry verifications
- `rtl8196e_l2_check_last_result` — last L2 check return code
- `rtl8196e_tx_dbg_portmask` — port mask used for first TX packet
- `rtl8196e_tx_dbg_vid` — VLAN ID used for first TX packet
- `rtl8196e_tx_dbg_len` — length of first TX packet
- `rtl8196e_tx_dbg_submit` — whether first TX submit succeeded

## 13. Verification
- Ping IPv4/IPv6.
- Stable SSH session.
- iperf TCP RX: 91.2 Mbps (legacy rtl819x: 85.7 Mbps, +6.4%).
- iperf TCP TX: 46.9 Mbps (legacy rtl819x: 43.4 Mbps, +8.1%).
- TCP stress 300s: 92.0 Mbps, 0 driver errors, 0 TCP retransmissions (SoC side).
- `ethtool -S eth0` shows stats.
- No warnings in dmesg.

Measured on RTL8196E gateway (Lidl Silvercrest), Ubuntu 22.04 host,
iperf 2.x, 30s TCP tests, kernel 5.10.246-rtl8196e-eth.
