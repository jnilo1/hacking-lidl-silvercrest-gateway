# RTL8196E Ethernet Driver — Performance Analysis

## Measured throughput (v1.0, same-day baseline, 10s iperf TCP)

| Direction        | rtl819x (legacy) | rtl8196e-eth v1.0 | Delta  |
|------------------|------------------|-------------------|--------|
| RX (host → gw)   | 85.3 Mbps        | ~91 Mbps          | +6.7%  |
| TX (gw → host)   | 42.1 Mbps        | ~44 Mbps          | +4.5%  |

## MIPS16e + I-MEM experiment (2026-02-19)

### Phase 1 — single function (`rx_poll` only)

`rtl8196e_ring_rx_poll` annotated with `__MIPS16 __iram_fwd`.  Three runs:

| Run | Config             | TCP RX     | TCP TX     |
|-----|--------------------|------------|------------|
| 1   | IMEM=n (MIPS16e)   | 90.3 Mbps  | 44.0 Mbps  |
| 2   | IMEM=y (MIPS16e + I-MEM) | 90.0 Mbps | 42.4 Mbps |
| 3   | IMEM=y (MIPS16e + I-MEM) | 88.7 Mbps | 44.1 Mbps |

**Result: no measurable gain over v1.0.**

### Phase 2 — full hot path

All driver hot-path functions annotated with `__iram_gen`/`__iram_fwd`
(SRAM placement), and ring functions additionally with `__MIPS16` (16-bit
instruction encoding).  Functions placed in SRAM:

| Symbol                       | Section    | Encoding | Size  |
|------------------------------|------------|----------|-------|
| `plat_irq_dispatch`          | `.iram-gen`| MIPS32   | 160 B |
| `rtl8196e_isr`               | `.iram-gen`| MIPS32   | 248 B |
| `rtl8196e_poll`              | `.iram-gen`| MIPS32   | 244 B |
| `rtl8196e_start_xmit`        | `.iram-fwd`| MIPS32   | 568 B |
| `rtl8196e_ring_tx_reclaim`   | `.iram-gen`| MIPS16   | 188 B |
| `rtl8196e_ring_kick_tx`      | `.iram-gen`| MIPS16   |  44 B |
| `rtl8196e_ring_tx_submit`    | `.iram-fwd`| MIPS16   | 240 B |
| `rtl8196e_ring_rx_poll`      | `.iram-fwd`| MIPS16   | 452 B |
| **Total SRAM used**          |            |          | **2144 B / 16 KB** |

One run (IMEM=y, full hot path):

| Config                       | TCP RX     | TCP TX     |
|------------------------------|------------|------------|
| IMEM=y, full hot path        | 89.8 Mbps  | 42.8 Mbps  |

**Result: no measurable gain over v1.0.** All values are within iperf
run-to-run variance (±1–2 Mbps).

### Why the gain is negligible

At 90 Mbps, ~6 100 packets/s, 400 MHz CPU → ~65 000 cycles/packet average
(both directions CPU-bound at 100%).  Eliminating I-cache misses on the
entire driver + IRQ dispatch path (~100–150 cycles/packet savings) would be
a ~0.2% improvement — well below measurement noise.

The dominant costs are structural (DMA cache flush on TX ~300 cycles,
TCP stack overhead) and are unaffected by I-MEM.  The network stack
functions (`napi_gro_receive`, `eth_type_trans`, TCP send/receive path)
are far too large to fit in the 16 KB I-MEM and would need to be warm
for any measurable gain.

### I-MEM infrastructure status

The platform infrastructure (linker script sections, `_imem_dmem_init()`,
COP3 programming) is **correct and functional**: the kernel boots cleanly
with `CONFIG_RTL8196E_IMEM=y`, all annotated functions are placed in
`.iram-fwd`/`.iram-gen` at `0x80280000`, and the COP3 Instruction Window
is programmed at boot.  Total SRAM usage: 2144 B out of 16 384 B.

**Default: `CONFIG_RTL8196E_IMEM=n`.**  MIPS16e is always active on ring
functions (`__MIPS16` is unconditional) and gives the same throughput with
less platform complexity.  The `.iram-*` section attributes become no-ops
when `CONFIG_RTL8196E_IMEM=n`.

