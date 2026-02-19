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

| Direction | CPU role     | Data origin                       |
|-----------|--------------|-----------------------------------|
| RX        | Consumer     | Hardware DMA → already in RAM     |
| TX        | **Producer** | CPU must **generate** the payload |

In the RX direction the iperf server reads passively from the socket; the
kernel and hardware have already done the heavy lifting. In the TX direction
the iperf client must actively write test data, the TCP stack must segment it,
and only then does the driver submit it to the hardware ring.

More precisely, TCP TX benefits from **kernel-side segmentation**: iperf calls
`write()` with a large buffer (tens of KB), and the kernel's TCP stack splits
it into MSS-sized segments internally.  This amortises the per-segment overhead
across many packets per syscall.  On a 250 MHz in-order MIPS core, this
difference in data-generation efficiency is the single largest contributor to
the TX/RX gap (see the UDP experiment below for evidence).

---

### Factor 2 — Cache coherency: write-back-invalidate vs. invalidate-only

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
Every line must first be **written out to DRAM** (because the application just
dirtied it), then invalidated.  That is ~47 DRAM writes + ~47 invalidations
per packet.

**RX path** — data was DMA'd directly into DRAM by hardware, bypassing the
CPU cache entirely:

```c
/* After hardware delivers the packet: */
dma_cache_inv(skb->data, len);   /* invalidate only — no DRAM write */
dma_cache_inv(ph, sizeof(*ph));
dma_cache_inv(mb, sizeof(*mb));
```

The cache lines are either cold (not present) or stale; either way,
invalidation requires **no DRAM write**.

**Rough cycle estimate per 1500-byte packet:**

| Operation                | TX                                  | RX                        |
|--------------------------|-------------------------------------|---------------------------|
| Data cache op            | ~47 × (write + inv) ≈ 300 cycles    | ~47 × inv ≈ 50 cycles     |
| Descriptor cache ops     | ~2 × (write + inv) ≈ 12 cycles      | ~2 × inv ≈ 4 cycles       |
| **Total cache overhead** | **~312 cycles (~1.25 µs)**          | **~54 cycles (~0.22 µs)** |

---

### Factor 3 — TCP software checksum (TX only)

The RTL8196E switch verifies IP/TCP checksums on received frames in hardware.
The driver signals this to the kernel:

```c
/* RX: hardware already verified — kernel skips re-check */
skb->ip_summed = CHECKSUM_UNNECESSARY;
```

For TX the driver declares no checksum offload capability
(`NETIF_F_HW_CSUM` is not set), so the kernel computes the TCP checksum in
software over every segment (~1460 bytes each).  This is a real but secondary
cost; the UDP experiment below shows it is not the dominant factor.

---

### Summary: cumulative CPU budget per packet

```
TX per-packet CPU cost:
  data generation + segmentation (kernel TCP path)  significant — dominant factor
  dma_cache_wback_inv on data (~1500 bytes)          ~300 cycles
  descriptor flushes                                 ~12 cycles
  TCP software checksum (~1460 bytes)                secondary
  ring submit + TXFD kick                            small

RX per-packet CPU cost:
  dma_cache_inv on data (~1500 bytes)                ~50 cycles
  descriptor invalidations                           ~4 cycles
  stack delivery to socket buffer                    small
  application read (passive)                         small
```

The TX path carries a fundamentally heavier per-packet CPU burden. The ~2:1
throughput ratio is the direct consequence.

---

### Hardware is not the bottleneck

100BASE-TX is full-duplex: both RX and TX channels are physically independent
and each capable of 100 Mbps simultaneously.  The fact that RX reaches 91 Mbps
proves the DMA engine, the switch fabric, and the ring management all function
correctly in both directions.  A hardware bottleneck would suppress RX as well.

---

## UDP experiment: testing the checksum hypothesis

To isolate the contribution of the TCP checksum, a UDP TX test was run
(gateway → host, `iperf -u -b 100M -c <host> -t 10`, 0% packet loss).

**Result: UDP TX = 25.4 Mbps — lower than TCP TX (44 Mbps).**

```
[  1] 0.00-10.00 sec  30.3 MBytes  25.4 Mbits/sec   0.000 ms  0/21597 (0%)
```

This result **rules out TCP checksum as the primary bottleneck**.  If checksum
computation were the dominant cost, removing it (UDP) should have increased
throughput.  Instead, it decreased by ~42%.

### Why is iperf UDP TX slower than iperf TCP TX on this platform?

The difference lies in how iperf generates and submits packets in each mode:

| Mode       | iperf send pattern                          | Syscalls / packet       |
|------------|---------------------------------------------|-------------------------|
| **TCP TX** | `write(fd, buf, 128 KB)` — large buffer     | ~1 syscall per ~90 pkts |
| **UDP TX** | `sendto(fd, buf, 1470)` — one datagram      | **1 syscall per packet** |

With TCP, iperf pushes large chunks into the socket buffer and the kernel's
TCP stack handles segmentation internally.  The amortised syscall cost per
packet is negligible.

With UDP, iperf must call `sendto()` once per 1470-byte datagram.  On a
250 MHz Lexra MIPS without a VDSO fast path, each syscall involves a full
kernel entry/exit.  Additionally, iperf UDP calls `gettimeofday()` in a tight
loop to implement its rate limiter — another potential source of overhead on
this platform.

At the observed rate of ~2160 datagrams/s, the per-packet overhead of the UDP
send loop is sufficient to cap throughput well below what TCP achieves through
its more efficient batched segmentation path.

### What the UDP result actually tells us

The UDP experiment confirms that **the bottleneck is in the data-generation
and submission path, not in the TCP protocol machinery**.  TCP is actually
*more efficient* than UDP here because it pushes the segmentation work into
the kernel, minimising the number of userspace-to-kernel transitions per byte
transmitted.

This is consistent with Factor 1 above: on a slow embedded CPU, the cost
of producing data (context switches, syscall overhead, buffer management)
dominates over protocol-level costs like checksum computation.

---

## How to confirm CPU saturation experimentally

Run `vmstat 1` on the gateway during each iperf test and observe the `id`
(idle) column:

```
# during RX test (host → gw)
iperf -s &
vmstat 1 15     # expect idle > 0%

# during TCP TX test (gw → host)
iperf -c <host_ip> -t 10 &
vmstat 1 10     # expect idle ≈ 0%
```

If the CPU is near 100% busy during TX and has measurable idle time during RX,
the conclusion is confirmed.

---

## Can the gap be closed?

The TX/RX asymmetry is inherent to this architecture.  The only meaningful
levers are:

| Approach | Expected gain | Complexity |
|----------|--------------|------------|
| Hardware TX checksum offload | Small (secondary factor) | Requires vendor docs |
| `sendfile()` / zero-copy TX path | Moderate | Requires application support |
| Page-aligned TX buffers (reduce cache-line splits) | Small | Medium |
| Larger TCP socket buffers | Small (already near max) | Low |
| CPU clock increase | Linear | Not possible (SoC fixed) |

The driver already applies all software-level TX optimizations that are safe
on this platform (no spinlock, no BQL, no TX timer, `napi_consume_skb`,
`likely`/`unlikely` hints).  The remaining headroom is CPU-architecture
constrained.

---

*TCP baseline measured on: Ubuntu 22.04 host, gateway at 192.168.1.126,
iperf 2.x, 10s test, same-day same-host conditions.*
*UDP TX test: `iperf -u -b 100M -c 192.168.1.200 -t 10` from gateway,
0% packet loss, 10s, 21597 datagrams.*
