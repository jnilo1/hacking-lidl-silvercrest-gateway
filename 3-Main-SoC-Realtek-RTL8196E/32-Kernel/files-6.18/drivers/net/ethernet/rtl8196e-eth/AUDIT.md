# RTL8196E Ethernet driver (`rtl8196e-eth`) — audit

| | |
|---|---|
| **Audit date** | 2026-06-12 (updated same day for drivers 2.7 through 2.13) |
| **Driver version** | 2.13 (`RTL8196E_DRV_VERSION` in `rtl8196e_main.c`) |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`); v2.8..v2.13 unreleased |
| **Audited artifacts** | `rtl8196e_main.c` (923 l), `rtl8196e_ring.c` (920 l), `rtl8196e_hw.c` (808 l), `rtl8196e_dt.c` (126 l), `rtl8196e_{desc,regs,hw,ring,dt}.h`, `Kconfig`, `Makefile`, `rtl819x.dtsi` / `rtl8196e.dts` ethernet nodes, `config-6.18-realtek.txt` |

This document **supersedes and replaces** the cumulative audit log of
2026-04-23 / 2026-05-01 / 2026-05-03 (passes F1–F17, ETH-001..008,
ETHDRV-001..006). It is based solely on the current code. All legacy
finding IDs remain resolvable in the registry (§4) because several are
referenced from code comments (`ETHDRV-003` in `rtl8196e_ring.c` and
`rtl8196e_regs.h`) and from the GPIO driver audit (GPIO-007
cross-reference). The detailed bench tables of the rejected experiments
(F6, F11/F13/F15, the three ETHDRV-003 patch variants) live in the
superseded AUDIT.md, retrievable via `git log` on this file;
`PERFORMANCE.md` keeps the per-release throughput history.

Scope baseline: single netdev (`eth0`, port 4 on the Lidl board), NAPI +
GRO-defer tuning, KSEG1 (uncached) descriptor rings over KSEG0 (cached)
descriptor pools with explicit `dma_cache_*` discipline, SP/SC TX ring,
`__iram` hot paths. Current bench baselines: ~94 Mbit/s TCP RX,
~73 Mbit/s TCP TX (see `32-Kernel/CLAUDE.md`).

---

## 1. Security analysis

### 1.1 Attack surface

| Surface | Reachable by | Driver exposure |
|---|---|---|
| RX frames + ASIC-written descriptors | anyone on the wire / DMA | `rx_poll` trusts nothing: pkthdr and mbuf pointers pool-bounds-checked with index fallback (`rx_wild_*` counters), `ph_len` clamped to `[ETH_ZLEN, buf_size]` before `skb_put`, shadow skb looked up by **hardware** mbuf index with `< rx_cnt` guard (driver 2.6) |
| TX path (skb from stack) | local stack | nonlinear skbs linearised; short frames `skb_put_padto(ETH_ZLEN)` **before** cache flush — no slab-tail leak on the wire (ETH-001); len > 1518 rejected (`tx_bad_len`) |
| Devicetree | build-time (trusted) | `vlan-id` 1–4095, `member-ports` ⊆ 0x1ff and ≠ 0, `untag ⊆ member`, `mtu` 576–1500, `ifname` via `strscpy` (ETH-006) |
| sysfs (`led_mode`, `kick_threshold`) | root only (0644 dev attrs) | `sysfs_streq` whitelist / `kstrtouint` + range 1..64; no parsing of attacker data |
| module params (4 × 0644) | root only | debug knobs by design (ETHDRV-005); `rtl8196e_cpu_port_mask` is consumed only at `open()`, stray high bits are masked by the table packers |
| ethtool ops | `CAP_NET_ADMIN` | fixed-size string table, `data[]` filled to exactly `RTL8196E_ETHTOOL_STATS_COUNT`; no variable-length copy |

### 1.2 Verified correct in the current code

- **TX zero-padding before DMA** (`skb_put_padto` ahead of
  `dma_cache_wback_inv`) — the ETH-001 information-leak fix is present
  and ordered correctly; the ring-level `len < ETH_ZLEN → len = ETH_ZLEN`
  raise is now only defence in depth (those bytes are zeroed).
- **TX handover ordering**: descriptor fields → `dma_cache_wback_inv` →
  `wmb()` → ownership flip (WRAP-preserving) → `wmb()`. RX rearm mirrors
  it (skb buffer + ph + mb wback before the SWCORE_OWNED store).
- **SP/SC TX ring**: `start_xmit` runs with BH disabled (netdev xmit
  path) and NAPI is a softirq on the same single CPU — no true
  concurrency; `READ_ONCE`/`WRITE_ONCE` on `tx_prod`/`tx_cons` prevent
  compiler tearing. Ring-full check keeps one slot open
  (`next == tx_cons` → `-ENOSPC`).
- **ISR discipline** (F7): reads `CPUIISR ∧ CPUIIMR`, returns `IRQ_NONE`
  without acking when nothing is owned, W1Cs only the owned bits.
- **`tx_timeout` quiesce** (F1): `napi_disable` before ring reset;
  re-enable order (hw_start → napi_enable → enable_irqs) is safe.
- **MAC change refused while UP** (F2): prevents a silent NETIF/L2
  desync; next `open()` reprograms both tables from `dev_addr`.
- **Descriptor ABI guards**: `BUILD_BUG_ON` on sizes/offsets (ETH-004)
  and the `__BIG_ENDIAN_BITFIELD` `#error` (ETHDRV-004) are present.
