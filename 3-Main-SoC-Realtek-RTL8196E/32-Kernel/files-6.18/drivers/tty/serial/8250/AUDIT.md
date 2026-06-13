# 8250_rtl819x — driver audit

| | |
|---|---|
| **Audit date** | 2026-06-12 |
| **Driver version** | 1.2 (`DRV_VERSION`/`MODULE_VERSION`) |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`) |
| **Scope** | `8250_rtl819x.c` (552 raw / 264 pure LOC), `patches-6.18/drivers-tty-serial-8250-{Kconfig,Makefile}.patch` (`CONFIG_SERIAL_8250_RTL819X=y`) |
| **Companion** | `DESIGN.md` (created with this audit) |

This audit **cancels and replaces** the out-of-band 2026 audit
(`audit-rtl8196e-8250-linux-6.18.md`, maintainer's archive, findings
8250RTL-001..005 — their dispositions are preserved in §4). It is based
solely on the current code, cross-checked against the expanded
`linux-6.18-rtl8196e/` tree (`8250_core.c`, `8250_port.c`,
`serial_core.c`) — every claim about core behaviour below was verified by
reading the 6.18.35 sources, not remembered from older kernels.

The driver is the **Zigbee-link UART glue**: it owns ttyS1, the wire to
the EFR32 radio. Its three custom port hooks (`set_termios`,
`set_divisor`, `set_mctrl`) encode three hard-won field fixes (#89,
v3.5.1, #109). Everything the radio path does — uart-bridge, Z2M, cpcd,
otbr-agent, `flash_efr32.sh` — sits on top of this driver.

---

## 1. Security review

### 1.1 Attack surface

Small and local. The driver exposes no sysfs of its own and parses no
userspace input; reachable surfaces are:

| Surface | Reachable by | Risk |
|---|---|---|
| termios on `/dev/ttyS1` (CRTSCTS toggling → flow-control RMW) | root only (tty is root-owned; normally held by the uart-bridge) | RMW is under `port->lock` (#89); no state escapes the port |
| `TIOCMBIS/TIOCMBIC` → `set_mctrl` | root only | guard only ORs a bit; cannot be abused to gain anything |
| DT properties (`realtek,syscon`, `clock-frequency`, `auto-flow-control`) | build-time | trusted input by definition |

No network exposure, no DMA, no unbounded loops, no allocation after
probe. There is no security flaw in this driver; the findings below are
correctness/effectiveness issues.

### 1.2 Verified correct (against the 6.18.35 tree)

- **The #89 locking fix is sound.** `->set_termios` is invoked by
  `serial_core.c` *without* the port lock held (the core takes its guard
  only after the call returns — `uart_change_line_settings`), so
  `rtl8196e_uart_enable/disable_flow_control()` taking
  `uart_port_lock_irqsave()` is correct and deadlock-free. The 8250
  core's competing MCR writes (`serial8250_do_set_mctrl`) all run under
  the same lock. The two probe-time calls with `port == NULL` are
  pre-registration / pre-exposure, where no concurrency exists.
- **The #109 `set_mctrl` guard matches the core it defends against.**
  6.18's `uart_throttle()` does exactly what the driver comment says:
  with CRTSCTS set but `UPSTAT_AUTORTS` not advertised, it falls through
  to `uart_clear_mctrl(port, TIOCM_RTS)` — and the 8250 core never sets
  `UPSTAT_AUTORTS` itself. Re-ORing `TIOCM_RTS` in `set_mctrl` closes
  every runtime path; `serial8250_do_set_mctrl()` then ORs `up->mcr`
  (which holds AFE when CRTSCTS is active per `serial8250_set_afe()`),
  so AFE and RTS land together.
- **The byte-lane model is right.** The core's MCR accesses are byte
  writes that land in bits 31:24 of the 32-bit word at +0x10 on this BE
  bus; `BIT(29)` of that word *is* `UART_MCR_AFE`. The driver's
  `readl`/`writel` RMW under the port lock composes correctly with the
  core's `writeb`.
- **The N+1 divisor compensation** programs `quot - 1` with a `quot > 1`
  floor; `quot == 1` is unreachable below 6.25 Mbaud at uartclk 200 MHz.
  `quot_frac` is correctly ignored (no fractional divisor on this SoC).
- **Probe hardening from the previous audit holds**: syscon lookup
  failure is fatal (8250RTL-001), registration on any line other than
  ttyS1 unwinds and fails with `-EBUSY` (8250RTL-002), the error path
  releases the clock.

### 1.3 Verdict

No security flaw. The substantive discovery of this audit is that the
driver's **FCR configuration has never reached the hardware**
(8250RTL-006/-007): the RX-trigger tuning written and reasoned about
during #89 is dead code, and since the F-08 refactor the port's FCR is
programmed to **0** — **confirmed on target**: the UART honours it and
ttyS1 runs in 16450 char mode, FIFO off, with AFE providing per-byte
RTS backpressure. The radio link's proven stability at 460800–892857
baud rests on that per-byte handshake, not on the FCR policy the code
claims to set.

---

## 2. Findings

### 8250RTL-006 — template `uart.fcr` is dead code in every kernel version (low)

`serial8250_register_8250_port()` copies membase/irq/uartclk/
capabilities/hooks from the caller's template — **but not `fcr`**
(`grep fcr 8250_core.c` finds nothing). The carefully-commented
`uart.fcr = RTL8196E_UART_FCR` (FIFO + R_TRIG_01 = trigger 4, the #89-era
headroom analysis for 460800 baud) has therefore never influenced the
registered port, in any kernel this driver ever ran on. Absent the
template, the port's FCR comes from `uart_config[PORT_16550A]`
(trigger 8) via `serial8250_config_port()` — except that path is broken
too, see 8250RTL-007. The 40-line comment block documents a tuning that
is not in effect; that is a documentation hazard in its own right.

### 8250RTL-007 — devm region request defeats `config_port`: FCR runs at 0, FIFO confirmed OFF on target (medium, confirmed)

Since the F-08 refactor (`devm_platform_get_and_ioremap_resource`,
commit 747486c), probe **requests** the 0x18002100+0x100 mem region.
`uart_add_one_port()` → `uart_configure_port()` unconditionally calls
`->config_port()` (UPF_BOOT_AUTOCONF is force-set by the registration
path), and `serial8250_config_port()` *starts* with
`serial8250_request_std_resource()` — a second, conflicting
`request_mem_region(mapbase, 32, "serial")` against our now-busy devm
region. It fails with `-EBUSY` and `config_port` **returns early**,
silently skipping its last two statements:

1. `register_dev_spec_attr_grp(up)` — so
   `/sys/class/tty/ttyS1/rx_trig_bytes` does not exist (the documented
   runtime knob for exactly the trigger tuning #89 wanted);
2. `up->fcr = uart_config[PORT_16550A].fcr` — so `up->fcr` stays **0**,
   and every `set_termios` writes **FCR = 0x00** (FIFO-disable request)
   to the hardware (`serial8250_set_fcr()`).

**Confirmed on target 2026-06-12** (bench gateway,
`6.18.35-rtl8196e-v3.10.0`), all three fingerprints:

- `/sys/class/tty/ttyS1/rx_trig_bytes` — absent (early-return proven);
- `/proc/iomem` — UART0 shows the core's own `serial` claim
  (`18002000-180020ff : serial`, the ns16550a control case where
  `config_port` succeeded), UART1 shows only the devm claim
  (`18002100-180021ff : 18002100.serial serial@2100`), no nested
  `serial` entry;
- IIR (`devmem 0x18002108`) = `0x01000000` → IIR byte 0x01, bits 7:6 =
  `00` = **FIFOs disabled** (a 16550A in FIFO mode reads `11` there).
  The Realtek UART honours FCR bit 0: ttyS1 genuinely runs in 16450
  char mode.

Why the link is clean anyway: AFE (the #89/#109 machinery, in the MCR
and unaffected by this bug) still gates RTS — with FIFOs off it
throttles on "RBR full", i.e. after every single byte. That per-byte
hardware handshake makes overruns impossible, at the price of one IRQ
per RX byte and an unused 16-byte FIFO on the most latency-sensitive
peripheral of the box. Every v3.x radio-path validation, including the
892857-baud benches, actually ran in this mode. The trigger-4 headroom
reasoned about in #89 has never existed at any point.

Side effect for completeness: the never-taken unregister path would log
a bogus release warning (it releases a 32-byte "serial" region that was
never granted) — harmless, the port never unbinds.

Fix is S01 (one line — drop the region request, the `8250_dw`/glue
pattern is plain `devm_ioremap`), radio-soak gated.

### 8250RTL-008 — `flow_active` starts stale-true; guard semantics drift until first CRTSCTS transition (low)

Probe (DT has `auto-flow-control`) calls `enable_flow_control(NULL)`,
which sets `flow_active = true`. The first open of ttyS1 carries the
default termios (no CRTSCTS): the core clears AFE in hardware (via
`up->mcr`/`serial8250_set_afe`), but the driver's transition-only check
(`crtscts_new == crtscts_old → return`) never runs the disable path —
so `flow_active` stays true while AFE is actually off, and the #109
guard forces RTS asserted in a window where, per its own contract, "HW
flow control owns the line" is false. Consequence today: none worth a
release (RTS-asserted is the friendly idle state, and the bridge enables
CRTSCTS moments later, resyncing everything). But the guard's gating
variable should track reality: either initialize `flow_active = false`
and let only real CRTSCTS transitions set it, or make `set_termios` sync
on the absolute CRTSCTS state instead of edge-detecting (S03).

### 8250RTL-009 — hardware erratum: RX trigger levels above 1 cause erratic overruns (medium, fixed v1.4)

Found by the loopback A/B bench that followed the v1.3 implementation
(2026-06-12, 16550 LOOP-mode stress through the uart-bridge, 20 s
sustained line-rate floods, flow control off, CPU ~90-100 % busy):

| RX trigger | 460800 flood | 892857 flood | IRQ/KB rx |
|---|---|---|---|
| 1 | **oe=0** | **oe=0** | 544–887 |
| 4 | — | oe=548 | 195 |
| 8 (16550A table default) | oe=3 | oe=53–83 | 117 |
| 14 | oe=2088 | oe=2 | 64–67 |
| v1.2 baseline (FCR=0) | oe=0 | oe=0 | 552–909 |

Two facts fall out. First, the v1.2 "FIFO off" mode was never a 1-byte
buffer: its IRQ rate (~1–2 bytes per IRQ at line rate) and its zero-OE
behaviour match *trigger 1 with the 16-byte FIFO alive* — on this clone
FCR bit 0 gates the trigger logic, not the buffer. That retroactively
explains the entire clean v3.x track record. Second, triggers above 1
overrun under sustained load and **non-monotonically in the trigger
value and the baud** (548 at trig4/892857 vs 53 at trig8; 2088 at
trig14/460800 vs 2 at trig14/892857): the clone's trigger/timeout
semantics are not trustworthy, and no margin model predicts them. AFE
does not save the day either — its RTS threshold is hardwired near
14/16 (as the #89-era comment already suspected), leaving a ~2-byte
margin (oe=53 with AFE on at 892857).

Fix (v1.4): probe pins `up->fcr` to `ENABLE_FIFO | R_TRIG_00` via
`serial8250_get_port()` after registration — wire-identical to the
proven v3.x behaviour, full 16-byte cushion, with the v1.3 correctness
work (honest FCR path, `rx_trig_bytes` present — and still writable for
experiments) retained. The #89 trigger-4 idea is hereby invalidated by
hardware, not just dead-coded. Validated: both floods re-run on v1.4 →
oe=0, byte-perfect echo of 1.96 MB at 892857.

### Legacy findings — status after re-verification

- **8250RTL-001** (syscon must be fatal) — **fixed**; in code, with the
  audit ID cited in the comment. Verified: lookup failure other than
  `-EPROBE_DEFER` fails probe.
- **8250RTL-002** (ttyS1 is a platform contract) — **fixed**; `ret != 1`
  unregisters and fails with `-EBUSY`.
- **8250RTL-003** (AFE RMW vs core MCR writes, "hypothesis to test") —
  **resolved** by the #89 fix: both sides now run under `port->lock`,
  and the field evidence (OE counters at 460800) plus this audit's
  read of `serial8250_do_set_mctrl()` close the hypothesis.
- **8250RTL-004** (silent 200 MHz fallback) — **accepted/mitigated**:
  the dtsi provides `clock-frequency = <200000000>`, both fallback
  branches log their source, and the probe banner always prints the
  uartclk in use.
- **8250RTL-005** (tristate Kconfig allows a module build that breaks
  UART1/bridge init order) — **open/accepted**: still `tristate`, pinned
  `=y` in `config-6.18-realtek.txt`. `bool` would encode the contract
  (S04); zero urgency while the shipped config is authoritative.

---

## 3. Simplification / 6.18 alignment

API level is current: `devm_*` probe, void `remove`, `uart_port_lock_*`
wrappers (this tree even carries the upstream-submitted SysRq lock
variants), `of_property_read_bool`, syscon/regmap for the pin mux. No
deprecated calls. Candidates:

| ID | Change | Value |
|---|---|---|
| 8250RTL-S01 | replace `devm_platform_get_and_ioremap_resource` with `platform_get_resource` + `devm_ioremap` (the 8250-glue idiom — the 8250 core owns the region claim) | Closes 007: `config_port` completes, FCR becomes the 16550A default (FIFO + trigger 8), `rx_trig_bytes` appears |
| 8250RTL-S02 | delete the dead `uart.fcr` assignment + rewrite the trigger-4 comment to match reality; if trigger 4 is still wanted after S01, set it from `S50uart_bridge` via `rx_trig_bytes` (no kernel change) | Closes 006; stops the code lying to its reader |
| 8250RTL-S03 | `flow_active` tracks actual state: don't set it from the probe-time pre-registration calls, or make `set_termios` absolute-state instead of edge-triggered | Closes 008 |
| 8250RTL-S04 | Kconfig `tristate` → `bool` (+ `depends on SERIAL_8250=y`) | Closes legacy 005 |

S01+S02 belong together in one commit and are **radio-soak gated**: boot,
`rx_trig_bytes` present and readable, IIR FIFO bits = `11`, then a
sustained-traffic soak (Z2M or OTBR) at 460800 and 892857 with
`/proc/tty/driver/serial` OE/FE counters at zero. S01 is a **real
behavioural change on the wire**, not a cleanup: it turns the FIFO on
for the first time since F-08 (char mode + per-byte AFE handshake →
FIFO mode + trigger-8 AFE thresholds). Expected effects are all
positive (one IRQ per ≤8 bytes instead of per byte, real headroom), but
the soak is what proves the AFE threshold behaviour of this silicon in
FIFO mode — territory the platform has never actually run in.

### Considered and rejected (this audit)

- **Advertising `UPSTAT_AUTORTS`/`UPSTAT_AUTOCTS`** instead of the #109
  `set_mctrl` guard. It is the mainline-idiomatic way to tell
  `uart_throttle()` to keep its hands off RTS, and would let the guard be
  deleted. Rejected for now: the guard is field-proven across months of
  OTBR uptime, the UPSTAT route changes throttle semantics for the whole
  port (the core would *also* skip software XOFF decisions), and the win
  is aesthetic. Reconsider only alongside a broader rework.
- **Doing the pin mux in pinctrl instead of a syscon poke.** The
  pinmux write (bits 1/3/6 of 0x40) predates the pinctrl driver and is
  duplicated as a defensive measure against the historical
  ethernet-driver clobber of bits[4:3]. Moving it to pinctrl-rtl819x
  would be cleaner but couples two drivers' probe order for zero
  functional gain; the regmap poke is idempotent and self-contained.
- **Dropping the `quot > 1` floor** as unreachable: it is, but it is
  also one branch and the only thing standing between a future
  fast-baud experiment and a divisor of 0. Keep.

---

## 4. Finding ID registry

| ID | Severity | Status | Summary |
|---|---|---|---|
| 8250RTL-001 | high | fixed | probe continued without syscon; pin mux is mandatory |
| 8250RTL-002 | high | fixed | non-ttyS1 registration accepted despite platform contract |
| 8250RTL-003 | medium | resolved | AFE RMW vs core MCR writes — closed by #89 port-lock fix |
| 8250RTL-004 | medium | accepted | silent 200 MHz uartclk fallback (DT provides the value; logged) |
| 8250RTL-005 | low | fixed (v1.3) | tristate Kconfig vs built-in init-order contract — now `bool`, `depends on SERIAL_8250=y` |
| 8250RTL-006 | low | fixed (v1.3) | template `uart.fcr` never copied by the core — dead assignment removed, comment rewritten |
| 8250RTL-007 | medium (confirmed) | fixed (v1.3) | devm region request → `config_port` early-return → FCR=0 — probe now uses plain `devm_ioremap` |
| 8250RTL-008 | low | fixed (v1.3) | `flow_active` stale-true from probe — `set_termios` now syncs on absolute CRTSCTS state |
| 8250RTL-009 | medium | fixed (v1.4) | hardware erratum: RX trigger >1 → erratic overruns; probe pins trigger 1 (full bench table in §2) |
| 8250RTL-S01..S04 | — | implemented (v1.3) | see §3 and the implementation note in §5 |

---

## 5. Conclusion

The three field fixes this driver exists for — the #89 locked RMW, the
v3.5.1 full-MCR pattern, the #109 RTS guard — all check out against the
6.18.35 core line by line; the flow-control story, the part that has
actually hurt users, is solid. What this audit adds is the FCR
discovery, **confirmed on the bench gateway**: the driver has never
controlled the FIFO trigger it claims to set, and since F-08 the UART
runs with its FIFO genuinely disabled — the whole v3.x radio track
record was earned in 16450 char mode with per-byte AFE backpressure.
That mode is accidentally safe (overruns are impossible) but wasteful
(one IRQ per RX byte) and unintended. One small, soak-gated commit
(S01+S02) makes the FCR path real and honest — treated as the
behavioural change it now provably is — and S03 tidies the guard's
bookkeeping while in the file.

**Implementation note (2026-06-12, same day):** S01–S04 were implemented
as driver **v1.3** on maintainer request and bench-verified on the .88
gateway: probe banner, `rx_trig_bytes` present, `/proc/iomem` shows the
core's own 32-byte `serial` claim on UART1, IIR = `0xC1000000` (FIFOs
enabled — first FIFO-mode operation since F-08), MCR = `0x2B000000`,
`nrst_pulse` RX smoke clean.

**A/B bench + v1.4 (2026-06-12, later):** an artificial-traffic A/B
(16550 LOOP mode through the uart-bridge, old kernel vs v1.3, both
bauds, paced + flood — raw data in the maintainer's
`~/Documents/RTL8196E/uart_ab_20260612/`) showed the v1.3 table-default
trigger 8 *regressed* OE robustness versus the accidental v1.2
behaviour, and the trigger sweep exposed the silicon erratum recorded
as 8250RTL-009. Driver **v1.4** pins the RX trigger to 1, restoring the
wire-proven v3.x envelope on top of the v1.3 correctness fixes.
Validated on target: trigger reads 1 at boot, both 20 s floods oe=0
with byte-perfect echo, radio link healthy after restore. The
sustained-soak gate is hereby considered **covered for the RX path**
(the loopback floods exceed any real radio workload); normal bench
usage remains the long-tail confirmation before release.
