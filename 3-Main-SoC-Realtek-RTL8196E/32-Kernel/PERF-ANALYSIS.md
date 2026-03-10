# RTL8196E Ethernet Driver — Performance Analysis

**Date:** 2026-03-10
**Kernel:** Linux 5.10.246-rtl8196e-eth
**Hardware:** RTL8196E SoC, 200 MHz Lexra RLX4181 (single-core MIPS), 32 MB SDRAM, 100 Mbps MAC
**Driver:** rtl8196e-eth v2.0

## 1. Measurement Method

### 1.1 Kernel instrumentation (development only)

During development, we added temporary `ktime_get_ns()` probes at key points in the
driver hot path, exposed via `/proc/net/rtl8196e_perf`. **This instrumentation has been
removed from the production driver v2.0** — the committed code contains no probes, no
perf counters, and no /proc entry. All measurements in this document were taken with
the instrumented build and are representative of the driver's behavior, though the
production driver runs slightly faster due to the absence of probe overhead.

**TX path (`rtl8196e_start_xmit`)** — 5 timestamps per packet:
- `t0`: function entry
- `t1`→`t2`: `dma_cache_wback_inv()` on packet data (→ `tx_cache_flush_ns`)
- `t2`→`t3`: `rtl8196e_ring_tx_submit()` including descriptor cache flush (→ `tx_submit_ns`)
- `t0`→end: total time including kick_tx, stats update, free count (→ `tx_total_ns`)

**RX path (`rtl8196e_ring_rx_poll`)** — 4 timestamps per packet:
- `dma_cache_inv()` on packet data (→ `rx_cache_inv_ns`)
- `napi_alloc_skb()` (→ `rx_alloc_ns`)
- `eth_type_trans()` + `napi_gro_receive()` (→ `rx_deliver_ns`)
- Descriptor rearm + 3× `dma_cache_wback_inv()` (→ `rx_rearm_ns`)

**NAPI poll (`rtl8196e_poll`):**
- Full poll cycle time (→ `rx_poll_ns`)
- TX reclaim time within poll (→ `tx_reclaim_ns`)

**IRQ (`rtl8196e_isr`):**
- Total IRQ count and NAPI schedule count

Writing to `/proc/net/rtl8196e_perf` resets all counters to zero.

### 1.2 Instrumentation overhead caveat

Each `ktime_get_ns()` call reads the CP0 Count register through the kernel timekeeper
(seqlock + clocksource read + 64-bit multiply). On this 200 MHz MIPS core, each call
costs approximately 2-5 µs. With 5 calls per TX packet, the instrumentation adds
~10-25 µs overhead per packet. This is visible in the UDP TX results (see section 3).
**The production driver does not pay this cost.**

Since the core is single-threaded, **hardirqs can preempt `start_xmit`**. The measured
`tx_total_ns` therefore includes any IRQ handler time that fires during the function.
This is not a bug — it reveals real contention between TX submission and IRQ processing.

### 1.3 Test setup

All tests use `iperf` (v2) between the host PC (Ubuntu, 192.168.1.200, Gigabit NIC)
and the gateway (RTL8196E, 192.168.1.88, 100 Mbps). Duration: 15 seconds per test.
OTBR agent stopped during tests.

## 2. Baseline Results (TX completion IRQs enabled, rings 600/500)

These results were measured with the original driver configuration (v1.2):
TX/RX descriptor rings at 600/500/500 entries, TX_ALL_DONE interrupt enabled.

### 2.1 Summary

| Test    | iperf Mbps | Driver tx_mbps | Driver rx_mbps | tx_avg_ns | rx_avg_ns | pkts/poll | IRQs   |
|---------|------------|----------------|----------------|-----------|-----------|-----------|--------|
| tcp_rx  | 91.8       | 0              | 82             | 9,793     | 72,054    | 7         | 16,553 |
| tcp_tx  | 47.7       | 40             | 0              | 6,907     | 226,663   | 2         | 12,719 |
| udp_rx  | 2.6 (96% loss) | 0          | 59             | —         | 130,667   | 1         | 74,450 |
| udp_tx  | 28.6       | 23             | 0              | 46,880    | —         | 0         | 36,916 |

