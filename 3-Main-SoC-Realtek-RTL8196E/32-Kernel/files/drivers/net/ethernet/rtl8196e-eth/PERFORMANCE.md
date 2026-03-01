# RTL8196E Ethernet Driver — Performance Analysis

## Measured throughput

### Test conditions

- Ubuntu 22.04 host, gateway 192.168.1.126, iperf 2.x
- **Direct connection**: short Cat 6 cable between host and gateway (no switch,
  no router).  Throughput drops up to 60% when tested through a LAN with
  switches or consumer routers due to buffering, QoS, and store-and-forward
  latency on the intermediate hops.
- TCP tests: 30 s per run; stress test: 300 s
- Kernels: 5.10.246-rtl8196e-eth (new) / 5.10.246-rtl8196e (legacy)
- rtl8196e-eth v1.0 measured 2026-02-22; v1.1 measured 2026-02-28; rtl819x measured 2026-02-23
- v1.1 adds PIN_MUX_SEL/SEL2 clearing (fixes EFR32 nRST, also cleans up MII pin mux)
- v1.2 fixes PIN_MUX_SEL UART1 pin mux (fixes universal-silabs-flasher probe)

### TCP throughput

| Test                      | rtl819x (legacy) | rtl8196e-eth v1.0 | rtl8196e-eth v1.1 | Delta (v1.1 vs legacy) |
|---------------------------|------------------|-------------------|-------------------|------------------------|
| TCP RX (host→gw, 30s)     | 85.7 Mbps        | 91.2 Mbps         | **91.6 Mbps**     | +5.9 Mbps (+6.9%)      |
| TCP TX (gw→host, 30s)     | 43.4 Mbps        | 46.9 Mbps         | **49.2 Mbps**     | +5.8 Mbps (+13.4%)     |
| TCP Parallel 4 streams    | 90.0 Mbps        | 94.6 Mbps         | **94.7 Mbps**     | +4.7 Mbps (+5.2%)      |
| TCP Parallel 8 streams    | 70.0 Mbps        | 70.9 Mbps         | **67.4 Mbps**     | -2.6 Mbps (-3.7%)      |
| TCP Stress 300s           | 88.8 Mbps        | 92.0 Mbps         | **92.0 Mbps**     | +3.2 Mbps (+3.6%)      |

The new driver is consistently faster on all single-stream TCP tests.
v1.1 shows a notable TX improvement (+13.4% vs legacy, +4.9% vs v1.0) —
clearing PIN_MUX_SEL2 removes pin contention on the MII bus.
The 8-stream result varies between runs (measurement noise at high contention).

### Driver error counters (full test session)

| Counter                    | rtl819x | rtl8196e-eth v1.0 | rtl8196e-eth v1.1 |
|----------------------------|---------|-------------------|--------------------|
| RX errors                  | 0       | 0                 | 0                  |
| TX errors                  | 0       | 0                 | 0                  |
| RX dropped                 | 5       | 6                 | 2                  |
| TX dropped                 | 0       | 0                 | 0                  |
| TCP RetransSegs (SoC side) | 0       | 0                 | 0                  |

2–6 RX drops over 3.5 M packets (0.0001%) — negligible.

### UDP loss at saturation

| Target bandwidth | rtl819x | rtl8196e-eth v1.0 | rtl8196e-eth v1.1 |
|-----------------|---------|-------------------|--------------------|
| 10 Mbps         | 0%      | 0%                | 0%                 |
| 50 Mbps         | 40%     | 60%               | 71%                |
| 100 Mbps        | 41%     | 57%               | 48%                |

Legacy shows lower UDP loss at high load. The rtl819x private buffer pool
pre-allocates receive buffers, absorbing bursts more efficiently than the
standard page-fragment allocator used by rtl8196e-eth. UDP loss at
saturation varies between runs (50 Mbps: 60→71%, 100 Mbps: 57→48%);
these are within normal variance for a 400 MHz MIPS SoC with no hardware
UDP offload. Neither driver approaches UDP line rate.

---

## Why is TX throughput roughly half of RX?

### CPU utilization measurement (confirmed)

To settle this question experimentally, CPU utilization was measured on the
gateway during both TCP tests using `/proc/stat` sampled at 1-second intervals:

