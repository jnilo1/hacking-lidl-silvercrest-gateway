# RTL8196E Ethernet driver (`rtl8196e-eth`) — specification

| | |
|---|---|
| **Document date** | 2026-06-12 |
| **Driver version** | 2.8 (`RTL8196E_DRV_VERSION` in `rtl8196e_main.c`) — 2.7/2.8 only change probe-time pad muxing (`PIN_MUX_SEL_2` derived from `gpio-line-names` + `realtek,led-pads`), nothing in the datapath spec below |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`) |

Goals/non-goals contract and externally observable behaviour of the
driver. The architecture rationale lives in `DESIGN.md`, findings and
audit history in `AUDIT.md`, throughput history in `PERFORMANCE.md`
(all in this directory).

---

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
  HW supports it, see `MEMO-tx-throughput-verdict.md` at the repo root and
  the `feat/tx-throughput` archive branch for the rejected SG implementation).
- XDP.

## 3. Hardware constraints (isolated in `rtl8196e_hw.*` / `rtl8196e_ring.c`)

- DMA registers and descriptors are programmed with **virtual** addresses
  (KSEG1 for the ring arrays, KSEG0 for pools and buffers), not
  `dma_addr_t` — the ASIC ignores the segment bits (AUDIT F17/ETH-S01).
- Non-coherent write-back L1: TX data requires `dma_cache_wback_inv()`
  before submit; HW-written descriptors require `dma_cache_inv()` before
  reading (full model in `DESIGN.md` §3).
- Two RX rings required: pkthdr (descriptors) + mbuf (buffers).
- Mandatory init sequence: pinmux (via syscon, shared registers —
  AUDIT ETHDRV-007), switch clock cycle, MEMCR, full reset, PHY init,
  TRXRDY.
- L2 toCPU entry required for CPU packet reception (trap-all fallback
  when it cannot be installed or verified).
- IRQ routed through SoC interrupt controller (GIMR bit 15).
- BIST skipped (must not block init).

## 4. RX buffer management (`napi_alloc_skb`)

- Hot path uses `napi_alloc_skb(napi, buf_size)` — NAPI-optimized allocation
  using a per-CPU page frag cache.  Avoids locks, maximizes cache locality.
  Internally adds `NET_SKB_PAD` headroom and calls `skb_reserve`.
- Ring init uses `netdev_alloc_skb_ip_align(NULL, ...)` (no NAPI context at
  probe time).
- Pre-allocated SKBs stored in shadow array `rx_bufs[]`
  (`struct rtl8196e_rx_buf { struct sk_buff *skb }`), one per RX
  descriptor. Since driver 2.6 the poll path looks the shadow up by
  the **hardware mbuf index** (pool-bounds guarded; misses counted in
  `rtl8196e_rx_mbuf_no_shadow`) instead of trusting ring-position
  correspondence.
- On each RX: the old SKB is handed to the stack, a new SKB is allocated
  with `napi_alloc_skb(napi, buf_size)`, and its `data` pointer is installed
  in the hardware descriptor.
- On destroy: `dev_kfree_skb_any()` for each shadow entry.
- No `page_pool`, no `build_skb()`, no PAGE_POOL Kconfig dependency.

## 5. Devicetree compatibility

- Parent node: `&ethernet` (compatible: `realtek,rtl8196e-mac`).
- Reads the first child `interface@0` (matched by `reg = <0>`):
  - `ifname` — interface name (default: `eth0`)
  - `local-mac-address` — MAC address (random if absent; the Lidl DTS
    deliberately omits it — S10network persists the random MAC to
    `/userdata/etc/mac_address` and restores it on every boot)
  - `vlan-id` — VLAN ID (default: 1)
  - `member-ports` — port bitmask (port 4 = `0x10`); must fit in the
    9-port HW window (`0x1ff`), driver rejects anything outside (since v2.4)
  - `untag-ports` — untag bitmask; must be a subset of `member-ports`
    (since v2.4)
  - `mtu` — MTU (default: 1500, accepted range 576–1500)
  - `phy-id` — PHY address for MDIO (default: same as port number)
  - `link-poll-ms` — link status polling interval (also on parent node)
- Additional interface nodes are silently ignored (the first child
  with `reg = <0>` wins; a warning is emitted only when no
  `interface@0` node is found at all).
- The `realtek,syscon` phandle is mandatory: probe defers on
  `-EPROBE_DEFER` and fails on any other lookup error (ETHDRV-001).

## 6. File architecture

| File              | Role                                                                          | Pure LOC |
|-------------------|-------------------------------------------------------------------------------|---------:|
| `rtl8196e_main.c` | net_device, NAPI poll, ISR, TX xmit, ethtool, sysfs, probe/remove             |      692 |
| `rtl8196e_hw.c`   | MMIO registers, init sequence, KSEG1 helpers, PHY/MDIO, VLAN/NETIF/L2 tables  |      584 |
| `rtl8196e_ring.c` | TX/RX descriptor rings, kick coalescing, napi_alloc_skb RX buffers, cache ops |      627 |
| `rtl8196e_dt.c`   | Devicetree parsing (`interface@0` properties)                                 |       92 |
| `rtl8196e_regs.h` | Register definitions (trimmed to what's used)                                 |      140 |
| `rtl8196e_desc.h` | Hardware descriptor structures (`rtl_pktHdr`, `rtl_mBuf`)                     |       93 |
| `rtl8196e_ring.h` | Ring API                                                                      |       60 |
| `rtl8196e_hw.h`   | HW API                                                                        |       31 |
| `rtl8196e_dt.h`   | DT API                                                                        |       19 |
| **Total**         |                                                                               | **2 338** |

Pure LOC = non-blank, non-comment lines (`gcc -fpreprocessed -dD -E -P`),
re-verified exact at driver 2.6 on 2026-06-12. For comparison, the
legacy `rtl819x` driver (17 files) totalled ~9 660 pure LOC — a ~4×
reduction.

## 7. RX path

- Two RX rings:
  - pkthdr ring (descriptors) — `RTL8196E_RX_DESC` (128) entries
  - mbuf ring (buffers) — `RTL8196E_RX_MBUF_DESC` (128) entries
- Buffer allocation via `napi_alloc_skb(napi, buf_size)` (NAPI-optimized).
- Data placed at `skb->data` (after `NET_SKB_PAD` headroom, added internally).
- NAPI poll (`rtl8196e_ring_rx_poll()`), per RISC-owned entry up to budget:
  1. Check descriptor ownership bit.
  2. Validate the pkthdr pointer against the pool bounds (fallback to
     the static index mapping, `rx_wild_pkthdr`); invalidate + read it.
  3. Validate `ph_mbuf` the same way (`rx_wild_mbuf`); invalidate + read.
  4. Look the shadow SKB up by **hardware mbuf index**, guarded
     `< rx_cnt` (`rx_mbuf_no_shadow`).
  5. Bound-check `ph_len` to `[ETH_ZLEN, buf_size]` (`rx_bad_len`).
  6. Invalidate cache on packet data (only `len` bytes).
  7. `napi_alloc_skb()` — allocate a fresh SKB for the descriptor.
  8. `skb_put()` on old SKB, `eth_type_trans()`, `napi_gro_receive()`.
  9. Rearm from a **canonical descriptor state on every exit path**
     (nominal / drop / bad-length — ETHDRV-002): reset ph/mb fields,
     install the fresh SKB's `data`, flush buffer + descriptors,
     `wmb()`, flip both ring entries to SWCORE_OWNED (preserving WRAP).
- `ip_summed = CHECKSUM_UNNECESSARY` is applied blanket — the
  documented, bench-forced trade-off (AUDIT §1.3, ETHDRV-003).

## 8. TX path

- Single TX ring: `RTL8196E_TX_DESC` (128) entries.
- `rtl8196e_start_xmit()` → `rtl8196e_ring_tx_submit()`:
  - Non-linear SKBs linearized via `skb_linearize()`.
  - Short packets padded to `ETH_ZLEN` via `skb_put_padto()` **before**
    the data flush (info-leak guard, ETH-001); oversized (>1518) rejected.
  - Packet data flushed before submit (`dma_cache_wback_inv` on `skb->data`).
  - Descriptor flushes (pkthdr + mbuf) inside `tx_submit`; descriptor
    and mbuf pointers pool-bounds-validated (`tx_bad_pkthdr`/`tx_bad_mbuf`).
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
- No BQL today; listed as the one remaining bench-gated perf candidate
  (AUDIT ETH-S05).
- TX timeout: NAPI-quiesced full TX ring reset with SKB cleanup,
  re-init HW TX ring (F1).

## 9. PHY / Link

- Minimal PHY init sequence extracted from legacy driver, isolated in
  `rtl8196e_hw.c`.
- Link status read from port registers (PSRPx).
- `netif_carrier_on/off` updated on link change IRQ and poll timer.
- Link poll timer interval configurable via DT (`link-poll-ms`) or module
  param.
- MAC address change is refused while the interface is UP (F2): the
  NETIF table and the hashed L2 toCPU entry are reprogrammed from
  `dev_addr` only at `open()`.

## 10. Constants

| Constant                  | Value | Location          |
|---------------------------|------:|-------------------|
| `RTL8196E_TX_DESC`        |   128 | `rtl8196e_main.c` |
| `RTL8196E_RX_DESC`        |   128 | `rtl8196e_main.c` |
| `RTL8196E_RX_MBUF_DESC`   |   128 | `rtl8196e_main.c` |
| `RTL8196E_CLUSTER_SIZE`   |  1700 | `rtl8196e_main.c` (`buf_size` passed to ring) |
| `RTL8196E_TX_STOP_THRESH` |     4 | `rtl8196e_main.c` |
| `RTL8196E_TX_WAKE_THRESH` |    16 | `rtl8196e_main.c` |
| `rtl8196e_kick_threshold` |     4 | `rtl8196e_ring.c` (extern; runtime-tunable via the `kick_threshold` sysfs attribute, §13) |
| `RTL8196E_DRV_VERSION`    | "2.8" | `rtl8196e_main.c` |

## 11. Init sequence (in `rtl8196e_open()`)

1. `rtl8196e_hw_init()`: pinmux via syscon, switch clock cycle, MEMCR
   (0 then 0x7f), FULL_RST + delay, LED direct mode, RX queue mapping,
   L2 table clear, W1C pending IRQs.
2. Set RX rings (pkthdr + mbuf base addresses) and TX ring base address.
3. `rtl8196e_hw_init_phy()`: PHY reset + autoneg for the configured port.
4. `rtl8196e_hw_vlan_setup()`: VLAN table entry + PVIDs.
5. `rtl8196e_hw_netif_setup()`: NETIF table entry (MAC, VLAN, MTU, port mask).
6. `rtl8196e_hw_l2_setup()`: L2 forwarding mode, flood control, STP
   forwarding (+ optional `rtl8196e_force_trap` debug mode).
7. `rtl8196e_hw_l2_add_cpu_entry()`: toCPU L2 entry for driver MAC —
   on failure, trap-to-CPU fallback and skip to step 9.
8. `rtl8196e_hw_l2_add_bcast_entry()` + `rtl8196e_hw_l2_check_cpu_entry()`
   readback verify — trap fallback on verify failure.
9. `rtl8196e_hw_start()`: CPUICR (`TXCMD | RXCMD | BUSBURST_32WORDS |
   MBUF_2048BYTES | EXCLUDE_CRC`), TRXRDY.
10. `napi_enable()`.
11. `rtl8196e_hw_enable_irqs()`: CPUIIMR (`RX_DONE_IE_ALL | LINK_CHANGE_IE
    | PKTHDR_DESC_RUNOUT_IE_ALL`).  TX completion is **not** unmasked
    here (software reclaim).
12. Start queue, check link, start link poll timer.

`stop()` runs the reverse direction and **resets both rings** so the
next `open()` starts from a canonical descriptor state (ETH-002).
Step 1 redoes one-time SoC state on every open — hoisting it to probe
is tracked as AUDIT ETH-S03 (with ETHDRV-007).

## 12. Module parameters

All exposed under `/sys/module/rtl8196e_eth/parameters/` once the
driver is loaded.  All read/write at runtime (mode 0644, root-only
debug knobs — ETHDRV-005).

| Parameter                | Type          | Default               | Purpose                                                  |
|--------------------------|---------------|----------------------:|----------------------------------------------------------|
| `link_poll_ms`           | unsigned int  | 0 (disabled)          | Link poll interval in ms; 0 disables the poll timer      |
| `rtl8196e_debug`         | unsigned int  | 0                     | Extra debug logging (descriptor dumps via `dbg_timer`)   |
| `rtl8196e_force_trap`    | unsigned int  | 0                     | Force all unknown traffic to CPU (debug)                 |
| `rtl8196e_cpu_port_mask` | unsigned int  | `RTL8196E_CPU_PORT_MASK` (0x20) | CPU port mask for VLAN / L2                |

`link_poll_ms` and `rtl8196e_cpu_port_mask` are consumed at `open()`
time only; a runtime write takes effect on the next down/up cycle.

## 13. Sysfs attributes (under `/sys/class/net/eth0/`)

| Attribute        | Mode | Purpose                                                                |
|------------------|------|------------------------------------------------------------------------|
| `led_mode`       | RW   | Front-panel LAN LED mode: `bright` / `dim` / `off` (drives LEDCREG/DIRECTLCR — the LED is ASIC-hardwired, GPIO has no effect) |
| `kick_threshold` | RW   | TX kick coalescing factor, range 1..64 (1 disables coalescing); mirrors `rtl8196e_kick_threshold`, sweepable under live traffic |

## 14. Ethtool stats (`ethtool -S eth0`)

24 driver-private stats (`RTL8196E_ETHTOOL_STATS_COUNT`, returned by
`get_sset_count(ETH_SS_STATS)`), in three groups:

L2 / first-TX debug (original set):

- `rtl8196e_l2_check_ok` — successful L2 toCPU entry verifications
- `rtl8196e_l2_check_fail` — failed L2 toCPU entry verifications
- `rtl8196e_l2_check_last_result` — last L2 check return code
- `rtl8196e_tx_dbg_portmask` — port mask used for first TX packet
- `rtl8196e_tx_dbg_vid` — VLAN ID used for first TX packet
- `rtl8196e_tx_dbg_len` — length of first TX packet
- `rtl8196e_tx_dbg_submit` — whether first TX submit succeeded

(The four `tx_dbg_*` slots are bring-up scaffolding; their retirement
is tracked as AUDIT ETH-S02.)

TX kick coalescing (added with Track A, v3.4.1):

- `rtl8196e_tx_kicks_total` / `_cold` / `_threshold` / `_drain` —
  TXFD pulses, split by trigger (cold-start, threshold, NAPI drain)

Ring anomaly counters (added with the driver 2.6 validators — must
stay 0 in nominal flow):

- `rtl8196e_rx_wild_pkthdr`, `rtl8196e_rx_wild_mbuf` — descriptor
  pointers outside their pool
- `rtl8196e_rx_bad_len`, `rtl8196e_rx_no_skb`, `rtl8196e_rx_alloc_fail`,
  `rtl8196e_rx_rearm_badidx`, `rtl8196e_rx_mbuf_no_shadow` — RX drop
  / rearm anomalies
- `rtl8196e_tx_bad_args`, `rtl8196e_tx_bad_len`, `rtl8196e_tx_ring_full`,
  `rtl8196e_tx_reclaim_no_skb`, `rtl8196e_tx_bad_pkthdr`,
  `rtl8196e_tx_bad_mbuf` — TX submit / reclaim anomalies

## 15. Verification

Current baselines (6.18 head, gcc 15.2 toolchain — see
`32-Kernel/CLAUDE.md` and `PERFORMANCE.md` for the per-release
history):

- TCP RX (host → gateway): **~94 Mbit/s** (line-rate), retrans ~0
- TCP TX (gateway → host): **~73 Mbit/s**, retrans ~0
- Regression threshold: >1 Mbit/s sustained delta or non-zero TCP
  retransmission rate (`scripts/test_rtl8196e_eth.sh`; stop OTBR first)

Historical reference (v3.4.1, kernel 6.18.24, where the §8 kick
coalescing was introduced): TCP RX 93.5 / TCP TX 70.1 / UDP TX 100M
37.9 / UDP storm 64-byte 1.87 Mbit/s (iperf 2.x, 5 × 60 s medians,
direct cable).

Functional checks:

- `ping` IPv4 / IPv6.
- Stable SSH session.
- 0 driver TX/RX errors, 0 TCP retransmissions on the SoC side over a
  300 s stress.
- `ethtool -S eth0` shows the driver-private stats (see §14) with all
  anomaly counters at 0.
- No warnings in dmesg.
- `/proc/irq/<eth>/spurious` stays at 0 unhandled (F7/F14 gate).

See `PERFORMANCE.md` for the full per-phase TX path decomposition,
asymptote analysis, and the four orthogonal-levers tracks measured in
the v3.4.1 perf session.