### 2.2 TCP RX — Host → Gateway (91.8 Mbps)

Near wire-speed. The per-packet RX breakdown (72 µs total):

| Phase                           | ns/pkt  | % of total |
|---------------------------------|---------|------------|
| `dma_cache_inv` (packet data)   | 1,286   | 1.8%       |
| `napi_alloc_skb` (new SKB)      | 10,971  | 15.2%      |
| `napi_gro_receive` (deliver)    | 19,191  | 26.6%      |
| Rearm (3× cache wback+inv)      | 2,055   | 2.9%       |
| Overhead (desc read, skb_put…)  | 38,551  | 53.5%      |
| **Total per packet**            | **72,054** | **100%** |

- 120,284 packets received, 16,553 NAPI polls → **7.3 pkts/poll** average batch size
- TX side: 4,882 ACK packets sent (one ACK per ~25 data packets — delayed ACKs working)
- The driver measures 82 Mbps; iperf reports 91.8 Mbps (difference = Ethernet + IP + TCP headers)

### 2.3 TCP TX — Gateway → Host (47.7 Mbps)

The TX per-packet breakdown (6.9 µs total):

| Phase                           | ns/pkt  | % of total |
|---------------------------------|---------|------------|
| `dma_cache_wback_inv` (pkt data)| 1,104   | 16.0%      |
| `ring_tx_submit` (desc flush)   | 2,612   | 37.8%      |
| kick_tx + stats + free_count    | 3,191   | 46.2%      |
| **Total start_xmit**           | **6,907** | **100%** |

- 62,195 TX packets in 18.5s = 3,353 pps
- tx_ring_full = 0, tx_queue_stopped = 0 → ring never saturated
- RX side: 30,564 ACK packets received, processing at 226 µs/pkt (high due to
  low batch size of 2 pkts/poll and IRQ overhead)
- **tx_reclaim_avg_ns = 59,149 ns** — expensive because each reclaim call
  processes ~4.9 packets (62,195 reclaimed / 12,719 calls)

### 2.4 UDP RX — Host → Gateway (96% packet loss)

The driver received 85,808 of 85,782 sent packets (essentially all of them).
However, iperf reports only 3,339 delivered to the application = **96% loss at
the socket layer**.

- **rx_pkts_per_poll = 1.15** — almost no batching
- **74,450 IRQs for 85,808 packets** — nearly one IRQ per packet
- rx_avg_per_pkt = 130 µs (vs 72 µs for TCP RX) — higher because of the 1:1
  IRQ-to-packet ratio (no amortization of IRQ/NAPI overhead)
- The UDP socket receive buffer overflows because the CPU spends all its time
  in interrupt/softirq handling and cannot schedule the iperf userspace process

### 2.5 UDP TX — Gateway → Host (28.6 Mbps)

Slowest test. The driver TX path itself is fast, but measured time is inflated:

| Phase                           | ns/pkt  | % of total |
|---------------------------------|---------|------------|
| `dma_cache_wback_inv` (pkt data)| 1,281   | 2.7%       |
| `ring_tx_submit` (desc flush)   | 2,525   | 5.4%       |
| **IRQ preemption + overhead**   | **43,074** | **91.9%** |
| **Total start_xmit (measured)** | **46,880** | **100%** |

The 43 µs "overhead" is explained by:
- **36,916 IRQs for 36,447 TX packets = 1.01 IRQ per packet** — every TX completion
  triggers an IRQ that preempts the ongoing `start_xmit` on this single-core CPU
- Each empty NAPI poll (checking descriptors + tx_reclaim) takes ~27 µs
- The IRQ fires *during* `start_xmit`, so our `t0`→`end` measurement captures it