- **Table-engine failure paths** (F10): TLU timeout aborts the write
  with `-EIO`; `open()` falls back to trap-to-CPU mode when the L2
  toCPU entry cannot be installed or verified.
- **Sleeping waits in process context** (F3/F4): `msleep` /
  `usleep_range` throughout `hw_init` and the poll-ready loops.
- **DT refcounts**: `for_each_child_of_node` early-return hands an
  elevated ref to the caller, which `of_node_put`s on every exit.
- **PIN_MUX_SEL (0x40) writes** match the documented v1.2 UART1 fix:
  bits [4:3] = 01 preserved, MII bits cleared; bits 1/6 are owned by
  `8250_rtl819x` and untouched here. Since v2.7 the **PIN_MUX_SEL_2
  (0x44)** write derives each B2–B6 pad field from the GPIO controller
  node — the board, not the driver, decides pad ownership (closes
  ETHDRV-007). v2.8 makes the rule three-state: named in
  `gpio-line-names` → `0b11` (GPIO), listed in `realtek,led-pads` →
  `0b00` (LED_PORTn), neither → `0b11` left as unclaimed GPIO (Hi-Z —
  Table 36 has no disable encoding); `[17:15]` (MII) always cleared.
  Property absent → every unnamed pad falls back to `0b00` (v2.7
  behaviour, third-party DTB compatibility).

### 1.3 Standing accepted risk — ETHDRV-003 (unchanged)

The RX path still applies blanket `CHECKSUM_UNNECESSARY`
(`rtl8196e_ring.c`, comment block at the assignment). Empirical
characterisation (2026-05-03, preserved in the superseded log) showed
bad-UDP-checksum frames reach userland sockets; all three gated-csum
variants regressed the bench by 13–33 Mbit/s because the ASIC does not
reliably set `CSUM_TCPUDP_OK` for TCP under load, and CSCR has no
"reject bad L3/L4 toward CPU" bit (SDK V3.4.7.3 layout, documented in
`rtl8196e_regs.h`). Exposure is bounded: on-link attacker, UDP-IPv4
surface limited to the DHCP client on the stock system. Classified
**case D — accepted, re-openable**; any retry must pass the standard
iperf suite.

### 1.4 Verdict

No remotely exploitable memory-safety flaw found in the current code.
The RX hot path validates every hardware-influenced value before use,
and the TX path no longer leaks slab memory. The two medium findings
below were a cross-driver ownership violation (ETHDRV-007 — closed in
v2.7) and a latent cache-aliasing hazard at ring creation (ETHDRV-008)
— both robustness, not exploitability, on this platform.

