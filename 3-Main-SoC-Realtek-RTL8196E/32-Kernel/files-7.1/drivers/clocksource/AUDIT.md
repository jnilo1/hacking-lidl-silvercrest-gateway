# RTL819x timer driver (`timer-rtl819x`) — security & code audit

| | |
|---|---|
| **Audit date** | 2026-06-11 |
| **Driver version** | **1.0** (`DRV_VERSION` in `timer-rtl819x.c` — never bumped since the v3.4.0 baseline; the TMR-005 `min_delta` edit and the Timer0 quiesce rework rode later releases without a version change) |
| **Active release** | **v3.10.0** (kernel `6.18.35-rtl8196e-v3.10.0`) |
| **Audited artifacts** | `timer-rtl819x.c` (this directory); DT nodes `timer@3100`, `slowclk`, `busclk` (`rtl819x.dtsi`); `patches-6.18/drivers-clocksource-{Kconfig,Makefile}.patch`; timer-related kernel config (`CONFIG_CLKSRC_RTL819X=y`, `HZ=250`, `HIGH_RES_TIMERS=y`) |

This audit **supersedes and replaces** the previous `AUDIT.md`
(2026-05-01, pre-v3.5.0). It is a fresh audit of the code as it stands
today. Legacy finding IDs TMR-001…TMR-005 are preserved in the registry at
the end (TMR-005 is referenced from `drivers/watchdog/DESIGN.md` and the
slowclk DT comment chain); their fixes were all re-verified present in the
current source rather than taken on faith.

Audit questions, per the project audit charter:

1. **Security** — does the driver introduce exploitable flaws?
2. **Simplification / optimization** — can the code be simplified or
   optimized for the Linux 6.18 APIs it targets?

---

## 1. Security audit

### 1.1 Attack surface

There is none. The driver:

- exposes **no device node, no sysfs attribute, no module parameter, no
  ioctl, no procfs entry** — its only interfaces are the in-kernel
  clocksource/clockevent/sched_clock registrations;
- parses **no input** at runtime — every value it consumes comes from the
  DT (trusted, built into the kernel image) at `__init` time;
- is **built-in only** (`TIMER_OF_DECLARE`, `CONFIG_CLKSRC_RTL819X=y`) —
  no module load/unload surface, no `.remove` path;
- performs MMIO exclusively through `readl`/`writel` on 32-bit-aligned
  offsets within its own mapped window — no buffers, no DMA, no copies.

Root can corrupt timekeeping via `devmem` on the timer registers, but that
is an SoC property, not a driver one, and root already owns the kernel.

**No trust boundary is crossed anywhere in this driver.**

### 1.2 Integrity properties re-verified (current code)

The security-adjacent value of this driver is *availability and
correctness of system time* — the platform has no usable CP0 `Count`, so
this is the **only** timekeeping source. The historical hardening was
re-checked line-by-line:

- **IRQ-before-exposure ordering (TMR-002)** — still correct: Timer0 is
  quiesced (TC0_EN off, stale `TC0_PENDING` W1C-cleared, IR masked), then
  `request_irq()`, then `clockevents_config_and_register()`. On this
  platform CPU IP7 is level-triggered and dedicated to Timer0, so an
  unhandled assertion is an interrupt storm, not a lost edge — the
  ordering is load-bearing. Verified present.
- **Spurious-IRQ discipline (TMR-003)** — handler reads IR first, returns
  `IRQ_NONE` when `TC0_PENDING` is clear, acks via W1C otherwise.
  Verified present.
- **Divider validation (TMR-001)** — `busclk` enable checked with a
  200 MHz fallback; `panic()` on `timer_rate > bus_rate`, on
  `div_fac == 0`, and on `div_fac > 0xffff` (CDBR field width). With the
  production DT (`200 MHz / 25 kHz = 8000`) all guards are dead code, as
  intended. Verified present.