## 3. Root Cause Analysis

### 3.1 Why TCP TX (48 Mbps) is half of TCP RX (92 Mbps)

TCP RX and TX are fundamentally asymmetric on this single-core CPU:

**TCP RX (92 Mbps) — the hardware does the pacing:**
- The sender (host PC) is regulated by TCP congestion control. It sends bursts,
  then waits for ACKs. This natural pacing lets the gateway's NAPI batch 7-8 packets
  per poll, amortizing the IRQ/NAPI overhead across multiple packets.
- The RX path is passive: packets arrive, the driver processes them. No contention
  between submission and completion — they happen in the same NAPI poll context.
- The CPU only needs to: receive packet → deliver to stack → send occasional ACK.

**TCP TX (48 Mbps) — the CPU fights itself:**
- The gateway must simultaneously *submit* new packets (in `start_xmit`, process
  context or softirq) and *reclaim* completed packets (in NAPI, softirq context).
- On a single-core CPU, these two tasks cannot run in parallel. Every TX completion
  IRQ preempts the ongoing `start_xmit`, adding ~27 µs of IRQ→NAPI→reclaim overhead.
- The TX path requires both directions: data packets out + ACK packets in. Each ACK
  triggers an RX IRQ, which schedules NAPI, which preempts any in-progress TX work.
- TX completion IRQs fire at a 1:1 ratio (one IRQ per completed packet). With
  12,719 IRQs at ~27 µs each = 343 ms/s = **34% CPU consumed by interrupt overhead**.
- The remaining 66% CPU must handle TCP stack processing, ACK reception, and
  actual packet submission — leaving only ~48 Mbps of effective throughput.

**The 2:1 asymmetry is therefore structural**, not a driver bug. It stems from:
1. No hardware interrupt coalescing (1 IRQ per TX completion)
2. Single-core CPU (no parallel TX submit + TX reclaim)
3. TX requires bidirectional processing (data + ACKs) unlike RX (data only + rare ACKs)

### 3.1b Effect of network topology on TX throughput

An interesting counter-intuitive result: **TCP TX through a router (57 Mbps) is higher
than TCP TX with a direct cable (44 Mbps)**, while TCP RX shows the opposite pattern
(45 Mbps through router vs 92 Mbps direct).

This confirms the ACK-driven IRQ contention model described above:

- **Direct cable** (sub-ms RTT): TCP ACKs return almost instantly. Each ACK triggers
  an RX IRQ that preempts the ongoing `start_xmit` on the single-core CPU. The high
  ACK frequency maximizes IRQ contention → worst-case TX throughput (44 Mbps).
  Conversely, RX benefits from the low latency — the sender's congestion window opens
  quickly → best-case RX throughput (92 Mbps).

- **Through a router** (higher RTT, store-and-forward buffering): The router smooths
  ACK timing by absorbing bursts in its packet buffer. ACKs arrive less frequently and
  in batches → fewer RX IRQs → less preemption of `start_xmit` → TX improves to 57 Mbps.
  Conversely, RX drops to 45 Mbps because the router's store-and-forward latency and
  buffer management throttle the incoming traffic.

The direct cable test is the correct benchmark: it reveals the worst-case TX performance
(maximum ACK-driven IRQ contention) and the best-case RX performance (no intermediate
buffering). All measurements in this document use direct cable.

### 3.2 Why UDP throughput is worse than TCP

**UDP RX (2.6 Mbps vs TCP RX 92 Mbps) — IRQ storm kills userspace:**

At 95 Mbps offered load, the sender floods packets with no flow control. The result:
- **74,450 IRQs for 85,808 packets** — nearly 1:1 ratio, no NAPI batching
- Each packet costs 130 µs (vs 72 µs for TCP RX) due to zero amortization
- 74,450 IRQs × 130 µs = **9.7 seconds of CPU time** in a 15-second test — the CPU
  is saturated in interrupt/softirq handling
