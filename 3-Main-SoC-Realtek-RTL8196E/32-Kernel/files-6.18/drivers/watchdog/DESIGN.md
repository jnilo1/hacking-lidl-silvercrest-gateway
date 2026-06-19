# RTL8196E watchdog driver (`rtl819x-wdt`) — design

| | |
|---|---|
| **Document date** | 2026-06-11 (updated 2026-06-12 for driver v1.5, then v1.6) |
| **Driver version** | 1.6 (`DRV_VERSION` in `rtl819x_wdt.c`) |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`); v1.5/v1.6 unreleased |

Architecture reference for the driver. Operator-facing usage lives in
`README.md`; security and code findings in `AUDIT.md` (both in this
directory).

---

## 1. Hardware model

The RTL8196E watchdog is a single 32-bit register, **WDTCNR** at
`sysc + 0x311C` (physical `0x1800311C`), driving an internal **up-counter**
that resets the whole SoC on overflow. There is no readable counter, no
interrupt, no pretimeout — the entire programming model is:

```
 31      24 23     22  21 20    19      18  17 16        0
+----------+------+--------+-----+--------+------+--------+
|   WDTE   |WDTCLR|OVSEL1:0|WDIND|NRFRstTy|OVSEL3:2| rsvd |
+----------+------+--------+-----+--------+------+--------+
 0xA5=stop  W1 =   bucket    W1C   strap    bucket
 else run   kick   (low)    (rst             (high)
                            cause)
```

- **WDTE** `[31:24]` — `0xA5` halts the counter; *any other byte* runs it.
- **WDTCLR** `[23]` — write 1 to zero the up-counter ("kick"); hardware
  auto-clears the bit.
- **OVSEL** — a 4-bit selector split across `[22:21]` (low) and `[18:17]`
  (high), choosing the overflow threshold: `0000`=2^15 ticks up to
  `1001`=2^24 ticks.
- **WDIND** `[20]` — reset-cause flag (W1C). Empirically reads 0 on rev
  0xb08 even after a watchdog reset (open finding WDT-001).

The tick comes from **CDBR** (`sysc + 0x3118`), a clock divider **shared
with Timer0/Timer1** (the system clocksource). Since v3.5.0 the
`timer-rtl819x` driver programs DivFactor = 8000 from the 25 kHz `slowclk`
DT fixed-clock, so:

```
tick = 200 MHz / 8000 = 25 kHz
OVSEL=1001 → 2^24 ticks / 25 kHz ≈ 671 s   (hardware ceiling)
OVSEL=0000 → 2^15 ticks / 25 kHz ≈ 1.31 s  (reset bucket)
```

This sharing is the single most important external constraint: **changing
CDBR rescales the watchdog and the clocksource simultaneously** (see
WDT-005 / TMR-005 history).

## 2. Driver architecture

```
   BusyBox watchdog -t 30          S26panicrec (next boot)
        (S25watchdog)                    ▲ dmesg line
              │ write/ioctl             │
        ┌─────▼──────────┐    ┌─────────┴──────────┐
        │ watchdog core   │    │ probe: report &    │
        │ (/dev/watchdog, │    │ clear panic record │
        │  auto-kick when │    └─────────▲──────────┘
        │  HW_RUNNING)    │              │ readl/memcpy_fromio
        └─────┬──────────┘     ┌─────────┴──────────┐
   ops: start/│stop/ping/      │ reserved DRAM page │
   set_timeout│/restart        │ memory-region      │
              │                │ (boothold, no-map) │
        ┌─────▼──────────┐     └─────────▲──────────┘
        │  rtl819x_wdt   │               │ writel/memcpy_toio
        │  (this driver) │───────────────┘ panic notifier
        └─────┬──────────┘   (priority INT_MAX, arm chip + record)
              │ writel
        ┌─────▼──────────┐
        │ WDTCNR @0x311C │──overflow──▶ SoC reset
        └────────────────┘
