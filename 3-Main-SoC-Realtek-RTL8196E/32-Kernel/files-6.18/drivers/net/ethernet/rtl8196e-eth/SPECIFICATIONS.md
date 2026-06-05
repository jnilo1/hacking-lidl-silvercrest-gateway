# RTL8196E Minimal Ethernet Driver (Linux 6.18) — Specification

## 1. Goals

- Clean, single-purpose driver targeting the RTL8196E SoC only.
- Single physical Ethernet port (port 4 on the Lidl Silvercrest gateway).
- Maximum performance (zero-copy RX via `napi_alloc_skb`, direct TX).
- Compatible with existing devicetree (`&ethernet` + `interface@0`).
- IPv4 and IPv6 handled entirely by the Linux network stack.
- NAPI polling, hardware interrupts, basic ethtool stats.
- No kernel patches required (pure in-tree driver, no external dependencies).

## 2. Non-goals

- QoS / multiple queues / netfilter offload / L3-L4 hardware acceleration.
- Multiple hardware VLANs (single netdev only).
- Scatter-gather (`NETIF_F_SG` not advertised on the production driver — the
  HW supports it, see `MEMO-tx-throughput-verdict.md` and the
  `feat/tx-throughput` archive branch for the rejected SG implementation).
- XDP.

## 3. Hardware constraints (isolated in `rtl8196e_hw.*`)

- DMA uses KSEG1 addresses (`0xAxxxxxxx` via bit 29), not standard `dma_addr_t`.
- TX requires explicit cache flush: `dma_cache_wback_inv()`.
- RX/TX descriptor reads require cache invalidate: `dma_cache_inv()`.
- Two RX rings required: pkthdr (descriptors) + mbuf (buffers).
- Mandatory init sequence: MEMCR, full reset, PHY init, TRXRDY.
- L2 toCPU entry required for CPU packet reception.
- IRQ routed through SoC interrupt controller (GIMR bit 15).
- BIST skipped (must not block init).

## 4. RX buffer management (`napi_alloc_skb`)

- Hot path uses `napi_alloc_skb(napi, buf_size)` — NAPI-optimized allocation
  using a per-CPU page frag cache.  Avoids locks, maximizes cache locality.
  Internally adds `NET_SKB_PAD` headroom and calls `skb_reserve`.
- Ring init uses `netdev_alloc_skb_ip_align(NULL, ...)` (no NAPI context at
  probe time).
- Pre-allocated SKBs stored in shadow array `rx_bufs[]`
  (`struct rtl8196e_rx_buf { struct sk_buff *skb }`), one per RX descriptor.
- On each RX: the old SKB is handed to the stack, a new SKB is allocated
  with `napi_alloc_skb(napi, buf_size)`, and its `data` pointer is installed
  in the hardware descriptor.
- On destroy: `dev_kfree_skb_any()` for each shadow entry.
- No `page_pool`, no `build_skb()`, no PAGE_POOL Kconfig dependency.

## 5. Devicetree compatibility

- Parent node: `&ethernet` (compatible: `realtek,rtl8196e-mac`).
- Reads the first child `interface@0` (matched by `reg = <0>`):
  - `ifname` — interface name (default: `eth0`)
  - `local-mac-address` — MAC address (random if absent)
  - `vlan-id` — VLAN ID (default: 1)
  - `member-ports` — port bitmask (port 4 = `0x10`); must fit in the
    9-port HW window (`0x1ff`), driver rejects anything outside (since v2.4)
  - `untag-ports` — untag bitmask; must be a subset of `member-ports`
    (since v2.4)
  - `mtu` — MTU (default: 1500)
  - `phy-id` — PHY address for MDIO (default: same as port number)
  - `link-poll-ms` — link status polling interval (also on parent node)
- Extra interface nodes are ignored with a warning.

## 6. File architecture