- The userspace `iperf` process cannot be scheduled to drain the UDP socket buffer
- Socket receive buffer overflows → **96% packet loss at the application layer**
- The driver itself received all packets — the loss is entirely at the socket layer

TCP avoids this because the congestion window naturally throttles the sender to match
the receiver's processing capacity. With TCP, the sender pauses after each window,
giving the gateway time to batch-process packets via NAPI (7-8 per poll) and schedule
userspace to drain the socket buffer.

Without hardware interrupt coalescing, UDP RX at wire-speed is fundamentally impossible
on this 200 MHz single-core CPU. The maximum sustainable UDP RX rate is approximately
1/(130 µs) = 7,700 pps ≈ 90 Mbps at the driver level, but the CPU has no cycles left
for userspace — practical application throughput is limited to the rate at which the
kernel can context-switch to the receiving process between NAPI polls.

**UDP TX (28.6 Mbps vs TCP TX 48 Mbps) — worst-case IRQ preemption:**

UDP TX has the worst IRQ-to-packet ratio of all tests:
- **36,916 IRQs for 36,447 TX packets = 1.01 IRQs/packet** — every single TX
  completion generates an interrupt
- Unlike TCP TX (which has RX ACK traffic to trigger NAPI and batch TX reclaim),
  UDP TX has almost no RX traffic. NAPI is triggered exclusively by TX completion IRQs.
- Each IRQ preempts the ongoing `start_xmit` on the single-core CPU, injecting
  ~27 µs of latency directly into the TX submission path
- With TCP TX, ACK-driven NAPI polls batch ~4.9 TX reclaims per call. With UDP TX,
  there are no ACKs, so NAPI runs once per TX completion — zero batching benefit.

The throughput penalty compounds: slower TX submission → fewer packets in flight →
less batching opportunity → more per-packet IRQ overhead → even slower submission.

### 3.3 Lack of hardware interrupt coalescing — the root cause

The #1 performance limiter across all tests is **one IRQ per TX completion**. The
RTL8196E switch core has no interrupt coalescing registers — no delay timer, no packet
count threshold, no combined RX/TX coalescing. This was verified by scanning all
CPUICR (CPU Interface Control Register) and related register definitions.

On a single-core 200 MHz CPU, each IRQ cycle (hardirq → NAPI schedule → softirq →
poll → reclaim) costs ~27 µs even when no RX packets are pending. With 3,353 TX pps
(TCP TX), that's:

    3,353 × 27 µs = 90.5 ms/s = 9.1% CPU wasted on TX completion interrupts

For UDP TX at full rate, the interrupt overhead consumes the CPU faster than it can
submit new packets.

If the hardware supported coalescing (e.g., one IRQ per 16 completed packets), the
overhead would drop from 27 µs/pkt to ~1.7 µs/pkt — a potential **15× reduction** in
TX interrupt overhead.

### 3.4 RX throughput: already near optimal for TCP

TCP RX achieves 91.8 Mbps (near wire-speed) with 7.3 pkts/poll batching. The TCP
congestion window naturally regulates the sender to match our processing speed, which
enables effective NAPI batching.

The two largest RX costs are:
- `napi_alloc_skb`: 15.2% — SLAB allocation from NAPI cache, hard to optimize further
- `napi_gro_receive`: 26.6% — GRO + protocol stack delivery, fundamental cost

### 3.5 Cache flush overhead: negligible thanks to I-MEM

The `dma_cache_wback_inv` and `dma_cache_inv` operations cost only 1.1-1.3 µs per
packet — roughly 2% of the per-packet budget. The I-MEM optimization (placing
`rlx_flush_dcache_fast` and `rlx_flush_dcache_range` in on-chip SRAM) ensures these
run at zero wait-state. This is a solved problem.

## 4. Driver v2.0 Optimizations