```

### 2.1 Fixed-bucket policy ("soft timeout contract")

The chip is **always armed at the maximum bucket** (OVSEL=1001, ~671 s).
`wdd.timeout` (default 60 s, DT `timeout-sec`) is a *soft contract* that
drives the framework's ping cadence and userspace expectations — it is
never translated into an OVSEL value. Rationale:

- The bucket granularity is power-of-two ticks; mapping arbitrary second
  values onto 10 coarse buckets adds code for no protection gain.
- The protection property that matters — "the box reboots if nobody
  kicks" — is provided by the kick cadence (30 s) against the fixed
  ceiling (671 s), with ~22× margin.
- A fixed arm pattern makes every WDTCNR write a compile-time constant,
  which keeps the panic/restart paths trivially auditable. Since v1.6
  the kick is a constant write too (no read-modify-write — the RMW
  cost an uncached MMIO read per kick and W1C-erased WDIND when set).

Consequence: `.set_timeout` only stores the value, and the real
worst-case reset latency after the last kick is the 671 s ceiling, not
`timeout`. This is deliberate and documented in the ops comments. The
ceiling is declared to the core as `max_hw_heartbeat_ms = 671000`
(v1.6, exact semantics: it *is* a hardware window, not a timeout
register), so the core bridges any longer soft timeout with worker
pings instead of rejecting it; sysfs `max_timeout` reads 0.

### 2.2 Lifecycle

Pure platform driver, DT-matched (`realtek,rtl8196e-wdt`), built-in
(`CONFIG_RTL819X_WDT=y`). Everything is devm-managed; there is no
`.remove` and no shutdown hook (the chip is *supposed* to stay armed as
late as possible). Probe sequence:

1. map WDTCNR (4 bytes) from the DT `reg`;
2. populate `watchdog_device` (min timeout 1 s, hardware window
   declared via `max_hw_heartbeat_ms`, `watchdog_init_timeout()` for
   DT override, restart priority 192);
3. decode + W1C the WDIND reset-cause bit (best-effort, WDT-001);
4. **adopt** a pre-armed chip: if WDTE ≠ 0xA5, set `WDOG_HW_RUNNING` so
   the core auto-kicks at `timeout/2` until userspace opens the device —
   the chip is never disarmed during boot, and a SIGKILLed feeder leaves
   the safety net intact (`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`);
5. map the panic-record page, then report-and-clear any record left by
   the previous boot (one-shot dmesg line);
6. register the watchdog device;
7. register the panic notifier at priority `INT_MAX`, with a devm action
   for symmetric teardown.

### 2.3 The three reset paths

All three converge on the same primitive — *make WDTCNR overflow soon*:

| Path | Trigger | Mechanism | Latency |
|---|---|---|---|
| `.restart` op | `reboot`, `sysrq-b` | `writel(0)`: WDTE=run, OVSEL=0, no kick → overflow | ~1.3 s |
| Panic notifier | `panic()`, incl. soft-lockup via `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y` | record post-mortem, then two-step arm (see §3.2) | ~1.3 s after panic; ~23 s end-to-end for a soft lockup |
| Natural overflow | everyone stops kicking | up-counter passes 2^24 ticks | ≤ 671 s |

The `.restart` op at priority 192 wins over the arch-level
`_machine_restart` (the historical `writel(0)` in `arch/mips/realtek/`),
which remains as the fallback when the driver hasn't probed.

Why the panic notifier exists at all (WDT-008): on this UP /
`PREEMPT_NONE` system, the framework auto-kicker runs from softirq, which
a userspace busy-syscall loop keeps draining — so a soft-locked box gets
petted forever. Promoting the soft lockup to `panic()` disables IRQs
(killing the kicker) and runs our notifier, which arms the 1.31 s bucket.
`INT_MAX` priority (WDT-009) guarantees no earlier notifier can wedge the
chain before the arm lands; returning `NOTIFY_DONE` lets later notifiers
run inside the grace window.

## 3. Panic post-mortem record

The differentiating feature of this driver: a soft-lockup reboot leaves a
*why* behind, surviving the reset, instead of vanishing with the volatile
ramfs `/var/log`.

### 3.1 Storage — shared reserved page

The record reuses the `no-map` reserved-memory page already carved out for
boothold (the labelled `boothold` node in the board DTS — `boothold@1ffe000`
on the Lidl board). Since v1.5 the driver does not know the address: the
watchdog node carries `memory-region = <&boothold>;` and probe resolves the
page via `of_reserved_mem_lookup()` — a board that relocates the reservation
(64 MiB Sengled G4: `boothold@3ffe000`) moves the record with it, and a DTS
without the property/reservation cleanly disables the post-mortem feature.
Layout, shown here with the Lidl addresses (offsets are page-relative):

```
0x01FFE000 ┌──────────────────────────────┐
           │ panic record (≤ 0x144 bytes) │  ← this driver, grows up
0x01FFE144 ├──────────────────────────────┤
           │        ~3.8 KB gap           │
