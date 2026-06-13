# RTL819x timer driver (`timer-rtl819x`) — design

| | |
|---|---|
| **Document date** | 2026-06-11 |
| **Driver version** | 1.2 (`DRV_VERSION` in `timer-rtl819x.c`) |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`) |

Architecture reference for the platform's timekeeping driver. Findings
and audit history live in `AUDIT.md` (this directory).

---

## 1. Why this driver carries the whole platform

The Lexra RLX4181 core has **no usable CP0 `Count` register** — the
stock MIPS clocksource/clockevent (`csrc-r4k`) cannot work here. This
driver is therefore the *only* source of:

- the **clocksource** (monotonic time, `ktime_*`, timestamps),
- the **clockevent** (the scheduler tick, hrtimers, NOHZ wakeups),
- **`sched_clock()`** (printk timestamps, scheduler accounting,
  perf/ftrace timing).

If it fails to initialize, the kernel has no time and no tick — which is
why init failures `panic()` with explicit messages rather than limping on
(see TMR-006 in AUDIT.md for the one inconsistent path).

## 2. Hardware model

The timer block lives at `sysc + 0x3100` and provides two 28-bit
timer/counters plus a shared clock divider:

| Offset | Register | Used as |
|---|---|---|
| 0x00 | `DATA0` | Timer0 terminal count (clockevent delta) |
| 0x04 | `DATA1` | Timer1 terminal count (set to max: free-run) |
| 0x08 | `COUNT0` | Timer0 current count (unused) |
| 0x0C | `COUNT1` | Timer1 current count (**clocksource read**) |
| 0x10 | `CTRL` | `TC0_EN`[31] `TC0_MODE`[30] `TC1_EN`[29] `TC1_MODE`[28] |
| 0x14 | `IR` | `TC0_IE`[31] `TC1_IE`[30] `TC0_PENDING`[29] (W1C) `TC1_PENDING`[28] (W1C) |
| 0x18 | `CLOCK_DIV` (CDBR) | DivFactor in [31:16] — **shared with the watchdog** |

Two quirks shape the code:

- **28-bit values live in bits [31:4]** of DATA/COUNT. Hence
  `RTLADJ_TICK(x) = x >> 4` on every read and `delta << 4` on every
  write. This is also why the generic `clocksource_mmio` helpers can't
  be used.
- **CDBR is not ours alone.** `tick = busclk / DivFactor` feeds Timer0,
  Timer1 *and* the on-chip watchdog (WDTCNR at 0x311C, next door).
  Changing the divider rescales all three at once — the entire 25 kHz
  regime (§4) exists because of this coupling.

## 3. Architecture

```
                 kernel timekeeping            scheduler tick / hrtimers
                        ▲                                ▲
            clocksource_register_hz()        clockevents_config_and_register()
            sched_clock_register()                       │ set_next_event /
                        │ .read                          │ set_state_*
              ┌─────────┴──────────┐          ┌──────────┴──────────┐
              │ Timer1: free-run   │          │ Timer0: one-shot    │
              │ COUNT1 >> 4        │          │ DATA0 = delta << 4  │
              │ (counter to max,   │          │ disable→load→enable │
              │  wraps ~3 h)       │          │ IRQ on terminal cnt │
              └─────────┬──────────┘          └──────────┬──────────┘
                        └──────────┬─────────────────────┘
                          CDBR: 200 MHz busclk / 8000 = 25 kHz tick
                                   │
                          CPU IP7 (level-triggered, dedicated)
                                   ▼
                        rtl819x_timer_interrupt()
                        IR read → IRQ_NONE if not ours
                        → W1C ack → cd->event_handler()
```

**Role split.** Timer1 runs forever as a pure counter (`DATA1 = max`,
mode=Counter, IRQ masked) — reads are side-effect-free. Timer0 is
re-armed per event by the clockevents core in oneshot mode; the
`set_next_event` sequence (disable → load DATA0 → enable) restarts the
count from zero each time.

**Single instance, globals by design.** One timer block exists per SoC;
since v1.2 the driver is built on the `timer_of` framework (TMR-S01): a
single file-static `struct timer_of` owns the register base (plain
`of_iomap`, no region claim), the refclk and the IRQ, with the
clocksource/sched_clock paths reading the base through it. The hand-rolled
resource/irq/clk parsing and the separate global base pointer are gone.

## 4. The 25 kHz regime (TMR-005 / WDT-005)

The DT feeds `clocks[0]` ("refclk") from the **25 kHz `slowclk`** node,
not the 25 MHz crystal. The driver computes
`DivFactor = busclk / timer_rate = 200 MHz / 25 kHz = 8000` (the SDK
BSP's own value) and programs CDBR once at init. This was a deliberate
trade made for the *watchdog*, whose maximum overflow bucket is 2^24
ticks: at 25 MHz that ceiling was ~671 ms (unfeedable from userspace);
at 25 kHz it is ~671 s.

What 25 kHz costs and buys on the timer side:

| Property | at 25 MHz (pre-v3.4.2) | at 25 kHz (current) |
|---|---|---|
| sched_clock / clocksource resolution | 40 ns | **40 µs** |
| Timer1 28-bit wrap | ~10.7 s | **~3 h** |
| min_delta (8 ticks today) | n/a (was 0x300 ≈ 31 µs) | 320 µs |
| hrtimer effective granularity | ~µs | ~40 µs + IRQ latency |

The resolution loss is invisible to kernel timekeeping (HZ=250 = 4 ms
tick) and shows up only in perf/ftrace/printk timestamp precision —
an accepted trade, documented at the `slowclk` node itself.

`min_delta = 8 ticks` is the second tuned constant: 320 µs sits
comfortably under the 4 ms tick but far above the program-the-timer
MMIO latency on this 200 MHz core. (The old 0x300 would have meant a
30 ms floor at 25 kHz — incompatible with HZ=250.)

## 5. Init sequence — ordering is the contract

`rtl819x_timer_init()` (from `TIMER_OF_DECLARE`, during `time_init()`),
v1.2 / timer_of shape:

```
1. timer_of_init(): map registers (of_iomap, no claim), enable refclk
   (rate-validated), request_irq(IRQF_TIMER)   ← handler live from here