---

## 2. New findings (this audit)

| ID | Type | Severity | One-liner |
|----|------|----------|-----------|
| ETHDRV-007 | ROBUSTNESS (cross-driver) | **medium** | *(closed in v2.7)* `hw_init()` (ndo_open) cleared PIN_MUX_SEL_2 fields owned by held GPIO lines — silently broke `efr32-nrst` control after any `ifconfig eth0 up` |
| ETHDRV-008 | ROBUSTNESS (DMA) | **medium** | ring arrays are written via KSEG1 without flushing the cached alias first — stale dirty lines can later evict over live descriptors |
| ETHDRV-009 | ROBUSTNESS | low | `stop()` masks IRQs before `napi_disable()`; a racing NAPI completion re-arms `CPUIIMR` on a downed interface |
| ETHDRV-010 | HARDENING | low | probe `request_irq`s before quiescing `CPUIIMR`/`CPUIISR`; bootloader-latched state (the bootloader uses this NIC for TFTP) can fire the ISR on a not-yet-registered netdev |
| ETHDRV-011 | ROBUSTNESS (debug) | info | `dbg_timer_fn` dereferences ring-entry pointers without the pool-bounds checks the hot paths use (root-only, `rtl8196e_debug` gated) |
| ETHDRV-012 | API | info | no `ndo_change_mtu`: a live MTU change updates `ndev->mtu` but not the NETIF table until the next `open()` |

### ETHDRV-007 — eth re-clears GPIO-owned mux fields on every open (medium)

`rtl8196e_hw_init()` (`rtl8196e_hw.c:322`) does
`regmap_update_bits(syscon, 0x44, (3<<6)|(3<<9)|(3<<12)|(7<<15), 0)` and
is called from `rtl8196e_open()` — i.e. on **every** interface up, not
once at boot. Fields [7:6]/[10:9]/[13:12] are the B4/B5/B6 pad muxes
that `gpio-rtl819x` sets to `0b11` (GPIO mode) at line-request time. On
the Lidl board B4 is `efr32-nrst`, held by the uart-bridge via gpiod
with open-drain emulation.

Consequence: after any `ip link set eth0 down/up` while the radio is
running, the B4 pad silently leaves GPIO mode. The line stays
*requested* in gpiolib, so nothing re-runs the request-time mux — every
subsequent nRST pulse (EFR32 recovery, `flash_efr32.sh` bootloader
entry) is a no-op until reboot. The `0b00` value historically chosen
here keeps nRST deasserted on the Lidl board, so the radio does not
reset spontaneously — the failure is the *loss of reset control*, which
is exactly the failure class the v3.9.0 nRST rework eliminated. On
boards using B5/B6 as GPIO (Sengled G4 button), the same clobber hits
input lines.

This is the driver-side counterpart of **GPIO-007** (see
`drivers/gpio/AUDIT.md` §2) — the fix belongs here. Recommendation,
in preference order:

1. Move the whole one-time pinmux + clock + reset bring-up out of
   `ndo_open` into probe (couples with ETH-S03). Probe runs before the
   uart-bridge requests the line (and can be ordered against it), so a
   single boot-time clear keeps the historical "nRST not driven low
   before the bridge takes over" guarantee without ever undoing a
   live GPIO claim.