### 4.1 TX IRQ mitigation

Since the hardware has no interrupt coalescing, we implemented a software mitigation:

1. **Disable `TX_ALL_DONE_IE` in CPUIIMR** — no more TX completion interrupts
2. **Reclaim TX descriptors in `start_xmit`** — unconditional call to
   `rtl8196e_ring_tx_reclaim()` on every packet submission. The function exits
   immediately when there is nothing to reclaim (`tx_cons == tx_prod`).
3. **Reclaim in NAPI poll** — unchanged, handles batch reclaim when RX traffic
   is present (e.g., TCP ACKs drive NAPI which reclaims TX in batch)

**Why conditional reclaim failed:** An initial attempt used a threshold: only reclaim
when `free_count < 64` (ring getting full). This preserved TCP TX throughput but
**completely broke UDP TX** (84 Kbps, down from 28.6 Mbps). Root cause: with a
600-entry TX ring and slow UDP TX rate, the ring never filled enough to trigger
reclaim. Completed SKBs were never freed, socket wmem filled up, and the kernel
throttled the sending process. Unconditional reclaim was required to break this
deadlock.

### 4.2 Descriptor ring size reduction

The original driver used large descriptor rings sized for wire-speed throughput:

| Parameter           | v1.2 (old) | v2.0 (new) | Savings |
|---------------------|------------|------------|---------|
| TX descriptors      | 600        | 128        |         |
| RX descriptors      | 500        | 128        |         |
| RX mbuf descriptors | 500        | 128        |         |
| TX stop threshold   | 16         | 4          |         |
| TX wake threshold   | 64         | 16         |         |
| **Estimated RAM**   | **~1.05 MB** | **~270 KB** | **~780 KB** |

On a 32 MB system, this frees ~780 KB of RAM (2.7% of total, 3.8% of free RAM),
which directly benefits OTBR (ot-br-posix uses ~4-5 MB resident).

The ring never saturated (`tx_ring_full = 0`, `tx_queue_stopped = 0`) in any test,
including wire-speed TCP RX at 92 Mbps. 128 entries provide ~18 NAPI polls of
backlog at 7 pkts/poll — more than sufficient.

### 4.3 Combined results (v2.0: TX IRQ mitigation + rings 128)

Measured with the instrumented build (wire-speed tests):

| Test    | v1.2 baseline | v2.0 final | Delta   |
|---------|---------------|------------|---------|
| tcp_rx  | 91.8 Mbps     | **91.8**   | 0%      |
| tcp_tx  | 47.7 Mbps     | **44.3**   | **-7.1%** |
| udp_rx  | 2.6 (96%)     | 2.6 (96%)  | ~same   |
| udp_tx  | 28.6 Mbps     | **36.5**   | **+28%** |

The TCP TX regression (-7.1%, from -4.8% TX IRQ + -2.5% smaller rings) is acceptable
given the +28% UDP TX improvement and ~780 KB RAM savings.

## 5. Use Case Validation (OTBR + NCP-UART)

### 5.1 Test methodology

Tests use realistic packet sizes and rates matching actual gateway traffic patterns:

| Test         | Proto | Payload | Rate    | Simulates                    |
|--------------|-------|---------|---------|------------------------------|
| coap_rx/tx   | UDP   | 100 B   | 0.5 Mbps | CoAP (Thread device traffic) |
| mdns_rx/tx   | UDP   | 300 B   | 1 Mbps  | mDNS/DNS-SD (discovery)      |
| ncp_rx/tx    | TCP   | 100 B   | max     | Z2M ↔ ser2net (Zigbee frames)|
| tcp_rx/tx    | TCP   | 1448 B  | max     | Firmware update / SCP        |
| udp_flood    | UDP   | 1472 B  | 95 Mbps | Stress test (HW limits)      |

### 5.2 Results (v2.0 configuration, instrumented build)

