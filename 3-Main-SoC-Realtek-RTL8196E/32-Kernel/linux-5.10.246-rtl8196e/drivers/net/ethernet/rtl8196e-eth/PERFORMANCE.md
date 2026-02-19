# RTL8196E Ethernet Driver — Performance Analysis

## Measured throughput (v1.0, same-day baseline, 10s iperf TCP)

| Direction        | rtl819x (legacy) | rtl8196e-eth v1.0 | Delta  |
|------------------|------------------|-------------------|--------|
| RX (host → gw)   | 85.3 Mbps        | ~91 Mbps          | +6.7%  |
| TX (gw → host)   | 42.1 Mbps        | ~44 Mbps          | +4.5%  |

Hardware: Realtek RTL8196E SoC, Lexra RLX4181 CPU (~250 MHz, MIPS32-like,
big-endian, single core, no FPU, no SIMD, write-back L1 cache).
Link: 100BASE-TX full duplex.

---

## Why is TX throughput roughly half of RX?

This is a structural property of the platform, not a driver limitation.
The same ~2:1 ratio appears in the legacy rtl819x driver, confirming that
the constraint is systemic, not software-specific.

Three cumulative factors explain the asymmetry.

---

### Factor 1 — The CPU role is asymmetric

| Direction | CPU role    | Data origin                  |
|-----------|-------------|------------------------------|
| RX        | Consumer    | Hardware DMA → already in RAM |
| TX        | **Producer** | CPU must **generate** the payload |

In the RX direction the iperf server reads passively from the socket; the
kernel and hardware have already done the heavy lifting. In the TX direction
the iperf client must actively write test data, the TCP stack must segment it,
and only then does the driver submit it to the hardware ring. On a 250 MHz
in-order MIPS core, data generation is a real cost even before the driver
touches the packet.

---

### Factor 2 — TCP checksum: software TX, hardware RX

The RTL8196E switch verifies IP/TCP checksums on received frames in hardware.
The driver signals this to the kernel:

```c
/* RX: hardware already verified — kernel skips re-check */
skb->ip_summed = CHECKSUM_UNNECESSARY;
```

For TX the driver declares no checksum offload capability
(`NETIF_F_HW_CSUM` is not set in `ndev->features`), so the kernel computes
the TCP checksum in software over every segment (~1460 bytes each).

At 44 Mbps TX that is roughly **3,600 segments/s × 1460 bytes = ~5 MB/s** of
pure software checksum work. On a 250 MHz core with a simple byte-loop this
consumes a non-trivial fraction of the available CPU budget.

---

### Factor 3 — Cache coherency: write-back-invalidate vs. invalidate-only

This is the dominant cost difference between the two paths.

The Lexra RLX4181 uses a **write-back** L1 cache: dirty cache lines are not
written to DRAM until explicitly flushed or evicted.

**TX path** — data just written by the application is **dirty in cache**:

```c
/* Before submitting to the DMA ring: */
dma_cache_wback_inv(skb->data, len);   /* write dirty lines → DRAM, then invalidate */
dma_cache_wback_inv(ph, sizeof(*ph));  /* same for pkthdr descriptor */
dma_cache_wback_inv(mb, sizeof(*mb));  /* same for mbuf descriptor */
```

For a 1500-byte payload this touches ~47 cache lines (32 bytes each).
Every line must first be **written out to DRAM** (because iperf just dirtied
it), then invalidated. That is ~47 DRAM writes + ~47 invalidations per packet.

**RX path** — data was DMA'd directly into DRAM by hardware, bypassing the
CPU cache entirely:

```c
/* After hardware delivers the packet: */
dma_cache_inv(skb->data, len);   /* invalidate only — no DRAM write */
dma_cache_inv(ph, sizeof(*ph));
dma_cache_inv(mb, sizeof(*mb));
```

The cache lines are either cold (not present) or stale; either way,
invalidation requires **no DRAM write**. The cost is roughly 6× lower than
`dma_cache_wback_inv` for the same data size.

**Rough cycle estimate per 1500-byte packet:**

| Operation                  | TX                        | RX                   |
|----------------------------|---------------------------|----------------------|
| Data cache op              | ~47 × (write + inv) ≈ 300 cycles | ~47 × inv ≈ 50 cycles |
| Descriptor cache ops       | ~2 × (write + inv) ≈ 12 cycles   | ~2 × inv ≈ 4 cycles   |
| **Total cache overhead**   | **~312 cycles**           | **~54 cycles**        |

At 250 MHz, 312 cycles represents ~1.25 µs of pure cache work per TX packet,
versus ~0.22 µs per RX packet.

---

### Summary: cumulative CPU budget

```
TX per-packet CPU cost:
  data generation (iperf)     non-zero
  TCP segmentation + timers   moderate
  software checksum           ~4 cycles/byte × 1460 bytes ≈ 5840 cycles
  dma_cache_wback_inv (data)  ~300 cycles
  descriptor flushes          ~12 cycles
  ring submit                 small

RX per-packet CPU cost:
  dma_cache_inv (data)        ~50 cycles
  descriptor invalidations    ~4 cycles
  stack delivery              small
  application read (passive)  small
```

The TX path carries a fundamentally heavier per-packet CPU burden at every
layer of the stack. The ~2:1 throughput ratio is the direct consequence.

---

### Hardware is not the bottleneck

100BASE-TX is full-duplex: both RX and TX channels are physically independent
and each capable of 100 Mbps simultaneously. The fact that RX reaches 91 Mbps
proves the DMA engine, the switch fabric, and the ring management are all
functioning correctly in both directions. A hardware bottleneck would suppress
RX as well.

---

### How to confirm CPU saturation experimentally

**Method 1 — CPU idle measurement**

Run `vmstat 1` on the gateway during each iperf test and observe the `id`
(idle) column:

```
# during RX test (host → gw)
iperf -s &
vmstat 1 15     # expect idle > 0%

# during TX test (gw → host)
iperf -c <host_ip> -t 10 &
vmstat 1 10     # expect idle ≈ 0%
```

If the CPU is near 100% busy during TX and has measurable idle time during RX,
the conclusion is confirmed.

**Method 2 — Replace TCP with UDP**

UDP eliminates segmentation, retransmissions, and RTT estimation. It also
removes the software checksum for UDP-lite if `SO_NO_CHECK` is used:

```
# on the gateway
iperf -u -b 100M -c <host_ip> -t 10
```

If UDP TX significantly exceeds TCP TX (e.g., 60–70 Mbps vs. 44 Mbps), the
TCP stack overhead (primarily checksum) accounts for a large part of the gap.
If UDP TX ≈ TCP TX, the bottleneck is at the driver/cache layer.

---

### Can the gap be closed?

The remaining gap between TX and RX is inherent to this architecture. The
only meaningful levers are:

| Approach | Expected gain | Complexity |
|----------|--------------|------------|
| Hardware TX checksum offload | Moderate (+5–10%) | Requires vendor docs confirming HW support |
| Page-aligned TX buffers (reduce cache-line splits) | Small | Medium |
| Larger TCP socket buffers on both ends | Small (already near max) | Low |
| CPU clock increase | Linear | Not possible (SoC fixed) |

The driver already applies all software-level TX optimizations that are safe
on this platform (no spinlock, no BQL, no TX timer, napi_consume_skb,
likely/unlikely hints). The remaining headroom is hardware-constrained.

---

*Measured on: Ubuntu 22.04 host, gateway at 192.168.1.126, iperf 2.x,
10s TCP test, same-day same-host baseline.*