2. Alternatively, make the clear ownership-aware: read each 2-bit
   field first and skip any field already at `0b11` (the "a GPIO
   consumer owns this pad" convention from the GPIO audit).

**Resolution (v2.7, v3.11.0-pre).** Fixed by a third, stronger variant
of recommendation 2: ownership comes from the **DT contract** rather
than from the current register value. `hw_init()` reads the GPIO
controller's `gpio-line-names` and writes each B2–B6 field accordingly —
named pad → `0b11` (GPIO), unnamed → `0b00` (LED_PORTn), `[17:15]`
always cleared. `ndo_open` still runs the write, but for a held GPIO
line it now *re-asserts* the same `0b11` the gpio-rtl819x request hook
set, so a `down/up` no longer un-muxes anything; it also gives named
on-demand lines (nRST, blmode) a deterministic GPIO-input state from
boot — bench-measured: nRST floats high via the EFR32 pull-up before any
claim. Residual exposure (v2.7): a line claimed via the cdev *without* a
DTS name still got `0b00` on every open. **Closed by v2.8** (#126,
hlyi's report): with `realtek,led-pads` present on the GPIO node, only
listed pads get `0b00`; named pads stay `0b11` and *everything else* is
left as unclaimed GPIO (`0b11`, Hi-Z — Table 36 has no disable
encoding) — so an anonymous cdev claim keeps its GPIO mux across
`down/up`, and no unknown wiring is ASIC-driven. The LED pad is
declared, not derived from `member-ports`, because it is a wiring fact
only a visual check proves (a member port may have no LED wired). Both
known boards do follow the Table 36 1-1 naming — Lidl port 4 →
B6/LED_PORT4, G4 port 0 → B2/LED_PORT0, both verified by eye after the
Lidl value first shipped wrong as B2 and killed the LAN LED (register
readback cannot catch a wrong LED pad, #126). ETH-S03
(hoist bring-up to probe) remains open as a pure latency item — it no
longer carries the ownership fix.

### ETHDRV-008 — no cache flush of ring-array memory before KSEG1 aliasing (medium)

`rtl8196e_alloc_uncached()` (`rtl8196e_ring.c:87`) kmallocs the three
descriptor *ring arrays* (`tx_ring`, `rx_pkthdr_ring`, `rx_mbuf_ring`)
and returns the KSEG1 alias; from then on the CPU touches them only
uncached. But the underlying lines may still sit **dirty in the
write-back L1** from the memory's previous lifetime (a freed skb, any
prior slab user — `kfree` does not flush). A later eviction writes the
stale line back to DRAM, clobbering ring entries that were written via
KSEG1 — corrupt ownership bits or wild descriptor pointers. The
defensive `tx_bad_pkthdr`/`rx_wild_*` checks would degrade it from an
oops to dropped slots, but it is a real one-shot corruption window.

The driver demonstrably knows the rule — the descriptor *pools* get a
full `dma_cache_wback_inv` after init (lines 263–264), and the rejected
F6 experiment flushed before aliasing — the ring arrays just never got
the same treatment. Note the odd `dma_cache_inv` on a KSEG1 address in
`tx_reclaim` (F11 heritage): on this virtually-indexed,
physically-tagged cache it can hit and discard the stale KSEG0-alias
line, accidentally protecting the **TX** ring at reclaim time; the two
RX rings have no such accidental cover.

Fix (3 lines, when implemented): `dma_cache_wback_inv((unsigned long)p,
size)` on the cached pointer inside `rtl8196e_alloc_uncached()` before
returning the alias. Cost: one-time, probe only.

**Resolution (v2.9).** Implemented exactly as above. Full iperf gate
passed (see `PERFORMANCE.md`, v2.9 entry).

### ETHDRV-009 — stop() ordering lets a racing NAPI re-arm IRQs (low)

`rtl8196e_stop()` order is: `netif_stop_queue` → `disable_irqs` →
`hw_stop` → W1C → `napi_disable`. A NAPI poll already in flight when
IRQs are masked can finish with `work_done < budget`, and its
`napi_complete_done()` branch then calls `rtl8196e_hw_enable_irqs()` —
re-arming `CPUIIMR` on an interface going down. Today this is harmless
(`hw_stop` has already cleared TXCMD/RXCMD/TRXRDY, so no event can
latch), but the masking is illusory and the pattern breaks if `stop()`
ever relies on IRQs being off. Conventional fix: `napi_disable()`
(which waits out the in-flight poll) before `disable_irqs`/`hw_stop`;
the ring resets already sit correctly after both.

**Resolution (v2.9).** Reordered as recommended. The short window where
an RX IRQ can land between `napi_disable` and the mask is benign: the
ISR W1C-acks and `napi_schedule_prep` refuses on a disabled NAPI — no
storm, verified in-code and exercised by a live down/up under traffic
on the bench.

### ETHDRV-010 — probe-time IRQ window before netdev registration (low)

`rtl8196e_probe()` calls `request_irq()` (which unmasks the line at the
interrupt controller) before any quiesce of `CPUIIMR`/`CPUIISR` and
before `register_netdev()`. The bootloader uses this NIC for TFTP and
is not guaranteed to leave the interface masked, so the ISR can run
immediately: `napi_schedule_prep` safely refuses (NAPI still in its
disabled state), but a latched `LINK_CHANGE_IP` would drive
`netif_carrier_on/off` on a **not-yet-registered** netdev. Cheap
hardening: `rtl8196e_hw_disable_irqs()` + W1C `CPUIISR` in probe before
`request_irq` (mirrors what `stop()` already does).

**Resolution (v2.9).** Implemented as recommended.

### ETHDRV-011 — debug timer skips the pool-bounds discipline (info)

`rtl8196e_dbg_timer_fn()` derives `ph`/`rx_ph`/`rx_mb` from raw ring
entries and `dma_cache_inv`s + dereferences them with none of the
`rtl8196e_ptr_in_pool` checks the hot paths apply. A corrupt entry —
precisely the situation in which an operator would enable
`rtl8196e_debug=1` — can oops the debug path that was meant to observe
it. Root-only and off by default; fold into ETH-S02 (retire or harden
the scaffolding) rather than patching in place.

**Resolution (v2.10).** Closed by deletion — the whole scaffolding is
gone with ETH-S02.

### ETHDRV-012 — live MTU change not propagated to hardware (info)

Without an `ndo_change_mtu`, the core accepts any MTU in
`[68, iface.mtu]` and updates `ndev->mtu` only; the NETIF table keeps
the open-time value until the next `open()`. Harmless in practice
(buffers are 1700 B, HW limit 1518 stands), but either propagating the
change or rejecting it while UP (the F2 pattern) would remove the
silent inconsistency.

**Resolution (v2.9).** F2 pattern: `-EBUSY` while UP, accepted while
down (the next `open()` programs the NETIF table from `ndev->mtu` —
verified that is the value `rtl8196e_hw_netif_setup()` consumes).
Bench: `ip link set eth0 mtu 1400` refused UP, accepted down.

---

## 3. Kernel 6.18 simplification / optimization review

| ID | Effort | Gain | Proposal |
|----|--------|------|----------|
| ETH-S01 | medium | correctness of the resource model | `devm_platform_ioremap_resource` the DT `reg` window (today decorative) and route CPU-interface MMIO through `readl/writel` on it; SWCORE (0x1B800000) and the ASIC table window need two extra `reg` entries. Retires the hardcoded-KSEG1 class (F17 / ETH-005 / ETHDRV-006) |
| ETH-S02 | low | −~150 lines, −4 ethtool slots | retire (or gate under a debug Kconfig) the bring-up scaffolding: `dbg_timer`, `tx_debug_once`, `tx_dbg_*` stats, `dbg_irqs`, `rtl8196e_force_trap`. Resolves ETHDRV-011 by deletion |
| ETH-S03 | medium | `open()` drops from >1 s to ms (no longer carries the ETHDRV-007 fix — closed in v2.7) | hoist the one-time SoC bring-up (pinmux, switch-clock toggle with its 650 ms of sleeps, MEMCR, FULL_RST, L2 table clear) from `ndo_open` to probe; `open()` keeps only ring/VLAN/NETIF/L2-entry programming + start |
| ETH-S04 | trivial | hygiene | drop dead defines (`PIN_MUX_SEL`/`PIN_MUX_SEL2`, `TX_ALL_DONE_*`, `PortStatusNWayEnable`), fix the stale Kconfig help figures ("91/44 Mbps" → current 94/73), audit `depends on !RTL819X` (legacy symbol absent from the 6.18 tree) |
| ETH-S05 | low | TX latency under load | BQL (`netdev_sent_queue`/`netdev_completed_queue`) on the single TX queue — standard 6.x practice for soft-reclaim drivers; **bench-gated**, this platform has punished "obvious" wins before (F11/F13/F15) |
| ETH-S06 | trivial | API honesty | drop the never-set `rtl8196e_hw.base` member and decide the `(void)hw` question once (F16): either delete the parameter or keep the handle and remove the casts |
| ETH-S07 | trivial | call-site clarity | `rtl8196e_ring_tx_submit()` `flags` argument is constant at both call sites (`PKTHDR_USED | PKT_OUTGOING`) — fold into the ring layer |

**Implementation status (v2.13, 2026-06-12).** ETH-S05 implemented and
**kept after its bench gate**: BQL on the single TX queue —
`netdev_sent_queue` after a final submit, `netdev_completed_queue` at
the three reclaim sites (xmit-opportunistic, xmit-retry, NAPI),
`netdev_reset_queue` in open()/stop()/tx_timeout next to the ring
resets. Accounting is consistent by construction (both sides count
`skb->len`; the `tx_reclaim_no_skb` anomaly path routes to tx_timeout,
whose reset re-syncs BQL). Gate: RX 94.0 / P4 93.8 / P8 93.9 /
stress-300s 94.1 / TX 69.5 (in spread), UDP profile unchanged; BQL
limit observed converged (~2.5 KB) after load. This was the one
remaining performance idea — landed without the throughput cost the
F11/F13/F15 history warned about. The keep-it rationale (the
~15 ms-ring → ~0.2 ms latency win, the Zigbee/Thread control-traffic
argument, the qdisc-enabler point) and the 5-rep TX median A/B
quantifying the ≤1 % cost are in `PERFORMANCE.md` (v2.13 entry); the
balanced-accounting + reset-pairing correctness rule is `DESIGN.md`
invariant 5 corollary.

**Implementation status (v2.12, 2026-06-12).** ETH-S01 implemented as a
*resource-claim variant*: the DT node declares the three windows
(`cpu-interface` 0x1000, `asic-table` 0x100000 — `type << 16`
selector, `switch-core` 0x8000) and probe claims + maps all three via
`devm_platform_ioremap_resource()`, **failing probe** if any returned
virtual base differs from the compile-time KSEG1 constant — the
constants become an enforced, executable invariant and `/proc/iomem`
is honest (three named windows visible on-target). The full
pointer-routing variant ("route MMIO through readl/writel on the
mapped base") is **rejected with rationale**: on MIPS, ioremap of these
low-512MB windows returns the very same KSEG1 alias, so routing would
only replace foldable `lui+lw/sw` pairs with unfoldable dependent
loads in the `__iram` hot paths (ISR/kick/NAPI) — the exact class of
"obvious" change this platform benched and rejected before
(F11/F13/F15, −47 Mbit/s). This retires the F17 / ETH-005 / ETHDRV-006
hardcoded-KSEG1 class: the addresses are no longer unverified
assumptions. Full iperf gate passed (PERFORMANCE.md v2.12 entry).

**Implementation status (v2.11, 2026-06-12).** ETH-S03 implemented:
`rtl8196e_hw_init()` moved from `ndo_open` to probe (between ring
creation and the ETHDRV-010 quiesce, so nothing FULL_RST latches
survives into `request_irq`). Bench: `open()` measured at ~30 ms
(was >1 s — the 650 ms of bring-up sleeps now run once at probe);
traffic and **nRST RSTACK verified after a down/up flap** — the 0x44
pad write moved to probe with the rest, which is correct because
nothing re-clears pad muxes at runtime since v2.7 (this write *was*
the historical clobberer). Full iperf gate passed (PERFORMANCE.md
v2.11 entry).

**Implementation status (v2.10, 2026-06-12).** ETH-S02, S04, S06 and S07
landed in one batch:

- *S02*: `dbg_timer` + `rtl8196e_dbg_timer_fn`, the `tx_debug_once`
  first-packet capture, the four `tx_dbg_*` ethtool slots, the ISR
  `dbg_irqs` prints and `rtl8196e_force_trap` are gone (−~190 lines
  net). The `rtl8196e_debug` module parameter lost its last consumer
  and is removed too (the ring-level `rx_debug_once`/`rx_debug_bad`
  one-shot prints are self-armed and stay). Six dbg-only ring
  accessors (`last_tx_submit`, `tx_count`, `tx_entry`, `rx_index`,
  `rx_pkthdr_entry`, `rx_mbuf_entry`) orphaned by the deletion are
  removed with it. The `rtl8196e_tx_kicks_*` ethtool stats are NOT
  debug scaffolding (tuning telemetry consumed by the bench script)
  and stay. ETHDRV-011 closed by deletion.
- *S04*: dead defines dropped (`PIN_MUX_SEL`/`PIN_MUX_SEL2`,
  `TX_ALL_DONE_IE_ALL`/`IP_ALL`, `PortStatusNWayEnable`); Kconfig help
  figures fixed to 94/73; `depends on !RTL819X` dropped (symbol does
  not exist in the 6.18 tree).
- *S06*: never-set `rtl8196e_hw.base` member dropped; the `(void)hw`
  casts removed and the `hw` parameter kept — ETH-S01 will route MMIO
  through the handle, so the API shape is the one S01 needs.
- *S07*: `tx_submit` no longer takes `flags`; the constant
  `PKTHDR_USED | PKT_OUTGOING` is owned by the ring layer.

Full iperf gate passed (PERFORMANCE.md v2.10 entry): RX 93.9 / P4
94.0 / P8 93.9 / stress-300s 94.1, TX 70.2 (in the documented
69.3–72.8 layout spread; v2.9 measured at the high edge, see the
variance note there). ethtool stats verified renumbered on-target.

### Considered and rejected

- **devm-converting probe** (`devm_request_irq` + auto-unwind): devm
  releases the IRQ *after* `remove()` has already `free_netdev`d the
  `dev_id`; the manual `free_irq`-before-`free_netdev` ordering is the
  correct one. Keep manual.
- **Per-CPU 64-bit stats (`ndo_get_stats64`)**: UP platform, 100 Mbit
  link; `ndev->stats` rollover horizon is years. Not worth the code.
- **phylib / fixed-link integration**: the four PHYs are internal to
  the switch ASIC and managed through PSRPx/MDIO vendor registers; the
  ethtool shim plus link timer/IRQ is smaller than a custom MDIO bus +
  phylib glue and loses nothing this hardware can express.
- **KSEG1 descriptor pools** (F6), **rearm `wback_inv → inv`** (F13),
  **WRAP-from-index** (F15), **`dma_cache_inv` removal** (F11): all
  hardware-tested and rejected — −1.2 to −47 Mbit/s; bench tables in
  the superseded log. Do not revisit bundled.
- **Gated RX checksum** (ETHDRV-003): three variants benched, all
  regress ≥13 Mbit/s; stays case D (§1.3).
- **Scatter-gather TX**: rejected pre-6.18 (`feat/tx-throughput`
  archive branch, see `SPECIFICATIONS.md` §2).

---

## 4. Finding ID registry (complete)

First-pass audit 2026-04-23 (F-series, driver 2.2→2.3):

| ID | Status | One-liner |
|----|--------|-----------|
| F1 | fixed | tx_timeout now napi_disables around the ring reset |
| F2 | fixed | MAC change refused while UP |
| F3 | fixed | `mdelay` → `msleep` in hw_init (650 ms, process ctx) |
| F4 | fixed | poll-ready loops use `usleep_range` |
| F5 | fixed | RX drop/bad-len paths update rx_errors/rx_dropped |
| F6 | rejected (bench) | KSEG1 descriptor pools: TCP TX −1.2 Mbit/s |
| F7 | fixed | ISR masks before W1C, owned bits only |
| F8 | fixed | sysfs via `attribute_group` |
| F9 | fixed | kick_tx through the MMIO helpers |
| F10 | fixed | table_write aborts on TLU timeout |
| F11/F13/F15 | rejected (bench) | ring micro-opts bundle: −47 Mbit/s RX |
| F12 | fixed | `ph->ph_mbuf` pool-bounds check in rx_poll |
| F14 | fixed | stop() W1Cs latched CPUIISR |
| F16 | intentional | `(void)hw` vestigial API (now ETH-S06) |
| F17 | intentional | KSEG1 virtual addresses in HW DMA registers (now ETH-S01) |

Second pass 2026-05-01 (driver 2.3→2.4): ETH-001 (TX zero-padding,
fixed), ETH-002 (ring resets in stop(), fixed), ETH-003 (= ETHDRV-003),
ETH-004 (BUILD_BUG_ON ABI guards, fixed), ETH-005 (= F17), ETH-006 (DT
port-mask bounds, fixed), ETH-007 (debug params opt-in, intentional),
ETH-008 (= F13, stays rejected).

Third pass 2026-05-03 (driver 2.4→2.5): ETHDRV-001 (syscon
EPROBE_DEFER, fixed), ETHDRV-002 (canonical descriptor rearm, fixed),
**ETHDRV-003 (blanket CHECKSUM_UNNECESSARY — open, accepted case D,
§1.3)**, ETHDRV-004 (BE-bitfield compile guard, mitigated), ETHDRV-005
(0644 debug params, intentional), ETHDRV-006 (= F17).

Issue-#99 synthesis (driver 2.6, no audit pass): shadow-skb lookup by
hardware mbuf index + TX/RX pool-bounds validators + `ethtool -S`
anomaly counters.

This audit 2026-06-12 (driver 2.6, updated for 2.7..2.10): **ETHDRV-007**
(eth/GPIO mux clobber — **closed in v2.7**, gpio-line-names-derived
0x44 write; residual anonymous-claim exposure closed in v2.8 via
`realtek,led-pads`), **ETHDRV-008** (ring-array cache aliasing —
**closed in v2.9**), **ETHDRV-009** (stop() IRQ re-arm race — **closed
in v2.9**), **ETHDRV-010** (probe IRQ window — **closed in v2.9**),
**ETHDRV-011** (debug-timer wild deref — **closed in v2.10**, ETH-S02
deletion), **ETHDRV-012** (live MTU change — **closed in v2.9**, F2
pattern). The v2.9 batch is probe/teardown-only (zero hot-path edits);
v2.10 implements ETH-S02/S04/S06/S07. Both passed the full iperf gate,
figures in `PERFORMANCE.md`.

Cross-references: **GPIO-007** (`drivers/gpio/AUDIT.md`) is the same
defect as ETHDRV-007 seen from the GPIO side; the GPIO audit explicitly
defers the fix to this driver — both close together in v2.7. `rtl8196e_regs.h` CSCR layout notes and
`reference_cscr_layout` derive from the ETHDRV-003 characterisation.

---

## 5. Conclusion

The driver is in its most hardened state since the rewrite: the entire
hardware-facing input surface (descriptors, lengths, pointers) is
validated with counters, the historical info-leak and quiesce races are
fixed and verified in-code, and the one accepted security trade-off
(ETHDRV-003) is documented with its full empirical justification.

**Everything actionable from this audit is now implemented**
(2026-06-12, drivers v2.7 through v2.13, each step behind the full
iperf gate): ETHDRV-007 (v2.7/v2.8), ETHDRV-008/009/010/012 (v2.9),
ETH-S02/S04/S06/S07 + ETHDRV-011 (v2.10), ETH-S03 (v2.11, `open()`
>1 s → ~30 ms), ETH-S01 resource-claim variant (v2.12), ETH-S05 BQL
(v2.13, kept). Remaining open items are deliberate, evidence-backed
deferrals: ETHDRV-003 (accepted case D, §1.3) and the
considered-and-rejected list above — every rejection carries its bench
figures.