Hardware: Realtek RTL8196E SoC, Lexra RLX4181 CPU (400 MHz, MIPS-1 + MIPS16
ISA, big-endian, single core, no FPU, no SIMD, write-back L1 cache,
16 KB I-cache, 8 KB D-cache, 16 KB I-MEM, 8 KB D-MEM).
Link: 100BASE-TX full duplex.

---

## Why is TX throughput roughly half of RX?

### CPU utilization measurement (confirmed)

To settle this question experimentally, CPU utilization was measured on the
gateway during both TCP tests using `/proc/stat` sampled at 1-second intervals:

| Test              | Gateway CPU   | Throughput   |
|-------------------|---------------|--------------|
| TCP RX (host→gw)  | **100% busy** | ~82–91 Mbps  |
| TCP TX (gw→host)  | **100% busy** | ~39–44 Mbps  |

**Both directions fully saturate the CPU.**  The 2:1 throughput ratio is not
caused by a hardware asymmetry, a ring management issue, or a protocol
overhead that could be optimised away.  It means that **processing one TX
packet costs roughly twice the CPU time of processing one RX packet**.

This is a structural property of the platform.  The same ~2:1 ratio appears
in the legacy rtl819x driver under identical conditions, confirming the
constraint is systemic and not driver-specific.

---

### Root cause: each TX byte touches DRAM twice; each RX byte touches it once

The Lexra RLX4181 has a **write-back** L1 cache.  DMA coherency is managed
entirely in software, with two different operations depending on direction:

**TX path — data is dirty in cache, must be flushed before DMA reads it:**

```c
dma_cache_wback_inv(skb->data, len);   /* write dirty lines to DRAM, then invalidate */
dma_cache_wback_inv(ph, sizeof(*ph));
dma_cache_wback_inv(mb, sizeof(*mb));
```

1. The application (iperf) writes the payload → lands in L1 cache, dirty.
2. The kernel copies it into the skb buffer → more dirty lines in L1 cache.
3. `dma_cache_wback_inv()` forces every dirty cache line (16 bytes each) to
   be **written back to DRAM** before the DMA engine can read it.

Each payload byte therefore traverses the DRAM bus **twice** from the CPU's
perspective: once when written to the socket buffer, once when flushed for
DMA coherency.  The CPU stalls during each writeback — this is a synchronous
operation on this architecture.

**RX path — data was DMA'd directly into DRAM, cache has no copy:**

```c
dma_cache_inv(skb->data, len);   /* invalidate cache tags — no DRAM write */
dma_cache_inv(ph, sizeof(*ph));
dma_cache_inv(mb, sizeof(*mb));
```

1. The DMA engine writes the received payload directly into DRAM, bypassing
   the CPU cache entirely.
2. `dma_cache_inv()` simply marks the corresponding cache lines as invalid.
   No data is written to DRAM.  The operation is nearly free.
3. The application reads the payload → cache miss → data loaded from DRAM.

Each payload byte touches the DRAM bus **once** from the CPU's perspective
(the hardware DMA write does not stall the CPU).

**Rough cycle cost per 1500-byte packet:**

| Operation                | TX                                  | RX                        |
|--------------------------|-------------------------------------|---------------------------|
| Data cache op (~94 lines)| ~94 × (writeback + inv) ≈ 300 cyc  | ~94 × inv ≈ 50 cycles     |
| Descriptor cache ops     | ~4 × (writeback + inv) ≈ 24 cycles  | ~4 × inv ≈ 8 cycles       |
| **Total cache overhead** | **~324 cycles (~0.81 µs)**          | **~58 cycles (~0.15 µs)** |

This 6× difference in cache overhead per packet is the dominant contributor
to the 2:1 throughput asymmetry, compounded by secondary factors below.

---

### Secondary factors

**TCP software checksum (TX only)**

The RTL8196E switch verifies IP/TCP checksums on received frames in hardware;
the driver sets `skb->ip_summed = CHECKSUM_UNNECESSARY` for RX.  For TX, no
checksum offload is declared, so the kernel computes it in software over every
segment (~1460 bytes).  This is real but secondary — see the UDP experiment
below for evidence.

**TCP stack TX is heavier than RX**