0x01FFEFF4 ├──────────────────────────────┤
           │ boothold: packed IPv4        │
0x01FFEFF8 │ boothold: TFTP-IP magic      │  ← boothold.c, grows down
0x01FFEFFC │ boothold: HOLD magic         │
0x01FFF000 └──────────────────────────────┘
```

`no-map` keeps the kernel from ever allocating the page, so the record is
intact from panic-write to next-boot read; boothold proved empirically
that this DRAM survives a WDTCNR reset. Both producers are
append-from-opposite-ends, so neither can clobber the other. (The former
address coupling by duplicated constant was finding WDT-012 — closed in
v1.5: this driver resolves the page from the `memory-region` phandle, the
`boothold` tool (v1.2) from `/sys/firmware/devicetree` at runtime, and the
bootloader read side from the per-board `BOARD_DRAM_TOP_KSEG1` in
`31-Bootloader/boards/<board>/board.h`.)

### 3.2 Write path — ordering is the design

The notifier write sequence encodes a hard lesson (WDT-010): **diagnosis
must never be able to delay or lose recovery.**

```
1. core record   uptime, reason, fn, epc/ra, softirq mask — no list walks,
                 counts zeroed, sentinel set; then magic "PANC" LAST + wmb()
                 → a torn record can never validate
2. arm the chip  two writes: (WDTE=0xA5 | WDTCLR)  — kick while halted
                             0                     — enable, OVSEL=0
                 → counter provably starts from 0; the v1.3 single-write
                   arm raced a stale counter and reset INSTANTLY
3. wheel walks   timer + hrtimer candidate lists (≤6 each), entries before
                 count (torn read sees 0); wheel overdue/pending stats last
                 → a wedged walk costs only the lists; reset still lands
```

Everything is `writel`/`memcpy_toio` into the uncached mapping — no
allocation, no locks, no kallsyms, panic-context-safe. The uptime field
is read with the NMI-safe `ktime_get_boot_fast_ns()` (v1.6): the
ordinary seqcount accessors could spin forever if the panic interrupted
a timekeeping writer (WDT-011, closed).

### 3.3 Record content (v3) and what each field discriminates

| Field | Names |
|---|---|
| `epc` / `ra` | the stuck PC and its caller — the #99 storms sit *between* timer callbacks, where `running` is NULL; `ra` names the real frame when `epc` lands in a leaf helper |
| `running` | the timer callback executing at panic, when there is one |
| `softirq` mask | *which* vector is storming (TIMER vs NET_RX vs …) when epc/ra only say "in the softirq dispatcher" |
| `timers[]` / `hrtimers[]` | candidate callbacks queued near expiry — a self-rearming culprit recurs across captures; `delayed_work` wrappers are resolved one level deeper to the work function |
| `overdue` / `pending` | wheel-lag discriminator: huge overdue = death spiral (wheel never catches up); ~0 = vector re-raised over a healthy wheel |

Raw u32 addresses are stored at panic time and symbolised with `%pS` only
at next boot (process context, same kernel image) — the atomic path stays
kallsyms-free.

### 3.4 Read path and persistence chain

```
panic ──record──▶ DRAM page ──reset──▶ next boot probe ──%pS decode──▶
  one dmesg line ("previous boot ended in panic: ...") ──S26panicrec──▶
  /userdata/panic/history   (first occurrence only; rm to re-arm)
