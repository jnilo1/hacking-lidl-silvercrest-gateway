# RTL8196E Ethernet driver (`rtl8196e-eth`) — design

| | |
|---|---|
| **Document date** | 2026-06-12 (updated 2026-06-19 for driver 2.15 / ETHDRV-015) |
| **Driver version** | 2.15 (`RTL8196E_DRV_VERSION` in `rtl8196e_main.c`) |
| **Active release** | v3.10.0 GA (kernel `6.18.35-rtl8196e-v3.10.0`); v2.15 on the `v4.0.0-rc2` candidate, v2.8 on `v3.8.6` (both carry the #99 ETHDRV-015 engine fix) |

Architecture reference for the from-scratch Ethernet driver. Findings
and audit history live in `AUDIT.md`; the goals/non-goals contract is
`SPECIFICATIONS.md`; throughput history and tuning rationale are in
`PERFORMANCE.md` (all in this directory).

---

## 1. What the hardware actually is

The RTL8196E "MAC" is a **5-port managed switch ASIC** with the CPU
attached as a sixth port (port 5). There is no conventional MAC+PHY
pair:

- Frames reach the CPU only if the switch's lookup decides so — via a
  static hashed **L2 "toCPU" entry** for the interface MAC, a broadcast
  entry, or the trap-all fallback. Programming the **VLAN**, **NETIF**
  and **L2** tables is therefore part of bringing the link up, not an
  offload feature.
- DMA is descriptor-list based but uses the vendor's BSD-style
  `rtl_pktHdr` / `rtl_mBuf` two-level format (20 B + 32 B, big-endian
  bitfields, ABI locked by `BUILD_BUG_ON` + `__BIG_ENDIAN_BITFIELD`
  `#error` in `rtl8196e_desc.h`).
- The four downstream PHYs are internal, managed through PSRPx status
  registers and a vendor MDIO window — there is no MDIO bus to expose
  to phylib.
- On the Lidl board a single physical port (4) is wired; the driver is
  deliberately single-netdev (see `SPECIFICATIONS.md` non-goals).

## 2. Module decomposition

```
 rtl8196e_main.c        net_device lifecycle, NAPI poll, ISR, xmit,
       │                ethtool, sysfs (led_mode, kick_threshold), timers
       │ calls
 ┌─────┴──────────────┬─────────────────────────┐
 │ rtl8196e_hw.c      │ rtl8196e_ring.c         │ rtl8196e_dt.c
 │ switch bring-up,   │ descriptor rings, SKB   │ &ethernet/interface@0
 │ pinmux (syscon),   │ lifecycle, cache        │ parsing + validation
 │ MDIO/PHY, VLAN/    │ discipline, TX kick     │ (vlan/ports/mtu bounds)
 │ NETIF/L2 tables,   │ coalescing, anomaly     │
 │ DMA reg setup, IRQ │ counters                │
 │ mask/unmask        │                         │
 └────────────────────┴─────────────────────────┘
 headers: rtl8196e_regs.h (register map + MMIO helpers),
          rtl8196e_desc.h (HW descriptor ABI), *_hw.h/*_ring.h/*_dt.h (APIs)
```

`rtl8196e_hw.c` is intentionally the only file that knows switch
register semantics; `rtl8196e_ring.c` is the only one that knows the
descriptor ABI and cache rules; `main.c` owns kernel-facing policy.

## 3. Memory & cache model (the heart of the driver)

Non-coherent write-back L1 — every DMA byte is managed by hand. Three
memory classes:

| Object | Address space | Coherency strategy |
|---|---|---|
| Ring arrays (u32 entries: descriptor ptr + OWNED/WRAP bits) | **KSEG1** (uncached alias of kmalloc) | CPU and ASIC both see DRAM directly; ownership flips are instantly visible (see AUDIT ETHDRV-008 for the missing initial flush) |
| Descriptor pools (`rtl_pktHdr`/`rtl_mBuf`) | **KSEG0** (cached) | per-descriptor `dma_cache_wback_inv` before handover, `dma_cache_inv` before reading HW-written fields (KSEG1 pools benched −1.2 Mbit/s — F6, rejected) |
| Packet buffers (skb data) | KSEG0 (cached) | TX: `dma_cache_wback_inv(data, len)` after padding; RX: `inv` before reading, full-span `wback_inv` of the fresh buffer before rearm |

Ownership protocol per entry: bit 0 = SWCORE-owned (1) / RISC-owned
(0), bit 1 = WRAP, remaining bits = descriptor pointer (4-byte-aligned
pools guarantee the low bits are free). Every handover is
`fields → wback → wmb() → ownership store (WRAP-preserving) → wmb()`.

Addresses programmed into HW (ring bases, `m_data`) are KSEG0/KSEG1
*virtual* addresses — the ASIC ignores the top segment bits. Documented
as intentional (F17/ETHDRV-006; ETH-S01 tracks the ioremap cleanup).

## 4. Data paths

### TX (`start_xmit`, `__iram`)

1. linearize if needed; `skb_put_padto(ETH_ZLEN)` **before** any flush
   (info-leak guard, ETH-001);
2. opportunistic `tx_reclaim` (TX_ALL_DONE IRQ is deliberately never
   armed — software reclaim here, in NAPI, and via the TX-reclaim timer
   below replaces one IRQ per completion);
3. flush data, `tx_submit` (pool-bounds-validated descriptor, ≤1518 B),
   retry once after a reclaim, else stop queue / `NETDEV_TX_BUSY`;
4. `kick_tx`: pulse CPUICR.TXFD immediately on cold start (ring was
   empty), otherwise coalesce `kick_threshold` (default 4, sysfs
   tunable) submits per pulse — a pulse costs ~1.44 µs of MMIO;
   NAPI's `kick_drain` flushes a sub-threshold remainder so nothing
   idles in the ring;
5. queue stops at < 4 free slots, NAPI rewakes at ≥ 16 (hysteresis);
6. **BQL** (ETH-S05): `netdev_sent_queue(skb->len)` after the submit is
   final (a `NETDEV_TX_BUSY` return above hands the skb back
   unaccounted). The completion side is `netdev_completed_queue` at the
   three reclaim sites (opportunistic xmit, xmit-retry, NAPI); both
   sides count `skb->len`. BQL keeps the *in-driver* queue shallow so
   bulk traffic cannot bury latency-sensitive frames in the 128-deep
   ring — see `PERFORMANCE.md` (the ring can hold ~15 ms of buffering;
   BQL's limit converges to ~2.5 KB ≈ ~0.2 ms under load). On this box
   that latency budget matters: the UART↔TCP bridge's EZSP/CPC/Spinel
   control frames share eth0 with any bulk transfer, and their protocol
   timers do not tolerate the jitter a deep FIFO injects. BQL is also
   the *enabler* for the qdisc — `pfifo_fast` today, a future
   `fq_codel` — which can only schedule packets still in the qdisc, not
   ones already dumped into the ring.

### TX-reclaim timer (the no-RX stall)

Both reclaim drivers above (xmit, NAPI) need *activity* to run: a fresh
xmit, or an RX-woken poll. A queue that stops (ring-full XOFF or BQL
byte-limit XOFF) while no RX is arriving — a purely-TX or low-RX workload
such as a border router idling with no paired peer — therefore has nothing
to reclaim its in-flight descriptors and would sit stopped until the 10 s
netdev watchdog fires `tx_timeout`. The **software TX-reclaim timer**
(`RTL8196E_TX_RECLAIM_MS`, 4 ms) closes that window: `start_xmit` and the
poll arm it whenever they leave the queue `netif_xmit_stopped`; the callback
`napi_schedule`s (reclaim + `netdev_completed_queue` + wake/un-freeze) and
the poll re-arms it while the queue stays stopped. Once the queue drains,
`netif_xmit_stopped()` is false and the timer lapses — bounded, never runs
on a moving queue. The arm is guarded by `timer_pending()` so the TX hot
path pays nothing once armed (an unconditional `mod_timer` per packet cost
~5 % TX on this CPU; see `PERFORMANCE.md`).

### RX (`rtl8196e_ring_rx_poll` from NAPI, `__iram`)

For each RISC-owned pkthdr entry, up to budget: validate the pkthdr
pointer (pool bounds, fallback to index mapping), `inv` + read it,
validate `ph_mbuf` the same way, then look the shadow skb up **by
hardware mbuf index** — under saturation the ASIC links pkthdr[i] to a
mbuf of a different index, the v2.6 lesson — bound-check `ph_len`,
`inv` the data, hand the old skb to `napi_gro_receive`, install a fresh
`napi_alloc_skb` buffer, and rearm from a canonical descriptor state on
*every* exit path (nominal/drop/bad-len) so HW never sees stale fields.
All anomaly paths count in `ethtool -S` (`rx_wild_*`, `rx_bad_len`,
`rx_mbuf_no_shadow`, …) and must stay at zero in nominal flow.

`ip_summed = CHECKSUM_UNNECESSARY` is blanket — the documented,
bench-forced ETHDRV-003 trade-off (AUDIT §1.3).

### IRQ / NAPI

ISR (`__iram`): read `CPUIISR ∧ CPUIIMR`, W1C owned bits only,
`IRQ_NONE` otherwise; LINK_CHANGE updates carrier inline; RX_DONE /
RUNOUT masks IRQs and schedules NAPI. Poll: RX up to budget → TX
reclaim (+ `netdev_completed_queue` for BQL) → kick drain →
conditional queue wake → re-arm the TX-reclaim timer if the queue is
still stopped → on completion W1C runout bits and re-enable IRQs. The probe sets
`napi_defer_hard_irqs = 1` + `gro_flush_timeout = 2 ms` **before**
`netif_napi_add` (6.x copies them at add time): batching the GRO flush
is worth +33 % RX / +36 % TX on this CPU (rationale block in probe).

## 5. Bring-up sequence

Since v2.11 (ETH-S03) the one-time SoC bring-up runs **once at probe**:
`hw_init` (pinmux + board 0x44 pad state via syscon, switch-clock cycle
with 650 ms of sleeps, MEMCR, FULL_RST, LED direct mode, queue mapping,
L2 clear), followed by the ETHDRV-010 IRQ quiesce.

`ndo_open` only programs the volatile per-open state — measured ~30 ms
on the bench (was >1 s): ring base registers → PHY reset + autoneg →
VLAN table + PVIDs → NETIF entry (MAC/VID/MTU) → L2 setup + toCPU entry
+ broadcast entry + readback verify (trap-all fallback at every
failure) → `hw_start` (TXCMD/RXCMD/TRXRDY) → `napi_enable` → unmask
IRQs → carrier from PSRPx.

The 0x44 pad write moved to probe with the rest: nothing re-clears pad
muxes at runtime since v2.7 (this write *was* the clobberer), so one
boot-time board-state write is the whole contract — re-validated on the
bench (nRST RSTACK after a down/up flap).

`stop()` quiesces in the reverse direction and **resets both rings**
(in-flight SKBs freed, descriptors rebuilt, shadow SKBs reused) so the
next `open()` — which only reprograms base registers — starts from a
canonical state. `tx_timeout` runs the same recipe but **must reset both
rings too, not just TX**: its `hw_stop()`/`hw_start()` cycles the switch RX
engine (TRXRDY) back to descriptor 0, so the RX cursor and bases have to be
resynced or the switch sees no usable RX descriptors and storms
`PKTHDR_DESC_RUNOUT` — the #99 soft-lockup (see AUDIT ETHDRV-013, invariant
9). A TX-only recovery is the bug, not the optimisation.

## 6. Concurrency model

- **UP SoC, three actors**: process context (open/stop/sysfs under
  RTNL), softirq (NAPI poll + timers), hardirq (ISR). No spinlocks in
  the fast path by design:
  - `start_xmit` runs with BH disabled → cannot interleave with NAPI on
    the single CPU; the TX ring is strict SP/SC with
    `READ_ONCE`/`WRITE_ONCE` on the indices.
  - `pending_kicks` races at worst into one extra TXFD pulse —
    idempotent on a non-empty ring.
  - ISR vs poll IRQ-mask handoff follows the standard
    `napi_schedule_prep → disable → __napi_schedule` pattern.
- Link state: hardirq LINK_CHANGE plus an optional poll timer
  (`link_poll_ms` DT property or module param, 0 = off) for setups
  where the latched IRQ proves unreliable.
- TX-reclaim timer: a softirq-context timer that only ever
  `napi_schedule`s — it touches no ring state itself, so it adds no new
  locking surface (the reclaim runs in the poll it wakes).
- Slow-path MMIO (MDIO, table engine, TLU) is process-context only,
  serialised by RTNL; the wait loops sleep (`usleep_range`).

## 7. External dependencies

| Dependency | Where | Role |
|---|---|---|
| `CONFIG_RTL8196E_ETH=y` | `config-6.18-realtek.txt`, `Kconfig` here | builds the four objects into `rtl8196e_eth.o` |
| `ethernet@10000` node + `interface@0` child | `rtl819x.dtsi` / `rtl8196e.dts` | IRQ 15 on `&intc`, `realtek,syscon` phandle, VLAN/ports/MTU config (`reg` window currently unused — ETH-S01) |
| sysc syscon regmap | `rtl819x.dtsi` | PIN_MUX_SEL/PIN_MUX_SEL_2 writes in `hw_init` — shared with `8250_rtl819x` and `gpio-rtl819x` (the former ETHDRV-007 / GPIO-007 contention is closed in v2.7: 0x44 fields derive from the GPIO node) |
| `gpio0` node `gpio-line-names` + `realtek,led-pads` | board DTS | decides each B2–B6 pad's 0x44 function — named → GPIO (`0b11`), in `led-pads` → LED_PORTn (`0b00`), neither → unclaimed GPIO/Hi-Z (`0b11`); `led-pads` absent → v2.7 fallback (unnamed → `0b00`) |
| `__iram` (`asm/mach-realtek/imem.h`) | arch overlay | hot functions (xmit, poll, ISR, ring ops) in 16 KB zero-wait I-SRAM |
| `dma_cache_*` (`asm/cacheflush.h`) | MIPS arch | the entire coherency model of §3 |
| S10network (userdata) | rootfs/userdata | persists the random MAC across boots (`ifconfig hw ether` at boot) |
| `scripts/test_rtl8196e_eth.sh` | `32-Kernel/scripts/` | the mandatory regression gate (~94 RX / ~73 TX Mbit/s, OTBR stopped) |

## 8. Invariants (do not break)

1. **Every perf-affecting change goes through the full iperf gate.**
   This platform has rejected four "obviously safe" optimisations on
   hardware evidence (F6, F11/F13/F15, gated csum, SG). >1 Mbit/s
   sustained delta or non-zero retrans = regression.
2. **The descriptor ABI is frozen** — sizes, offsets, big-endian
   bitfields, 4-byte pool alignment (ownership bits live in the low
   pointer bits). The compile-time guards must stay.
3. **Handover ordering** (`wback → wmb → ownership store → wmb`) and
   the canonical-rearm rule (every RX exit path rebuilds ph/mb fields)
   are load-bearing for the non-coherent cache model.
4. **`skb_put_padto` stays ahead of the data flush** — reordering
   reintroduces the ETH-001 slab leak on the wire.
5. **TX_ALL_DONE stays unarmed**; reclaim lives in xmit, NAPI, and the
   software TX-reclaim timer (the timer is what lets a no-RX stall recover
   without that IRQ — ETHDRV-014). Arming TX_ALL_DONE reintroduces one IRQ
   per completion on a 400 MHz core.
   **Corollary — BQL accounting must stay balanced**: every byte passed
   to `netdev_sent_queue` must later reach `netdev_completed_queue`, and
   every ring reset (`open`, `stop`, `tx_timeout`) must pair its
   `tx_reset` with `netdev_reset_queue`. A leaked count (sent without a
   matching completed, or a reset that drops in-flight bytes without
   resetting BQL) leaves BQL's limit stuck and the qdisc throttled — the
   TX queue wedges silently. The `tx_reclaim_no_skb` anomaly path is
   safe because it routes to `tx_timeout`, whose reset re-syncs BQL.
6. **GRO-defer fields are set before `netif_napi_add`** — setting them
   after is a silent no-op in 6.x.
7. **Shadow SKBs are indexed by hardware mbuf index, never by ring
   position** — position correspondence breaks under RX saturation
   (driver 2.6 fix; `rx_mbuf_no_shadow` counts violations).
8. **PIN_MUX_SEL bits [4:3] = 01, and 0x44 follows the GPIO node** —
   the UART1 mux value must be preserved exactly (v1.2 lesson). Since
   v2.8 the 0x44 fields are three-state from the GPIO controller node
   (named in `gpio-line-names` → `0b11` GPIO, listed in
   `realtek,led-pads` → `0b00` LED_PORTn, neither → `0b11` unclaimed
   GPIO/Hi-Z, `[17:15]` cleared; property absent → v2.7 fallback). The
   LED pad stays *declared*, never derived from `member-ports` — it is
   a wiring fact only a visual check proves (a member port may have no
   LED wired). Both known boards do follow the Table 36 1-1 naming
   (Lidl port 4 → B6/LED_PORT4, G4 port 0 → B2/LED_PORT0, verified by
   eye after the Lidl value first shipped wrong as B2 — register
   readback cannot catch a wrong LED pad, #126). Any future
   edit must keep the board — not the driver — as the owner of that
   decision. Since v2.11 the write runs once at probe (it must stay
   the *only* runtime writer that ever cleared these fields — what
   closed ETHDRV-007 is precisely that nothing re-clears them).
9. **`tx_timeout` resets *both* rings, symmetric with `open`/`stop`** — it
   cycles the switch via `hw_stop`/`hw_start`, which rewinds the RX engine
   to descriptor 0; a TX-only recovery desyncs RX and triggers the #99
   `PKTHDR_DESC_RUNOUT` storm (AUDIT ETHDRV-013). Keep `ring_rx_reset` +
   `hw_set_rx_rings` in the recovery path alongside the TX reset.