- **Registration error propagation (TMR-004)** — `clocksource_register_hz()`
  checked; `sched_clock_register()` only runs after success. Verified
  present.
- **Concurrency** — `set_next_event` / state callbacks RMW the shared
  CTRL register, but every caller runs with IRQs disabled on this UP
  machine, and no other code writes CTRL/IR (the watchdog lives at
  0x311C, outside the registers this driver touches). No race.

### 1.3 Security verdict

**No vulnerability found, by construction.** The driver has zero
unprivileged surface and parses no untrusted input. The items below are
robustness/hygiene, not security.

---

## 2. New findings (this audit)

| ID | Type | Severity | One-liner |
|----|------|----------|-----------|
| TMR-006 | ROBUSTNESS / CONSISTENCY | low | inconsistent init-failure policy: IRQ-map failure soft-fails (`pr_err` + `-EINVAL`, dangling global base) while every other failure panics — the soft path yields a later, far less diagnosable hang |
| TMR-007 | HYGIENE | info | `clk_put()` while the clock is still prepared/enabled (refclk and busclk both) — safe with DT fixed-clocks, but formally a use-after-put pattern |
| TMR-008 | CONSISTENCY / PORTABILITY | info | compatible is family-generic (`realtek,rtl819x-timer`) while the project convention (WDT-003, GPIO-003) is per-SoC tightening — acceptable (the timer block is SDK-common across the family), recorded as a deliberate exception |
| TMR-009 | LATENT / DT | low | the `timer@3100` `reg` window (`0x3100 0x20`) **overlaps the watchdog register** at 0x311C, which `watchdog@311c` claims via `devm_ioremap_resource()` — harmless today only because this driver maps without claiming |

### TMR-006 — harmonize the init-failure policy

`rtl819x_timer_init()` panics on every failure (resource, ioremap, clk,
divider, clocksource, request_irq) **except** `irq_of_parse_and_map()`
failure, which prints and returns `-EINVAL`. `timer_probe()` merely
tallies that error, so the boot continues into a system with a
clocksource but **no clockevent** — it hangs later in scheduler bring-up
with no pointer back to the cause. For the platform's only timer, panic
*is* the honest policy (that is why the other eight paths use it).

The soft path also leaves `rtl819x_timer_base` pointing at an iounmap'd
mapping — irrelevant once the system is doomed, but sloppy.

**Recommendation.** Make the IRQ-map failure panic like its siblings
(one line), or convert all paths to `pr_err` + cleanup + error return if
boot-without-timer ever becomes meaningful. The former matches reality.

### TMR-007 — clk reference dropped while enabled

Both `clk` (slowclk) and `busclk` are `clk_prepare_enable()`d and then
`clk_put()` immediately, with a comment acknowledging the trade
("timer runs forever, but release the reference"). With DT fixed-clocks
the provider is never unregistered, so this cannot bite on this platform.
Still, the canonical timer-driver pattern is to simply hold the reference
forever (these are `__init`-acquired, never released anyway). Dropping
the two `clk_put()` calls would make the code pattern-correct at zero
cost. Optional; fold into the next functional change.

### TMR-008 — generic compatible: deliberate exception, now recorded

`realtek,rtl819x-timer` matches any family member; the watchdog and GPIO
drivers deliberately narrowed theirs to `rtl8196e`. The timer/CDBR block
layout is common across the RTL819x SDK family, the multi-board DT
generalization (v3.10.0) benefits from the generic match, and narrowing
now would churn every board DTS for zero behavior change. **Decision:
keep generic.** This finding exists so the inconsistency is documented as
intentional rather than rediscovered by every future audit.

### TMR-009 — DT reg overlap with the watchdog node