| File              | Role                                                                          | Pure LOC |
|-------------------|-------------------------------------------------------------------------------|---------:|
| `rtl8196e_main.c` | net_device, NAPI poll, ISR, TX xmit, ethtool, sysfs (LED), probe/remove       |      574 |
| `rtl8196e_hw.c`   | MMIO registers, init sequence, KSEG1 helpers, PHY/MDIO, VLAN/NETIF/L2 tables  |      555 |
| `rtl8196e_ring.c` | TX/RX descriptor rings, kick coalescing, napi_alloc_skb RX buffers, cache ops |      529 |
| `rtl8196e_dt.c`   | Devicetree parsing (`interface@0` properties)                                 |       92 |
| `rtl8196e_regs.h` | Register definitions (trimmed to what's used)                                 |      133 |
| `rtl8196e_desc.h` | Hardware descriptor structures (`rtl_pktHdr`, `rtl_mBuf`)                     |       89 |
| `rtl8196e_ring.h` | Ring API                                                                      |       41 |
| `rtl8196e_hw.h`   | HW API                                                                        |       29 |
| `rtl8196e_dt.h`   | DT API                                                                        |       19 |
| **Total**         |                                                                               | **2 061** |

Pure LOC = non-blank, non-comment lines.  For comparison, the legacy
`rtl819x` driver (17 files) totalled ~9 660 pure LOC — a 4.7× reduction.

## 7. RX path (`napi_alloc_skb`)

- Two RX rings:
  - pkthdr ring (descriptors) — `RTL8196E_RX_DESC` (128) entries
  - mbuf ring (buffers) — `RTL8196E_RX_MBUF_DESC` (128) entries
- Buffer allocation via `napi_alloc_skb(napi, buf_size)` (NAPI-optimized).
- Data placed at `skb->data` (after `NET_SKB_PAD` headroom, added internally).
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

- Single TX ring: `RTL8196E_TX_DESC` (128) entries.
- `rtl8196e_start_xmit()` → `rtl8196e_ring_tx_submit()`:
  - Non-linear SKBs linearized via `skb_linearize()`.
  - Short packets padded to `ETH_ZLEN` via `skb_put_padto()`,
    oversized (>1518) rejected.
  - Packet data flushed before submit (`dma_cache_wback_inv` on `skb->data`).
  - Descriptor flushes (pkthdr + mbuf) inside `tx_submit`.
  - No spinlock: uniprocessor SoC, `start_xmit` runs with BH disabled.
  - Atomic ownership transfer (single write preserving WRAP bit).
- TX kick (`rtl8196e_ring_kick_tx(ring, was_empty)`):
  - Coalesced — pulses the `TXFD` bit on `CPUICR` at most once per
    `rtl8196e_kick_threshold` submits (default 4), except on cold-start
    (`was_empty == true`) where it always pulses immediately so the ASIC
    TX DMA engine can wake.
  - `rtl8196e_ring_kick_drain(ring)` is invoked at the end of every NAPI
    poll to flush sub-threshold bursts before the queue goes idle.
  - Coalescing introduced in v3.4.1; cf. `MEMO-tx-throughput-verdict.md`.
- TX reclaim (`rtl8196e_ring_tx_reclaim()`):
  - Called from NAPI poll with `napi_budget > 0` (uses `napi_consume_skb`
    for batched SKB freeing).
  - Called unconditionally from `start_xmit` (no TX completion IRQ).
  - No TX timer.
- TX completion: `TX_ALL_DONE` interrupt is **not** unmasked in
  `CPUIIMR`.  Reclaim is entirely software, driven by NAPI poll
  (RX traffic side) and by the unconditional reclaim at the head of
  every `start_xmit` (process side).
- Flow control:
  - `netif_stop_queue()` when free count `< 4` (`RTL8196E_TX_STOP_THRESH`).
  - `netif_wake_queue()` when free count `>= 16` (`RTL8196E_TX_WAKE_THRESH`),
    checked in NAPI poll after TX reclaim.
- No BQL (unnecessary overhead on single-queue 100 Mbit/s embedded SoC).
- TX timeout: full TX ring reset with SKB cleanup, re-init HW TX ring.

## 9. PHY / Link

- Minimal PHY init sequence extracted from legacy driver, isolated in
  `rtl8196e_hw.c`.
- Link status read from port registers.
- `netif_carrier_on/off` updated on link change IRQ and poll timer.
- Link poll timer interval configurable via DT (`link-poll-ms`) or module
  param.

## 10. Constants

| Constant                  | Value | Location          |
|---------------------------|------:|-------------------|
| `RTL8196E_TX_DESC`        |   128 | `rtl8196e_main.c` |
| `RTL8196E_RX_DESC`        |   128 | `rtl8196e_main.c` |
| `RTL8196E_RX_MBUF_DESC`   |   128 | `rtl8196e_main.c` |
| `RTL8196E_CLUSTER_SIZE`   |  1700 | `rtl8196e_main.c` (`buf_size` passed to ring) |
| `RTL8196E_TX_STOP_THRESH` |     4 | `rtl8196e_main.c` |
| `RTL8196E_TX_WAKE_THRESH` |    16 | `rtl8196e_main.c` |
| `rtl8196e_kick_threshold` |     4 | `rtl8196e_ring.c` (extern, `EXPORT_SYMBOL`, runtime tunable via future hook) |
| `RTL8196E_DRV_VERSION`    | "2.6" | `rtl8196e_main.c` |

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
10. `rtl8196e_hw_start()`: CPUICR (`TXCMD | RXCMD | BURST_32 | MBUF_2048 |
    EXCLUDE_CRC`), TRXRDY.
11. `rtl8196e_hw_enable_irqs()`: CPUIIMR (`RX_DONE_IE_ALL | LINK_CHANGE_IE
    | PKTHDR_DESC_RUNOUT_IE_ALL`).  TX completion is **not** unmasked
    here (software reclaim).
12. Start queue, check link, start link poll timer.

## 12. Module parameters

All exposed under `/sys/module/rtl8196e_eth/parameters/` once the
driver is loaded.  All read/write at runtime (mode 0644).

| Parameter                | Type          | Default               | Purpose                                                  |
|--------------------------|---------------|----------------------:|----------------------------------------------------------|
| `link_poll_ms`           | unsigned int  | 0 (disabled)          | Link poll interval in ms; 0 disables the poll timer      |
| `rtl8196e_debug`         | unsigned int  | 0                     | Extra debug logging (descriptor dumps via `dbg_timer`)   |
| `rtl8196e_force_trap`    | unsigned int  | 0                     | Force all unknown traffic to CPU (debug)                 |
| `rtl8196e_cpu_port_mask` | unsigned int  | `RTL8196E_CPU_PORT_MASK` (0x20) | CPU port mask for VLAN / L2                |

## 13. Sysfs attributes (under `/sys/class/net/eth0/`)

| Attribute  | Mode | Purpose                                                                |
|------------|------|------------------------------------------------------------------------|
| `led_mode` | RW   | Front-panel LED mode: `bright` / `dim` / `off` (drives LEDCREG/DIRECTLCR) |

## 14. Ethtool stats (`ethtool -S eth0`)

7 driver-private stats (count returned by `get_sset_count(ETH_SS_STATS)`):

- `rtl8196e_l2_check_ok` — successful L2 toCPU entry verifications
- `rtl8196e_l2_check_fail` — failed L2 toCPU entry verifications
- `rtl8196e_l2_check_last_result` — last L2 check return code
- `rtl8196e_tx_dbg_portmask` — port mask used for first TX packet
- `rtl8196e_tx_dbg_vid` — VLAN ID used for first TX packet
- `rtl8196e_tx_dbg_len` — length of first TX packet
- `rtl8196e_tx_dbg_submit` — whether first TX submit succeeded

## 15. Verification (v3.4.1, kernel 6.18.24, RLX4181 @ 380 MHz)

Direct cable host ↔ gateway, iperf 2.x, 5 × 60 s per workload, median:

- TCP RX (host → gateway): **93.5 Mbit/s** (line-rate)
- TCP TX (gateway → host): **70.1 Mbit/s** (Track A coalescing applied)
- UDP TX 100M (gateway → host): **37.9 Mbit/s**
- UDP storm 64-byte payload: **1.87 Mbit/s**

Functional checks:

- `ping` IPv4 / IPv6.
- Stable SSH session.
- 0 driver TX/RX errors, 0 TCP retransmissions on the SoC side over a
  300 s stress.
- `ethtool -S eth0` shows the 7 driver-private stats.
- No warnings in dmesg.

See `PERFORMANCE.md` for the full per-phase TX path decomposition,
asymptote analysis, and the four orthogonal-levers tracks measured in
the v3.4.1 perf session.