2. busclk → 200 MHz (fallback if absent); validate + program CDBR
   DivFactor (panic on nonsense — TMR-001)
3. register clocksource + sched_clock (Timer1 starts free-running)
4. QUIESCE Timer0: TC0_EN off, stale TC0_PENDING W1C, IR masked
5. clockevents_config_and_register()       ← core may arm Timer0 from here
```

The v3.4.0 TMR-002 ordering (quiesce strictly before request_irq) is
deliberately relaxed by timer_of: request_irq happens first. The window
is closed by the handler itself, not by ordering — a stale bootloader
pending bit fires at most one interrupt at unmask time, the W1C ack
clears it and the NULL `event_handler` check skips the dispatch (the
TMR-003 hardening). What remains load-bearing is step 4 before step 5:
the clockevent must not be exposed to the core with a stale pending or
an enabled TC0.

## 6. Context & concurrency model

- **UP, single instance.** `cpumask_of(0)` is exact, not a placeholder.
- All clockevent callbacks (`set_next_event`, `set_state_*`) are invoked
  by the core **with IRQs disabled**; the IRQ handler is the only other
  CTRL/IR writer and cannot preempt them. The read-modify-writes are
  therefore race-free without locking.
- The clocksource read is a single `readl` — safe from any context,
  `notrace` for the sched_clock variant.
- No suspend/resume, no hotplug, no teardown: the SoC has none of these.

## 7. External dependencies

| Dependency | Where | Role |
|---|---|---|
| `CONFIG_CLKSRC_RTL819X=y` | `config-6.18-realtek.txt` + `drivers-clocksource-{Kconfig,Makefile}.patch` | builds the driver (bool, built-in only) |
| `timer@3100` node | `rtl819x.dtsi` | reg window, IP7 interrupt, clock phandles (note: window currently overlaps WDTCNR — TMR-009) |
| `slowclk` 25 kHz fixed-clock | `rtl819x.dtsi` | timer_rate; **the** knob of the 25 kHz regime |
| `busclk` 200 MHz fixed-clock | `rtl819x.dtsi` | DivFactor numerator (LX bus clock) |
| `irq-rtl819x` / `&cpuintc` | `drivers/irqchip/` | IP7 delivery |
| watchdog driver | `drivers/watchdog/` | co-tenant of the CDBR tick — see §4 |
| `HZ=250`, `HIGH_RES_TIMERS=y`, `NO_HZ_IDLE` | config | the consumers the constants are tuned against |

## 8. Invariants (do not break)

1. **CDBR is shared with the watchdog.** Any change to `slowclk`,
   `busclk`, or the DivFactor computation rescales the watchdog overflow
   table — re-derive *both* drivers' numbers together (the WDT-005 /
   TMR-005 lesson).
2. **The IRQ handler stays self-contained** (W1C ack + NULL
   event_handler tolerance): under timer_of, request_irq precedes the
   Timer0 quiesce, so the handler is the only guard for that window.
   And **quiesce stays before clockevents_config_and_register** — the
   core must never see a stale pending or an enabled TC0.
3. **The `>> 4` / `<< 4` adjustment** is the hardware's 28-bit-in-[31:4]
   layout, not a scaling choice — it must match `CLOCKSOURCE_MASK(28)`
   and the `(1 << 28) - 1` max_delta.
4. **`min_delta` is coupled to the tick rate.** If the clock regime ever
   changes again, recompute it (target: well under `1/HZ`, well over
   MMIO arm latency).
5. **Timer1 must stay IRQ-masked.** Its pending bit is cleared and its
   interrupt disabled at init; the clocksource contract is
   side-effect-free reads.
6. **Init failures panic.** This is the platform's only timebase; a
   "graceful" failure is a worse diagnostic than a panic banner
   (TMR-006 tracks the one path that still soft-fails).
