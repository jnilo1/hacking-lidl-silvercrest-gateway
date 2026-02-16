# RTL8196E Minimal Ethernet Driver (Linux 5.10) - Specification

## 1. Goals
- Clean, single-purpose driver targeting the RTL8196E SoC only.
- Single physical Ethernet port (port 4 on the Lidl Silvercrest gateway).
- Maximum performance (zero-copy RX via page_pool, direct TX).
- Compatible with existing devicetree (`&ethernet` + `interface@0`).
- IPv4 and IPv6 handled entirely by the Linux network stack.
- NAPI polling, hardware interrupts, basic ethtool stats.
- No kernel patches required (pure in-tree driver + `select PAGE_POOL`).

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

## 4. RX buffer management (page_pool)
- Uses the kernel's standard `page_pool` API (`include/net/page_pool.h`).
- `page_pool_create()` with `flags=0` (no DMA mapping — hardware uses
  KSEG1 uncached addresses and manual cache management).
- Pool size: 512 pages (`RTL8196E_PP_SIZE`), order-0.
- Allocation: `page_pool_dev_alloc_pages()` returns one page per RX slot.
- Page-reuse pattern (Linux 5.10 lacks `skb_mark_for_recycle()`):
  - If `page_ref_count(page) == 1` → sole owner → `get_page()` + reuse.
  - Otherwise → allocate a new page from the pool.
- `build_skb(page_address(page), PAGE_SIZE)` sets `head_frag=1`.
  On SKB free the kernel calls `skb_free_frag()` → `put_page()`.
  No kernel patch needed.
- Shadow array `rx_bufs[]` (`struct rtl8196e_rx_buf { page, offset }`)
  tracks the page and data offset per RX descriptor.
- Kconfig: `select PAGE_POOL`.
- The overlay's `net/core/skbuff.c` restores vanilla `skb_free_head()`
  (removes legacy `is_rtl865x_eth_priv_buf` / `free_rtl865x_eth_priv_buf` hooks).

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

| File | Role |
|------|------|
| `rtl8196e_main.c` | net_device, NAPI poll, ISR, TX xmit, ethtool, probe/remove, page_pool lifecycle |
| `rtl8196e_hw.c/h` | MMIO registers, init sequence, KSEG1 helpers, PHY/MDIO, VLAN/NETIF/L2 tables |
| `rtl8196e_ring.c/h` | TX/RX descriptor rings, page_pool RX buffers, ownership, cache ops |
| `rtl8196e_dt.c/h` | Devicetree parsing (`interface@0` properties) |
| `rtl8196e_desc.h` | Hardware descriptor structures (`rtl_pktHdr`, `rtl_mBuf`) |
| `rtl8196e_regs.h` | Register definitions (trimmed to what's used) |
| `Kconfig` | Kernel config entry (`select PAGE_POOL`) |
| `Makefile` | Build: `rtl8196e_main.o rtl8196e_hw.o rtl8196e_ring.o rtl8196e_dt.o` |

## 7. RX path (zero-copy via page_pool)
- Two RX rings:
  - pkthdr ring (descriptors) — `RTL8196E_RX_DESC` (500) entries
  - mbuf ring (buffers) — `RTL8196E_RX_MBUF_DESC` (500) entries
- Buffer allocation via `page_pool_dev_alloc_pages()`.
- Data placed at `page_address(page) + NET_SKB_PAD`.
- NAPI poll (`rtl8196e_ring_rx_poll()`):
  1. Check descriptor ownership bit.
  2. Invalidate cache on pkthdr + mbuf descriptors.
  3. Invalidate cache on packet data (only `len` bytes).
  4. Page-reuse check: `page_ref_count == 1` → reuse, else alloc new.
  5. `build_skb()` from page, `skb_reserve()` + `skb_put()`.
  6. `eth_type_trans()`, `napi_gro_receive()`.
  7. Install new/reused page in mbuf descriptor.
  8. Rearm pkthdr + mbuf ownership bits (preserving WRAP).
  9. Flush cache on full page + descriptors.

## 8. TX path
- Single TX ring: `RTL8196E_TX_DESC` (600) entries.
- `rtl8196e_start_xmit()` → `rtl8196e_ring_tx_submit()`:
  - Non-linear SKBs linearized via `skb_linearize()`.
  - Short packets padded to `ETH_ZLEN`, oversized (>1518) rejected.
  - Single cache flush per packet (`dma_cache_wback_inv` on data + descriptors).
  - Atomic ownership transfer (single write preserving WRAP bit).
- TX kick: `TXFD` pulse on every submit via `rtl8196e_ring_kick_tx()`.
- TX reclaim (`rtl8196e_ring_tx_reclaim()`):
  - Called from NAPI poll (opportunistic).
  - Called from TX timer (2 ms, `RTL8196E_TX_TIMER_MS`) when `tx_pending > 0`.
  - Called from `start_xmit` on submit failure (emergency reclaim).
- Flow control:
  - `netif_stop_queue()` when free count < 32 (`RTL8196E_TX_STOP_THRESH`).
  - `netif_wake_queue()` when free count >= 128 (`RTL8196E_TX_WAKE_THRESH`).
- BQL: `netdev_tx_sent_queue()` / `netdev_tx_completed_queue()`.
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
| `RTL8196E_PP_SIZE` | 512 | `rtl8196e_main.c` |
| `RTL8196E_CLUSTER_SIZE` | 1700 | `rtl8196e_main.c` (buf_size passed to ring) |
| `RTL8196E_TX_STOP_THRESH` | 32 | `rtl8196e_main.c` |
| `RTL8196E_TX_WAKE_THRESH` | 128 | `rtl8196e_main.c` |
| `RTL8196E_TX_TIMER_MS` | 2 | `rtl8196e_main.c` |

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
- iperf TCP RX >= 80 Mbps, TX gap < 10% vs RX.
- `ethtool -S eth0` shows stats.
- No page_pool warnings in dmesg.
- `grep -c is_rtl865x vmlinux` returns 0 (no legacy pool hooks).