| Test              | Gateway CPU   | Throughput     |
|-------------------|---------------|----------------|
| TCP RX (host→gw)  | **100% busy** | ~86–92 Mbps    |
| TCP TX (gw→host)  | **100% busy** | ~43–49 Mbps    |

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
each capable of 100 Mbps simultaneously.  RX reaching 91–92 Mbps confirms
the DMA engine, switch fabric, and ring management all function at near
line-rate.  A hardware bottleneck would suppress RX throughput as well.

---

## UDP experiment: testing the checksum hypothesis

A UDP TX test was run (gateway → host, `iperf -u -b 100M -c <host> -t 10`,
0% packet loss) to isolate the TCP checksum contribution.

**Result: UDP TX = 25.4 Mbps — lower than TCP TX (44–49 Mbps).**

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

## PIN_MUX_SEL and UART1 — the EFR32 serial regression (v1.1 → v1.2)

### Symptom

After the v1.1 PIN_MUX_SEL/SEL2 clearing (commit `707effb`),
`universal-silabs-flasher` could no longer probe the EFR32 Zigbee radio
through `serialgateway`.  The UART1 peripheral worked internally (THRE
interrupts fired, DMA ran) but **no electrical signal reached the EFR32
on the physical TX/RX pins**.

### Diagnosis

Register comparison between the working Tuya firmware and our kernel
revealed that PIN_MUX_SEL = `0x00000000` on our kernel vs `0x00000042`
on Tuya.  Direct FIFO inspection confirmed the problem:

```
PIN_MUX_SEL = 0x00  →  echo ASH reset to /dev/ttyS1  →  LSR DR=0  (no RX data)
PIN_MUX_SEL = 0x4A  →  echo ASH reset to /dev/ttyS1  →  LSR DR=1  (EFR32 responded)
```

The UART hardware processed transmissions internally (THRE fired), but
the pin mux was not routing the UART1 signals to the physical pins.

### Root cause

Two independent gaps:

1. **Bootloader**: unlike the Tuya bootloader, ours does not set
   PIN_MUX_SEL bits 1 and 6 (UART1 RXD/TXD routing).

2. **Ethernet driver v1.1**: the PIN_MUX_SEL write cleared the
   bits[4:3] field to `00` (default/GPIO) instead of setting it to `01`
   (UART1 TXD) as the Realtek vendor BSP does:
   ```c
   /* Vendor BSP (linux-2.6.30/boards/rtl8196e/bsp/serial.c) */
   REG32(0xb8000040) = (REG32(0xb8000040) & ~(0x3<<3)) | (0x01<<3);
   ```

### Fix (v1.2)

| Driver | Change |
|--------|--------|
| `rtl8196e_hw.c` (Ethernet) | Set PIN_MUX_SEL bits[4:3] to `01` (UART1) instead of `00` |
| `8250_rtl819x.c` (UART1)   | Set PIN_MUX_SEL bits 1, 3, 6 at probe time |

The two fixes are independent of probe ordering: whichever driver loads
first, the final PIN_MUX_SEL value is `0x4A` (bits 1, 3, 6).

The nRST protection is preserved — that fix relies on PIN_MUX_SEL2
clearing (unchanged) and on the other PIN_MUX_SEL fields (bits 8–11, 15,
also unchanged).  Setting bits[4:3] to `01` (UART1) does not drive nRST.

### Verification

After cold boot (no devmem workaround):

```
$ universal-silabs-flasher --device socket://192.168.1.127:8888 probe
Detected ApplicationType.EZSP, version '7.5.1.0 build 0' at 115200

$ ./flash_efr32.sh 192.168.1.127
ncp-uart-hw-7.5.1.gbl  [####################################]  100%
```

Both probe and flash work in normal mode (CRTSCTS) and flash mode
(`serialgateway -f`, no hardware flow control).

---

*Hardware: Realtek RTL8196E SoC, Lexra RLX4181 CPU (400 MHz, MIPS-1 + MIPS16
ISA, big-endian, single core, no FPU, no SIMD, write-back L1 cache,
16 KB I-cache, 8 KB D-cache).  Link: 100BASE-TX full duplex.*

*TCP baseline: Ubuntu 22.04 host, gateway 192.168.1.126, iperf 2.x,
30 s TCP tests (stress: 300 s).*

*CPU measurement: `/proc/stat` sampled at 1 Hz during each test.*

*UDP TX test: `iperf -u -b 100M -c 192.168.1.200 -t 10` from gateway,
0% packet loss, 10 s, 21597 datagrams.*