`timer@3100` declares `reg = <0x3100 0x20>` (0x3100–0x311F) but the
driver uses offsets 0x00–0x1B only; 0x311C is **WDTCNR**, owned by
`watchdog@311c` (`reg = <0x311c 0x4>`). The two nodes' windows overlap.
Nothing fails today because this driver maps via plain `ioremap()`
(no `request_mem_region`), while the watchdog's
`devm_ioremap_resource()` is the only claimer. The hazard is latent: if
this driver is ever converted to a region-claiming accessor — or a
generic DT validator starts flagging overlapping `reg` ranges — probe
breaks in a non-obvious way.

**Recommendation.** Shrink the timer node to `reg = <0x3100 0x1c>`
(covers DATA0…CLOCK_DIV inclusive). One-character DT change, no driver
edit, removes the overlap permanently.

---

## 3. Simplification & optimization for kernel 6.18

The driver is small (~400 lines incl. comments) and the hot paths are
already minimal: the clocksource read is one uncached `readl` + a shift;
`set_next_event` is two reads + three writes at ~270 calls/s. There is no
performance problem to solve. Simplification candidates:

| ID | Item | Gain |
|----|------|------|
| TMR-S01 | Convert to the `timer_of` framework (`struct timer_of` + `TIMER_OF_BASE\|_CLOCK\|_IRQ`): replaces the hand-rolled resource/irq/clk parsing, the global `rtl819x_timer_base`, and the error paths with the canonical 6.x idiom used by most in-tree TIMER_OF drivers | −60…80 lines of init boilerplate; subsumes TMR-006's cleanup; `timer_of` maps via `of_iomap` so TMR-009 stays benign. *This is the one structurally worthwhile modernization* — but it is churn on a proven init path; schedule it with hardware re-validation, not as a drive-by |
| TMR-S02 | (If not doing S01) `rtl819x_timer_base = of_iomap(np, 0);` replaces the `of_address_to_resource()` + `ioremap()` pair | −6 lines |
| TMR-S03 | `IS_ERR(clk)` instead of `IS_ERR_OR_NULL(clk)` — `of_clk_get()` never returns NULL; the `_OR_NULL` variant masks API misunderstanding | 1-line correctness-of-intent |
| TMR-S04 | Drop unused includes: `<linux/reset.h>` (no reset_control call), `<linux/time.h>`, `<linux/clk-provider.h>` (consumer-only driver — `<linux/clk.h>` suffices) | verify with a build, then −3 lines |
| TMR-S05 | Drop the `#ifndef CONFIG_CPU_FREQ` guard around `sched_clock_register()` and the `__maybe_unused` — this platform cannot have cpufreq (fixed-clock Lexra, no driver exists) and the config never enables it; the conditional suggests a variability that does not exist | −3 lines, removes a misleading guard |
| TMR-S06 | Fold the duplicated MHz/kHz banner branches into one format (or print Hz) | −6 lines, cosmetic |

**Optimizations considered and rejected** (recorded so they are not
re-litigated):

- *`clocksource_mmio_init()`* — unusable: the COUNT1 value needs the
  `>> 4` adjustment (28-bit count lives in bits [31:4]), which the
  generic mmio read helpers cannot express. The custom 3-line read stays.
- *Shadowing CTRL to skip the read in `set_next_event`* — saves one
  uncached read per tick (~270/s); the readback also tolerates any future
  writer of CTRL. Negligible gain, small robustness loss. No.
- *`CLOCK_EVT_FEAT_PERIODIC`* — pointless: with `HIGH_RES_TIMERS=y` +
  `NO_HZ_IDLE` the core drives oneshot exclusively, and periodic mode
  would only add an untested code path.

None of the S-items changes behavior; TMR-S02…S06 are safe to batch with
any future functional commit (with a `DRV_VERSION` bump this time —
see the header note: the driver has silently absorbed two post-1.0
functional edits already). TMR-S01 deserves its own release and bench
pass.

---

## 4. Finding ID registry (complete)

Details of TMR-001…TMR-005 live in this repo's git history
(pre-v3.10.0 AUDIT.md). All five were re-verified present in the current
source during this audit.