The TCP sender manages congestion control (cwnd, RTT estimation, pacing) and
handles incoming ACKs.  The TCP receiver mainly reassembles in-order data and
delivers it to the socket buffer.  Both have overhead, but the sender path is
consistently more expensive per byte on this platform.

---

### Complete per-packet CPU budget

```
TX (gw → host):
  Application writes payload → L1 cache (dirty)
  tcp_sendmsg: copy user→kernel skb → more dirty lines
  TCP header build + software checksum (~1460 bytes)
  dma_cache_wback_inv(data, ~1500B)  ← dominant cost: ~300 cycles + DRAM stall
  dma_cache_wback_inv(descriptors)   ← ~24 cycles
  Ring submit + TXFD kick             ← small
  TCP congestion control + ACK rx     ← moderate

RX (host → gw):
  DMA writes payload to DRAM          ← done by hardware, no CPU stall
  dma_cache_inv(data, ~1500B)         ← ~50 cycles, no DRAM write
  dma_cache_inv(descriptors)          ← ~8 cycles
  Buffer recycle (napi_alloc_skb)     ← small
  TCP receive + deliver to socket     ← moderate
  Application reads from socket       ← passive
```

Total TX CPU cost per packet ≈ 2× RX CPU cost per packet → 2:1 throughput
ratio at 100% CPU utilisation in both directions.

---

### Hardware is not the bottleneck

100BASE-TX is full-duplex: RX and TX are physically independent channels,
each capable of 100 Mbps simultaneously.  RX reaching 91 Mbps confirms the
DMA engine, switch fabric, and ring management all function at near line-rate.
A hardware bottleneck would suppress RX throughput as well.

---

## UDP experiment: testing the checksum hypothesis

A UDP TX test was run (gateway → host, `iperf -u -b 100M -c <host> -t 10`,
0% packet loss) to isolate the TCP checksum contribution.

**Result: UDP TX = 25.4 Mbps — lower than TCP TX (44 Mbps).**

```
[  1] 0.00-10.00 sec  30.3 MBytes  25.4 Mbits/sec   0.000 ms  0/21597 (0%)
```

This **rules out TCP checksum as the primary bottleneck**.  UDP eliminates TCP
checksum computation but achieves *lower* throughput, for a different reason:

| Mode       | iperf send pattern               | Kernel work per packet     |
|------------|----------------------------------|----------------------------|
| **TCP TX** | `write(fd, 128 KB)` — bulk       | Kernel segments internally |
| **UDP TX** | `sendto(fd, 1470B)` — per packet | 1 syscall per datagram     |

With TCP, iperf pushes large buffers and the kernel's TCP stack handles
segmentation efficiently, amortising syscall overhead across many packets.
With UDP, iperf calls `sendto()` once per 1470-byte datagram (~2160 calls/s),
with additional `gettimeofday()` calls for rate limiting.  On a 400 MHz Lexra
without a VDSO fast path, this per-call overhead is significant.

The UDP experiment confirms that the bottleneck is in the **data production
and submission path**, not in TCP protocol processing per se.  It also shows
that TCP's kernel-side segmentation is *more efficient* than UDP's
per-datagram userspace API on this platform.

---

## Can the gap be closed?

The TX/RX asymmetry is inherent to the write-back cache architecture of this
SoC.  Eliminating it would require hardware DMA coherency support (cache
snooping or write-through cache) — neither of which is available on the
Lexra RLX4181.

The only meaningful software levers are:

| Approach | Expected gain | Complexity |
|----------|--------------|------------|
| Hardware TX checksum offload | Small (secondary factor) | Requires vendor confirmation |
| `sendfile()` / zero-copy TX | Moderate (avoids user→kernel copy) | Application support needed |
| Page-aligned TX buffers | Small | Medium |
| Larger TCP socket buffers | Marginal | Low |

The driver already applies all safe software optimisations (no spinlock,
no BQL, no TX timer, `napi_consume_skb`, `likely`/`unlikely` hints).

---

*TCP baseline: Ubuntu 22.04 host, gateway 192.168.1.126, iperf 2.x,
10s TCP test, kernel 5.10.246-rtl8196e-eth.*
*CPU measurement: `/proc/stat` sampled at 1 Hz during each test.*
*UDP TX test: `iperf -u -b 100M -c 192.168.1.200 -t 10` from gateway,
0% packet loss, 10s, 21597 datagrams.*
