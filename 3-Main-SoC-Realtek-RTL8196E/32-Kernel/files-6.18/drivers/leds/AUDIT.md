# leds-gpio-pwm — driver audit

| | |
|---|---|
| **Audit date** | 2026-06-12 |
| **Driver version** | unversioned (no `DRV_VERSION`/`MODULE_VERSION`; #120 fix shipped in v3.8.3) |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`) |
| **Scope** | `leds-gpio-pwm.c` (234 raw / 145 pure LOC) + Kconfig/Makefile patches under `patches-6.18/` |
| **Companion** | `DESIGN.md` (hardware story, LAN-LED ASIC discovery, mode mapping) |

First standalone audit of this driver. Based solely on the current code;
LED-core behaviour (`led_classdev_unregister()` → `LED_OFF`) and `HZ=250`
verified in the expanded 6.18 tree, not assumed.

---

## 1. Security review

### 1.1 Attack surface

None worth the name. The driver consumes a trusted DT node and exposes the
standard LED-class sysfs files (root-writable only). Brightness values are
clamped by the LED core to `max_brightness`; there is no parsing of
untrusted input, no DMA, no network path. The review below is therefore
about lifecycle correctness, not exploitability.

### 1.2 Verified correct

- **Timer vs `brightness_set` lifecycle.** `brightness` is the only field
  shared under the spinlock; `pwm_active` and `counter` are touched
  lock-free, and that is sound *on this platform*: single-core, the timer
  callback runs in TIMER_SOFTIRQ, and the interleavings all resolve —
  the callback's 0/255 guard path declines to re-arm and clears
  `pwm_active`, after which `brightness_set` correctly skips
  `timer_delete_sync()`; in the opposite order `timer_delete_sync()` kills
  the re-armed timer and waits out the running callback. (The guard's
  "should not happen" comment undersells it — the guard is *reachable*
  whenever a 0/255 write lands between the callback's brightness snapshot
  and its re-arm — but the handling is correct.) On SMP or PREEMPT_RT these
  lock-free accesses would need rework; recorded as a portability note, not
  a defect.
- **`timer_delete_sync()` calling context.** `brightness_set` is a
  non-blocking op, so triggers may invoke it from softirq (e.g. heartbeat's
  own timer). On UP, timer callbacks are serialized in the same softirq, so
  the sync-wait can never spin against a running instance of our callback.
  Safe here; same portability caveat as above.
- **Teardown.** No `.remove` and none needed: everything is devm-managed,
  and `devm_led_classdev_register_ext`'s unregister path calls
  `led_set_brightness(LED_OFF)` (verified in `led-class.c:614`), which
  routes through our `brightness_set(0)` → `timer_delete_sync()`. devm
  release order (classdev before gpiod) is correct, so the timer is dead
  before the GPIO descriptor goes away. The probe-loop error path
  (`of_node_put(child)` + return) unwinds already-registered children the
  same way.
- **The #120 re-arm.** `mod_timer(&led->timer, jiffies)` from the callback
  is the load-bearing line: the timer wheel's `calc_index()` rounds every
  expiry up one granularity, so `jiffies + 1` buckets at +2 (8 ms step,
  31 Hz, visible flicker) while `jiffies` buckets at the next tick (true
  4 ms step, 62.5 Hz). The in-code comment captures this precisely —
  do not "clean it up" to `jiffies + 1`.
- **GPIO from softirq.** `gpiod_set_value()` on gpio-rtl819x is plain MMIO
  (non-sleeping chip) — legal in timer context.
- **Arithmetic.** `threshold = (bright × 4 + 127) / 255` for bright ∈
  1..254 yields 1..4 after the floor-to-1 clamp; `counter` wraps at 4. No
  overflow, no division surprises (compile-time constants; no runtime
  `div_u64` need on the divide-less Lexra).

### 1.3 Verdict

No security flaw; no reachable memory-safety issue. Two functional nits and
some hygiene below.

---

## 2. Findings

### LED-001 — `default-state = "keep"` can never keep (low, dormant)

`gpio_pwm_led_probe_child()` requests the line with `GPIOD_OUT_LOW`, which
drives it low at request time — *then* the `"keep"` branch reads
`gpiod_get_value()` to learn the pre-existing state. It always reads back
the 0 the driver just wrote, so `"keep"` silently behaves as `"off"`.
Mainline `leds-gpio` requests `GPIOD_ASIS` exactly for this reason and only
then normalizes the direction. Dormant: the in-tree DTS uses
`default-state = "off"`, so nothing is currently wrong on the gateway — but
the property is advertised (same child syntax as `gpio-leds`) and would
mislead a board port. Fix: request `GPIOD_ASIS` when the property is
`"keep"` (LED-S01).

### LED-002 — brightness 224–254 runs the PWM timer at 100 % duty (info)

The quantization maps bright ≥ 224 to `threshold = 4` = always-on: the LED
is visually identical to 255, but because `brightness_set` only stops the
timer at exactly `>= 255`, the 224–254 band keeps 250 timer callbacks/s
alive writing an unchanging GPIO level. Symmetrically, 1–31 clamps to the
25 % floor rather than off. Cost is the documented ~0.004 % CPU — real
fleets only ever use 0/60/255 (the `led_mode` mapping), so the band is
unvisited in practice. Optional fix: quantize in `brightness_set` and treat
duty 4/4 as full-on, 0/4 as off (LED-S02).

### LED-003 — initial arm uses `jiffies + 1`, steady-state uses `jiffies` (info)

`brightness_set` starts the PWM with `mod_timer(timer, jiffies + 1)`, which
the #120 analysis showed buckets at +2 — the first tick lands ~8 ms out
instead of ~4 ms. One-shot start latency only; the steady-state re-arm in
the callback is correct. Worth aligning to `jiffies` purely so the file
doesn't contain the exact pattern its own #120 comment warns about
(LED-S03).

### LED-004 — no version identity (info)

The driver carries no `DRV_VERSION`/`MODULE_VERSION` and no versioned boot
banner, unlike every other custom driver in this tree — and unlike what the
release version-bump checklist greps for. It has now had one
behaviour-relevant fix (#120) that is invisible in any runtime banner.
Add `MODULE_VERSION` at the next functional touch (LED-S04).

---

## 3. Simplification / 6.18 alignment

Already current API throughout: `devm_fwnode_gpiod_get`,
`devm_led_classdev_register_ext` with `led_init_data`, `timer_setup` /
`timer_container_of` / `timer_delete_sync` (the 6.x-renamed timer API).

| ID | Change | Value |
|---|---|---|
| LED-S01 | `GPIOD_ASIS` when `default-state = "keep"` | Closes LED-001; one-line, makes an advertised property true |
| LED-S02 | quantize duty in `brightness_set`; 4/4 → full-on, 0/4 → off | Closes LED-002; saves the timer in the dead bands |
| LED-S03 | initial arm at `jiffies` | Closes LED-003; consistency with the #120 rule |
| LED-S04 | `MODULE_VERSION("1.1")` + banner | Closes LED-004; version-bump checklist compliance |

### Considered and rejected (this audit)

- **hrtimer-based PWM.** Already tried and reverted: 1 kHz hrtimers caused
  LX-bus contention with UART during Xmodem flashes
  (`DESIGN.md`). The jiffies softirq timer is the design, not a
  shortcut.
- **Reusing mainline `leds_pwm`.** Requires a PWM provider; the RTL8196E
  has no hardware PWM. A software `pwm_chip` shim would be strictly more
  code than this driver.
- **Reverting to mainline `leds-gpio`.** Loses brightness control, which is
  the whole point (STATUS dim=60 must match the LAN LED's ASIC scan-mode
  glow — see the design notes' dual-brightness story).
- **Locking `pwm_active`/`counter` or `READ_ONCE` annotations.** Correct on
  this UP platform as analysed in §1.2; annotations would document an SMP
  contract the driver doesn't otherwise honour. If the driver ever leaves
  this SoC family, redo the lifecycle instead of sprinkling macros.
- **Higher PWM resolution.** 8 levels → 31 Hz: the exact #120 flicker. The
  4-level/62.5 Hz trade-off is settled; revisit only if HZ ever changes
  (a `BUILD_BUG_ON(HZ != 250)` would over-constrain — the math degrades
  gracefully, it doesn't break).

---

## 4. Finding ID registry

| ID | Severity | Status | Summary |
|---|---|---|---|
| LED-001 | low (dormant) | fixed (v1.1) | `default-state = "keep"` always reads the just-written 0 |
| LED-002 | info | fixed (v1.1) | 224–254 band keeps a 250 Hz timer alive at 100 % duty |
| LED-003 | info | fixed (v1.1) | initial arm `jiffies + 1` contradicts the #120 rule (one tick) |
| LED-004 | info | fixed (v1.1) | no MODULE_VERSION / banner |
| LED-S01..S04 | — | implemented (v1.1) | see §3 and the note in §5 |

Related history (tracked elsewhere): issue #120 (31 Hz flicker, fixed
v3.8.3 by the `mod_timer(…, jiffies)` re-arm); the LAN-LED-is-ASIC-wired
discovery and `LEDCREG`/`DIRECTLCR` handling live in the Ethernet driver
(`led_mode`), documented in `DESIGN.md`.

---

## 5. Conclusion

A deliberately small driver whose one hard-won subtlety — the timer-wheel
rounding that produced issue #120 — is correctly implemented and correctly
documented at the line that matters. Lifecycle and teardown are sound under
the platform's UP/softirq model, with the SMP caveat recorded. The four
findings are one dormant property bug and three hygiene items; LED-S01 is
the only one with user-visible potential (board ports), and none justifies
a kernel rebuild alone — batch them with the next LED-area change.

**Implementation note (2026-06-12):** S01–S04 implemented as driver
**v1.1** on maintainer request and bench-verified on the .88 gateway by
sampling the physical GPIO 11 line via devmem across the brightness
bands: 128 → live PWM at ~2/4 duty, 60 → ~1/4 duty (the critical dim
level), 250 → constant full-on with **no timer**, 20 → constant off
(quantized), 0 → off. `default-state = "keep"` now requests `GPIOD_ASIS`
and re-drives the line as output at the level read back.