| Test           | Mbps   | Loss | pps   | tx_avg_ns | rx_avg_ns |
|----------------|--------|------|-------|-----------|-----------|
| coap_rx        | 0.48   | 0%   | 513   | —         | 202 µs    |
| coap_tx        | 0.52   | 0%   | 530   | 33.6 µs   | —         |
| mdns_rx        | 0.99   | 0%   | 353   | —         | 195 µs    |
| mdns_tx        | 1.05   | 0%   | 355   | 34.2 µs   | —         |
| ncp_rx (100B)  | 91.8   | —    | 6,847 | —         | 72 µs     |
| ncp_tx (100B)  | 4.58   | —    | 551   | 24.7 µs   | —         |
| tcp_rx (max)   | 91.8   | —    | 6,826 | —         | 72 µs     |
| tcp_tx (max)   | 44.3   | —    | 3,115 | 20.2 µs   | —         |
| udp_flood_rx   | 2.58   | 96%  | 4,700 | —         | 136 µs    |
| udp_flood_tx   | 36.5   | 0%   | 2,507 | 32.9 µs   | —         |

### 5.3 Key observations

**CoAP and mDNS (OTBR data plane): zero loss, minimal CPU usage.**
At 500 pps / 0.5 Mbps, each packet gets dedicated IRQ/NAPI handling (1:1 ratio,
no batching needed). CPU usage: 500 × 200 µs = 100 ms/s = **10% CPU**. Plenty of
headroom for the actual Thread mesh traffic (typically < 100 pps).

**NCP RX (TCP 100B segments): same as TCP max (91.8 Mbps).**
TCP coalesces small segments via Nagle's algorithm and delayed ACKs. The gateway
receives full-size segments regardless of the sender's write size. The driver sees
no difference between `-l 100` and default MSS writes.

**NCP TX (TCP 100B segments): 4.6 Mbps — 10× slower than TCP max.**
With `-l 100`, iperf sends many small TCP segments. The per-packet overhead
(TCP/IP headers = 54 bytes for 100 bytes payload = 35% overhead) and per-packet
driver cost (24.7 µs) dominate. This is a worst case — real NCP-UART traffic is
UART-limited to 115200 bps (0.1 Mbps), giving **46× headroom** even in this mode.

**UDP flood: confirms hardware limits, irrelevant for use case.**
96% RX loss and 36.5 Mbps TX are hardware limitations (no interrupt coalescing).
Real OTBR UDP traffic is < 1000 pps, far below the saturation point.

### 5.4 Adequacy summary

| Use case           | Protocol | Typical rate | Available | Headroom |
|--------------------|----------|--------------|-----------|----------|
| OTBR data plane    | UDP      | < 1 Mbps     | 36 Mbps   | **36×**  |
| OTBR mDNS/DNS-SD   | UDP      | < 0.1 Mbps   | 36 Mbps   | **360×** |
| NCP-UART (ser2net) | TCP      | < 0.5 Mbps   | 44 Mbps   | **88×**  |
| Firmware update    | TCP      | up to 44 Mbps | 44 Mbps  | At limit |

The driver v2.0 configuration is well-suited for the gateway's dual role as
Zigbee (NCP-UART) and Thread (OTBR) border router. The only scenario where
throughput limits are noticeable is bulk file transfer.

## 6. Hardware and Software Versions

- SoC: Realtek RTL8196E (200 MHz Lexra RLX4181, single-core, no SMP)
- MAC: RTL8196E integrated 5-port 100 Mbps switch
- Kernel: 5.10.246 with custom Lexra/RLX patches
- I-MEM: 29 hot-path functions in 16 KB on-chip SRAM (7,348 bytes / 44.8%)
- Driver: rtl8196e-eth v2.0 (TX IRQ mitigation, rings 128)
- Measurements taken with temporary ktime instrumentation (removed from production build)
- Test tool: iperf v2 (both sides)
- Host: Ubuntu PC with Gigabit Ethernet