```

The decode is one-shot (magic cleared after reporting) and
version-gated: v4 (current) plus v3/v2 (one-boot leftovers that follow a
firmware upgrade) decode; v1/unknown print a stub. All field reads are
clamped/NUL-terminated (see AUDIT.md §1.2).

**Single-line emission — truncation risk (deferred, AUDIT WDT-013).** The
report is one `dev_info()` concatenating every field, so it is bound by the
kernel's per-record printk limit (`LOG_LINE_MAX`, ~1 KB including the
`rtl819x-wdt …:` prefix). A fully-populated v4 record (long timer/hrtimer
lists + the NET_RX counters + a long `reason`) can approach that limit and
truncate the **tail**: `reason` is last and the v4
`softirqs=/hardirqs=/napi=` block sits just before it, so those are the
first fields lost. `S26panicrec` copies the dmesg line **verbatim** into
`/userdata/panic/history` (`grep -F 'previous boot ended in panic' |
tail -1`), so the file inherits any truncation — it adds none and recovers
none. Every real capture to date (~600–700 B) sits well under the limit and
persists intact.

Decision (2026-06-16): **left deferred** per WDT-013 ("no action required
now"). The #99 root-cause fix (`rtl8196e-eth` v2.14 tx_timeout RX-resync)
should stop new records, and rc1 is mid-soak where changing the record
format would disturb in-flight field captures. When revisited (post-GA /
record v4.1) it is a *coupled* change: split the report into ≥2 `dev_info()`
lines **and** adapt the `S26panicrec` grep to capture both (a naïve split
would drop the 2nd line from the file), plus sanitize `reason[]` to
printable ASCII (the log-injection half of WDT-013).

### 3.5 Kernel-side helpers (out-of-driver API)

The wheel walks need internals (`timer_bases`, `hrtimer_bases`) that no
exported 6.18 API reaches, so four GPL-exported, panic-cold-path-only
helpers are added by patch — they exist solely for this driver:

| Helper | Patch |
|---|---|
| `timer_get_running_fn()` | `kernel-time-timer.c.patch` |
| `timer_collect_pending_fns(out, max)` | `kernel-time-timer.c.patch` |
| `timer_wheel_stats(&overdue, &npend)` | `kernel-time-timer.c.patch` |
| `hrtimer_collect_pending_fns(out, max)` | `kernel-time-hrtimer.c.patch` |

Contract: UP-only (`raw_cpu_ptr`), caller has preemption/IRQs off (panic),
bounded output where the caller passes `max`. Consequence: the driver
cannot build out-of-tree against a vanilla kernel — the patches and the
driver ship as one unit.

## 4. Context & concurrency model

- **UP, `PREEMPT_NONE`** — one CPU, no SMP races by construction; the
  panic/restart paths run with IRQs off (system effectively frozen).
- Normal-path ops (`start/stop/ping/set_timeout`) are serialized by the
  watchdog core's per-device mutex.
- The record page has exactly one writer per epoch: the notifier at panic
  time, the probe (clear) at boot time.

## 5. External dependencies

| Dependency | Where | Role |
|---|---|---|
| `CONFIG_RTL819X_WDT=y` | `config-6.18-realtek.txt` | the driver |
| `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` | config | framework auto-kick after adoption |
| `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y` | config | soft lockup → panic → notifier |
| `CONFIG_PANIC_ON_OOPS=y`, `CONFIG_PANIC_TIMEOUT=10` | config | every fatal path funnels into panic; timeout is the last-ditch fallback |
| `slowclk` 25 kHz fixed-clock + `timer-rtl819x` CDBR programming | `rtl819x.dtsi`, `drivers/clocksource/` | tick rate → all timing math in §1 |
| `watchdog@311c` node (`timeout-sec=60`) | `rtl819x.dtsi` / board DTS | probe + soft timeout |
| labelled `boothold` reserved-memory node + `memory-region = <&boothold>` on the watchdog node | board DTS | record storage page, resolved at probe (WDT-012 closed in v1.5: coupling is by phandle) |
| `S25watchdog` | `34-Userdata` skeleton | userspace feeder, 30 s kicks |
| `S26panicrec` | `34-Userdata` skeleton | persists the post-mortem line to JFFS2 |
| 4 timer/hrtimer patches | `patches-6.18/` | §3.5 helpers |

## 6. Invariants (do not break)

1. **Arm before walk** — in the panic notifier, the chip-arm writes must
   precede any list walk; the walks are best-effort bonuses.
2. **Two-step arm** — kick-while-halted, then enable. A single-write arm
   reintroduces the WDT-010 instant-reset race.
3. **Magic last, count after entries** — every record write sequence must
   stay torn-read-safe (magic behind `wmb()`; per-list count written after
   its entries).
4. **No kallsyms / alloc / sleep in the notifier** — symbolisation happens
   at next boot only.
5. **CDBR is shared** — any clocksource/divider change rescales the
   watchdog; re-derive the §1 numbers if `slowclk` ever moves.
6. **Record stays below page+`0x144`**, boothold stays at the page top —
   the gap is the collision margin for both features' future growth.
   A board DTS that relocates the reservation must keep the `boothold:`
   label (the `memory-region` phandle dereferences it) and keep the page
   at DRAM top − 0x2000, matching its bootloader's `BOARD_DRAM_TOP_KSEG1`.
7. **`timeout-sec`/feeder cadence margin** — keep kick interval ≪ 671 s
   ceiling (today: 30 s, ~22×).