| ID | Status | One-liner |
|----|--------|-----------|
| TMR-001 | closed (v3.4.0) | divider validated (0 < div ≤ 0xffff), busclk enable checked with 200 MHz fallback |
| TMR-002 | closed (v3.4.0) | Timer0 quiesced + `request_irq()` before `clockevents_config_and_register()` (IP7 storm prevention) |
| TMR-003 | closed (v3.4.0) | handler returns `IRQ_NONE` when `TC0_PENDING` clear |
| TMR-004 | closed (v3.4.0) | `clocksource_register_hz()` return propagated |
| TMR-005 | closed (v3.4.2) | slowclk CDBR rework: DivFactor 8 → 8000, 25 kHz regime, `min_delta` 0x300 → 8; the clocksource side of the watchdog WDT-005 closure |
| TMR-006 | **fixed (v1.1, 2026-06-12)** | inconsistent init-failure policy (§2) — IRQ-map failure now panics like its siblings |
| TMR-007 | fixed (v1.1, 2026-06-12) | `clk_put()` while enabled (§2) — both references now held forever |
| TMR-008 | closed — documented exception | generic family compatible kept deliberately (§2) |
| TMR-009 | **fixed (v1.1, 2026-06-12)** | DT reg overlap with `watchdog@311c` — node shrunk to `0x1c` with in-DT comment |
| TMR-S01 | implemented (v1.2, 2026-06-12) | `timer_of` conversion — done as its own pass with the serial console connected, per the §3 gate |
| TMR-S02…S06 | implemented (v1.1, 2026-06-12) | `of_iomap`, `IS_ERR`, includes pruned, CPU_FREQ guard dropped, single Hz banner |

---

## 5. Conclusion

No security findings — the driver has no attack surface by construction,
and the availability/correctness hardening from the v3.4.x cycle is all
still in place. The two items worth scheduling are cheap:
**TMR-006** (one-line panic for the inconsistent soft-fail path) and
**TMR-009** (one-character DT shrink that removes a latent reg overlap
with the watchdog). The structural modernization (**TMR-S01**, `timer_of`)
is real but optional, and should ride its own release with hardware
re-validation. Whatever lands first should finally bump `DRV_VERSION`
past 1.0.

**Implementation note (2026-06-12):** TMR-006, TMR-007, TMR-009 and
TMR-S02…S06 implemented as driver **v1.1** on maintainer request
(`DRV_VERSION` finally bumped, closing the header's complaint about
silent post-1.0 edits). TMR-S01 (`timer_of` conversion) was then done
the same day as **v1.2**, as its own pass with the serial console
connected (the audit's gating condition). `timer_of` now owns base
(plain `of_iomap`, no claim — TMR-009 invariant kept), refclk
(by name, rate-validated) and the IRQ; the busclk/divider block stays
hand-rolled (timer_of handles one clock). One deliberate semantic
shift, documented in the code: `request_irq()` now runs inside
`timer_of_init()` *before* the Timer0 quiesce, relaxing the v3.4.0
TMR-002 ordering — safe because the TMR-003-hardened handler W1C-acks a
stale pending and tolerates a NULL event_handler, so the worst case is
one self-contained interrupt at unmask. v1.2 bench: clean boot, banner
identical math (mult 107374 / shift 32, 25000 Hz), `/proc/interrupts`
IRQ 7 now labelled `timer@3100` (np->full_name, cosmetic), sleep 20 =
20.02 s vs host wall-clock, hrtimer resolution 1 ns. Bench-verified on the .88 gateway: clean boot, clocksource
selected, banner `v1.1 … CLK:25000 Hz`, hrtimer resolution 1 ns,
`sleep 20` measured 20.03 s by the gateway's own clocksource and
consistent with the host wall-clock, `/dev/watchdog` present after the
TMR-009 reg shrink.