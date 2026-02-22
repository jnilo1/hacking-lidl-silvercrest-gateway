# AGENTS.md - rtl8196e-eth

## Mission
Implement a clean, minimal, high-performance RTL8196E Ethernet driver for Linux 5.10.
Single physical port, zero-copy RX/TX, DT compatible with existing `ethernet` node.

## Hard constraints
- Target chip: RTL8196E only.
- Zero-copy RX/TX (no payload copy).
- Use KSEG1 addresses for DMA (0xAxxxxxxx) via helper.
- Use `dma_cache_wback_inv()` for TX and `dma_cache_inv()` for descriptor reads.
- Two RX rings: pkthdr + mbuf.
- Keep pool private; relies on existing `skb_free_head()` patch.
- IRQ routing via SoC interrupt controller (GIMR bit 15).
- Avoid BIST; use reset + MEMCR sequence.

## Scope
- One netdev only (from `interface@0`).
- Parse DT properties: `ifname`, `local-mac-address`, `vlan-id`, `member-ports`, `untag-ports`, `mtu`.
- Ignore extra interface nodes with a warning.

## Non-goals
- QoS, netfilter offload, L3/L4 acceleration.
- Scatter-gather (NETIF_F_SG off).
- XDP / page_pool.

## Performance rules
- Single TX cache flush per packet.
- TX reclaim must not depend on RX traffic.
- Use TXFD pulse only when ring was empty.

## Safety
- Keep hacks isolated in `rtl8196e_hw.*` with comments.
- Do not modify `rtl819x` sources unless explicitly requested.

## Tests to run (when possible)
- `iperf3` TX/RX (target > 80 Mbps, low TX/RX gap).
- `ethtool -S` (pool/ring stats).
- `ping` IPv4/IPv6 + SSH stability.
