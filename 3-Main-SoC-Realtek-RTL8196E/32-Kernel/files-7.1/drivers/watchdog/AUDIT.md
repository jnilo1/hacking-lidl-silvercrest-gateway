# RTL8196E watchdog driver (`rtl819x-wdt`) — security & code audit

| | |
|---|---|
| **Audit date** | 2026-06-11 (updated 2026-06-12 for driver v1.5, then v1.6 — WDT-011 + S-batch implemented) |
| **Driver version** | **1.6** (`DRV_VERSION` in `rtl819x_wdt.c`, `MODULE_VERSION`) |
| **Active release** | **v3.10.0** (kernel `6.18.35-rtl8196e-v3.10.0`); v1.5/v1.6 unreleased |
| **Audited artifacts** | `rtl819x_wdt.c` (this directory); the four kernel patches that exist solely for this driver: `patches-6.18/kernel-time-timer.c.patch`, `kernel-time-hrtimer.c.patch`, `include-linux-timer.h.patch`, `include-linux-hrtimer.h.patch`; DT nodes `watchdog@311c` (`rtl819x.dtsi`) and the labelled `boothold` reserved-memory node + `memory-region` phandle (`rtl8196e.dts`); Kconfig dependencies in `config-6.18-realtek.txt`; userspace touchpoints `34-Userdata/skeleton/etc/init.d/S25watchdog` and `S26panicrec` (security surface only) |

This audit **supersedes and replaces** the previous `AUDIT.md` (written
during the v1.2 dev cycle, v3.5.0 release window). It is a fresh audit of
the code as it stands today; nothing was carried over unverified. Legacy
finding IDs `WDT-001`, `WDT-005`, `WDT-008`, `WDT-009` are still referenced
from code comments and the DTS, so the full ID registry is preserved at the
end of this file with one-line dispositions.

Audit questions, per the project audit charter:

1. **Security** — does the driver introduce exploitable flaws?
2. **Simplification / optimization** — can the code be simplified or
   optimized for the Linux 6.18 APIs it targets?

---

## 1. Security audit

### 1.1 Attack surface

| Surface | Exposure | Assessment |
|---|---|---|
| `/dev/watchdog` char device | `crw------- root root` (0600) | Root-only. All ioctls go through the watchdog core, which clamps `WDIOC_SETTIMEOUT` to `[min_timeout, max_timeout]` = [1, 671] before calling the driver. No driver-private ioctls. |
| sysfs (`/sys/class/watchdog/watchdog0/*`) | World-readable, no writable attributes from this driver | Read-only telemetry (identity, timeout, status). No information of value to an attacker. |
| Module parameter `nowayout` | 0444, boot cmdline only (built-in `=y`) | Read-only after boot. |
| Panic record page (the board's `boothold` reservation — DRAM `0x01FFE000` on Lidl, resolved from the `memory-region` phandle since v1.5) | Writable by the kernel and by root via `/dev/mem`/`devmem` | The only *parsed input* in the driver — analysed in §1.2. |
| MMIO `WDTCNR` register | Root via `devmem` can always arm/stop the chip directly | Inherent to the SoC, not a driver property. Root can already `reboot(2)`; no new capability. |

No unprivileged surface exists. Every reachable path requires root, and
root already holds strictly stronger primitives (`reboot`, `/dev/mem`).
**No trust boundary is crossed anywhere in this driver.**

### 1.2 Untrusted-input analysis — the panic record decode path

`rtl819x_wdt_report_panic_record()` runs once at probe and parses a DRAM
page that survived the reset. The page could contain a legitimate record, a
torn record, random garbage (cold boot), or a record forged by root on the
previous boot. Findings:

- **Magic gate** — decode only proceeds if `+0x00 == "PANC"`. The notifier
  writes the magic *last*, behind a `wmb()`, so a torn record never passes
  the gate. Verified correct.
- **Version gate** — only `v3` (current) and `v2` (one-boot leftover after
  a firmware upgrade) layouts are decoded; anything else prints a single
  "unknown record" line and clears the magic. The `v2` path never reads the
  `v3`-only fields (`overdue`/`pending` guarded by `ver >= 3`). Verified
  correct.
- **Candidate-count clamp** — `rtl819x_wdt_fns_decode()` clamps the
  on-record count to `WDT_REC_NR_FNS` (6) before iterating, so a corrupted
  count cannot overread the mapped window. Verified correct.
- **Reason string** — written with `memset_io` + bounded `memcpy_toio`
  (`strnlen(reason, WDT_REC_REASON_MAX - 1)` = max 0xDF bytes starting at
  +0x10, ending at 0xEF — provably clear of `epc` at +0xF0); read back with
  a forced NUL at `[WDT_REC_REASON_MAX - 1]`. No overflow in either
  direction. Verified correct.
- **`%pS` on attacker-chosen u32** — `sprint_symbol()` performs a kallsyms
  *lookup*; it never dereferences the value. A forged address yields a raw
  hex print, not a fault or an info leak beyond kallsyms names (dmesg is
  root-readable here anyway). Safe.
- **`scnprintf` accumulation** — both decoders use the
  `pos += scnprintf(buf + pos, len - pos, ...)` idiom; `scnprintf` with
  size 0 writes nothing and returns 0, so saturation is safe. Verified
  correct.

Residual (accepted-risk) items below: WDT-013.

### 1.3 Panic-path robustness (the notifier runs in the worst context the kernel has)

- **Arm-before-walk ordering (v1.4 design)** — the chip is armed
  (`~1.31 s` window) *before* the timer/hrtimer wheel walks. A walk that
  wedges on a corrupted list can therefore delay the candidate lists, never
  the reset or the already-committed core record. This is the right
  ordering and is field-proven (the v1.3 regression that motivated it is
  WDT-010 below).
- **Two-step arm** — `WDT_DISABLE_PATTERN | WDTCLR` then `0`: clears the
  up-counter while the chip is halted, then enables. Closes the v1.3
  instant-reset race (stale counter > OVSEL=0 threshold at enable time).
  Straight-line code with IRQs off; no window in which the box is left
  unprotected (the second write is unconditional). Verified correct,
  bench- and field-confirmed.
- **Bounded collectors** — `timer_collect_pending_fns()` /
  `hrtimer_collect_pending_fns()` increment `n` on every visit and bail at
  `max`, so even a *circular* corrupted hlist terminates. Verified correct.
- **Unbounded stats walk** — `timer_wheel_stats()` counts all queued
  timers with no upper bound; a circular list loops forever. Acceptable
  *only because* it runs post-arm and last, and the record carries the
  `0xFFFFFFFF` "walk did not complete" sentinel for exactly this case.
  Documented invariant: **never move this walk before the arm writes.**
- **No sleeping, no allocation, no kallsyms** in the notifier — all writes
  are MMIO/`memcpy_toio` into an uncached mapping; symbolisation is
  deferred to next boot. Verified correct.
- **WDT-011 (fixed in v1.6)** — the uptime read in the notifier used
  `ktime_get_boottime_seconds()`, which is *not* panic-safe; now the
  NMI-safe fast accessor. See §2.

### 1.4 Lifecycle / concurrency

- **Ops serialization** — all `watchdog_ops` calls are serialized by the
  watchdog core mutex; the only concurrent writers to `WDTCNR` are the
  `.restart` handler and the panic notifier, both of which run with the
  system effectively single-threaded (UP, IRQs off). No race.
- **devm teardown order** — release runs in reverse: panic-notifier
  unregister → watchdog unregister → `rec`/`base` unmap → free. The
  notifier can never fire against a stale mapping. The
  `devm_add_action_or_reset()` failure path unregisters the notifier
  inline. Verified correct.
- **Sysfs unbind footgun (info, accepted)** — root can unbind the driver
  while the chip is `HW_RUNNING`; the chip stays armed with nobody kicking
  and the box resets ≤ 671 s later. Root-only, self-inflicted, and
  arguably the safe failure direction for a watchdog. No action.

### 1.5 Userspace touchpoints

- `S25watchdog` — `killall watchdog` + magic-close `V` on stop; runs as
  root from init. No injection surface (no user-controlled input).
- `S26panicrec` — captures the one-shot dmesg line into
  `/userdata/panic/history`. `$line` is double-quoted throughout and is
  written to a file, never evaluated. First-occurrence guard caps JFFS2
  writes. No injection surface.

### 1.6 Security verdict

**No exploitable vulnerability found.** The driver adds no unprivileged
attack surface; the single parsed input (the panic record) is bounds-checked
at every field; the panic path is ordered so that diagnostic code cannot
defeat recovery. Two low-severity hardening items (WDT-011, WDT-013) and
one robustness item (WDT-012) are listed below — none is exploitable across
a privilege boundary.

---

## 2. New findings (this audit)

| ID | Type | Severity | One-liner |
|----|------|----------|-----------|
| WDT-011 | ROBUSTNESS (panic path) | **low** (likelihood) / medium (impact) | `ktime_get_boottime_seconds()` can spin on the timekeeping seqlock if the panic interrupted a timekeeping writer — and it runs *before* the chip-arm writes |
| WDT-012 | ROBUSTNESS / PORTABILITY | low | *(closed in v1.5)* panic-record page address was hard-coded (`0x01FFE000`) instead of resolved from the DT `reserved-memory` node — silent corruption hazard on boards whose DTS drops or moves `boothold@1ffe000` |
| WDT-013 | HARDENING | info | forged/corrupted record `reason[]` is printed unsanitized (control-char log injection into dmesg); fully-populated report line can approach the ~1 KB printk limit |
| WDT-014 | OBSERVABILITY | info | `WDIOF_CARDRESET` never reported via `bootstatus` — `WDIOC_GETBOOTSTATUS` always reads 0 (moot while WDT-001 stands) |

### WDT-011 — non-panic-safe clock read in the notifier

`rtl819x_wdt_panic_notify()` calls `ktime_get_boottime_seconds()`, which
resolves to a coarse timekeeping read under the `tk_core.seq` seqcount
retry loop. If the panic was raised while that seqcount was odd — on this
UP machine that means an oops *inside* the timekeeping write section, which
`CONFIG_PANIC_ON_OOPS=y` (set in `config-6.18-realtek.txt`) promotes to a
panic — the read loop spins forever.

Impact is amplified by ordering: the call sits in the core-record block,
**before** the chip-arm writes. A spin there means (a) the record is never
committed and (b) recovery degrades to the userspace-armed OVSEL=9 overflow
(≤ 671 s) — or to **no recovery at all** if the chip happened to be
magic-closed. `CONFIG_PANIC_TIMEOUT=10` does not save us either: the
notifier chain runs before the panic timeout loop, and this notifier is
priority `INT_MAX`, first in the chain.

**Recommendation.** Use the NMI-safe fast accessor:
`div_u64(ktime_get_boot_fast_ns(), NSEC_PER_SEC)` (lock-free, designed for
exactly this context; `div_u64` is cold-path so the Lexra soft-divide cost
is irrelevant). Likelihood is low — timekeeping writers run IRQs-off and
are a tiny code window — but the fix is one line and removes the only
unbounded wait ahead of the arm writes.

**Resolution (v1.6).** Implemented as recommended. Bench-verified
end-to-end on the Lidl board: sysrq crash at `/proc/uptime` 159 s
produced a record with `uptime=160s` (trigger deferred by a 1 s sleep) —
the fast-accessor conversion matches the boottime clock to the second,
and the full v3 record (reason, candidate lists, overdue/pending)
decoded normally on the following boot.

### WDT-012 — record page address not bound to the DT reservation

`WDT_REC_PHYS 0x01FFE000` duplicates, by hand, the address of the
`boothold@1ffe000` `reserved-memory` node in `rtl8196e.dts`. The driver
never verifies the reservation exists. Two failure shapes:

- A board DTS that **drops** the node (the v3.10.0 DT generalization now
  builds multiple boards from the same driver set — see the `BOARD=` build
  flow): the page is then ordinary kernel RAM. The probe-time
  `devm_ioremap()` creates an uncached alias of a page the kernel also
  maps cached (a classic MIPS aliasing hazard), and the panic-time write
  scribbles over whatever lives there. Pre-reset that is mostly harmless,
  but the next-boot *read* path would also parse a live kernel page.
- A board DTS that **moves** the reservation (different DRAM size — e.g.
  the 64 MiB Sengled G4 port in discussion #119): the driver keeps using
  the old address, silently landing in unreserved RAM as above.

**Recommendation.** Add a `memory-region = <&boothold>;` phandle to the
`watchdog@311c` node and resolve it at probe via
`of_reserved_mem_lookup()`; when the property or the reservation is absent,
keep `wdt->rec = NULL` (the existing graceful degradation: post-mortem off,
watchdog unaffected). This turns a silent corruption into an explicit,
per-board opt-in — consistent with the "board facts live in DT" direction
shipped in v3.10.0.

**Resolution (v1.5, v3.11.0-pre).** Implemented exactly as recommended:
the board DTS labels the reservation (`boothold:`) and sets
`memory-region = <&boothold>;` on the watchdog node; probe resolves it
via `of_parse_phandle()` + `of_reserved_mem_lookup()` and requires
`rmem->size >= WDT_REC_SIZE`; `WDT_REC_PHYS` is gone. The companion
userspace writer (`boothold` v1.2) now discovers the same page from
`/sys/firmware/devicetree` at runtime, and the bootloader's read-side
constant is derived per board from `BOARD_DRAM_TOP_KSEG1`
(`31-Bootloader/boards/<board>/board.h`). Bench-verified end-to-end on
the Lidl board (probe with no degradation warning; sysrq crash record
written and decoded at the DT-resolved address), and dtc-verified on the
Sengled G4 DTS (`/delete-node/` + relabel rebinds the phandle to
`boothold@3ffe000`).

### WDT-013 — record decode hardening (accepted risk, documented)

Two cosmetic weaknesses in `rtl819x_wdt_report_panic_record()`:

1. `reason[]` is printed with `%s` into dmesg. A record forged by root (or
   random garbage that happens to pass the magic gate — probability
   ~2^-32) can embed terminal escape sequences that fire when an operator
   `cat`s the console log. Sanitizing to printable ASCII would cost ~5
   lines. Root-only provenance keeps this at *info*.
2. The single `dev_info()` line carries up to ~850 bytes of decoded fields;
   with twelve `%pS` expansions it can flirt with the ~1 KB printk record
   limit and truncate the tail (`reason` is last). Splitting into two lines
   would remove the risk; against that, the one-line format is what
   `S26panicrec`'s `grep -F 'previous boot ended in panic'` captures
   atomically. If a field capture ever arrives truncated, split the line
   and adapt the grep.

No action required now; revisit if either bites in the field.

### WDT-014 — bootstatus not wired

The WDIND decode lands only in dmesg; `wdd.bootstatus` is never set, so
`WDIOC_GETBOOTSTATUS` always returns 0. Wiring
`wdt->wdd.bootstatus = WDIOF_CARDRESET` when WDIND reads 1 is two lines —
but WDT-001 (WDIND empirically reads 0 after a watchdog reset on rev
0xb08) makes the value unreliable anyway, and the panic record supersedes
it as the actual reset-cause channel on this platform. Defer until/unless
WDT-001 is ever resolved.

---

## 3. Simplification & optimization for kernel 6.18

The driver is already shaped for 6.18: watchdog core registration, full
devm lifecycle (no `.remove`), `module_platform_driver()`, DT-only probe,
`watchdog_init_timeout()`. The hot path is a single 30-second-cadence MMIO
RMW — there is nothing to optimize for performance. Remaining items are
small and behavior-preserving unless noted:

| ID | Item | Gain |
|----|------|------|
| WDT-S01 | `wdt->base = devm_platform_ioremap_resource(pdev, 0);` replaces the `platform_get_resource()` + `devm_ioremap_resource()` pair | −3 lines, the canonical 6.x idiom |
| WDT-S02 | Drop `platform_set_drvdata(pdev, wdt)` — nothing ever reads it back (no `.remove`, no sibling accessor) | dead line |
| WDT-S03 | Drop `.get_timeleft` — it returns the constant `wdd->timeout`, which is not a time-left and dilutes the ioctl's meaning; absent the op, the core returns `EOPNOTSUPP` (honest). BusyBox `watchdog` never calls it | −10 lines; *minor userspace-visible change* |
| WDT-S04 | Fold the duplicated WDTCNR layout documentation — the file header (lines ~5–35) and the register-block comment (~63–90) are near-identical twins; keep the register-block copy, point the header at it | −25 lines of drift-prone duplication |
| WDT-S05 | `.ping` as a constant write: `writel(WDT_ENABLE_PATTERN \| WDTCLR, base)` instead of the read-modify-write | saves one uncached MMIO read per kick and stops the RMW from silently W1C-clearing WDIND when set (today's RMW reads WDIND=1 and writes it back, erasing the one reset-cause bit WDT-001 is still hoping to observe). Caveat: an adopted chip armed with a non-max OVSEL gets normalized to the max bucket on first kick — which is what `.start` would do anyway |
| WDT-S06 | Consider `max_hw_heartbeat_ms = 671000` instead of `max_timeout = 671` | semantically exact (the hardware window *is* fixed); the core then derives the keepalive cadence itself and would honor hypothetical longer soft timeouts. Optional — current contract is documented and works |
| WDT-S07 | `#include <linux/of.h>` appears unused (no `of_*` call; `of_device_id` comes from `mod_devicetable.h`) | verify with a build, then drop |

WDT-011 (§2) is the only *recommended-now* code change; WDT-S01/S02/S04/S07
are safe to batch with it. WDT-S03/S05/S06 change visible behavior slightly
and should ride a normal release with a CHANGELOG note.

**Implementation status (v1.6, 2026-06-12).** S01–S06 implemented in one
batch with WDT-011. Verified core semantics before switching S06: in
6.18, a non-zero `max_hw_heartbeat_ms` makes `watchdog_timeout_invalid()`
skip the `max_timeout` clamp entirely, so the conversion *replaces*
`max_timeout` (now reads 0 in sysfs) rather than complementing it —
soft timeouts above the 671 s window are accepted and bridged by
core worker pings (`watchdog_next_keepalive()` uses
`min_not_zero(timeout, max_hw_heartbeat_ms)/2`, so the stock 60 s
cadence is unchanged). Bench-verified on the Lidl board: `timeleft`
sysfs attribute gone (S03), `watchdog -T 700` accepted with the chip
armed at the max bucket (S06; pre-v1.6 the core rejected >671), feeder
stop/start and kick path nominal (S05 exercised every 30 s).
**WDT-S07 was already obsolete when implementation started**: the audit
predates v1.5, whose `memory-region` resolution added
`of_parse_phandle()` to the probe — `<linux/of.h>` is now genuinely
required and stays. CHANGELOG note for S03/S05/S06 to be added at the
next release cut.

The four kernel patches were also reviewed for 6.18 fit: they touch only
cold paths, export with `EXPORT_SYMBOL_GPL`, use `raw_cpu_ptr()` correctly
for the documented UP/panic context, and `timer_collect_pending_fns()`'s
`delayed_work` un-wrapping uses `container_of` on the embedded timer —
correct against 6.18.35's `struct delayed_work`. No simplification
warranted; they are deliberately minimal to keep the vanilla diff small.

---

## 4. Finding ID registry (complete)

IDs are stable because code comments and the DTS reference them. Details of
WDT-001…WDT-009 live in this repo's git history (pre-v3.10.0 AUDIT.md).

| ID | Status | One-liner |
|----|--------|-----------|
| WDT-001 | **open (deferred)** | WDIND reads 0 after a watchdog reset on rev 0xb08 — "last reset:" dmesg line is unreliable; the panic record (v1.2+) now fills that role in practice |
| WDT-002 | closed (v1.0) | `.restart` at priority 192 supersedes `_machine_restart` |
| WDT-003 | closed (v1.0) | `of_match_table` restricted to `realtek,rtl8196e-wdt` |
| WDT-004 | closed (v1.0) | `WDOG_HW_RUNNING` adoption of a pre-armed chip |
| WDT-005 | closed (v1.1) | CDBR slowclk rework: 25 kHz tick, OVSEL=1001 ceiling ~671 s |
| WDT-006 | closed (v1.0) | OVSEL is a 4-bit field (datasheet), not the SDK's 2-bit |
| WDT-007 | closed (v1.1) | `S25watchdog` feeder enabled, DT `timeout-sec=60` |
| WDT-008 | closed (v1.2) | soft-lockup blind spot: panic notifier + `BOOTPARAM_SOFTLOCKUP_PANIC=y` → ~23 s autonomous recovery |
| WDT-009 | closed (v1.2) | panic notifier priority pinned `INT_MAX` |
| WDT-010 | closed (v1.4) | **v1.3 arm-race regression**: single-write arm let a stale up-counter (userspace-armed OVSEL=9) instantly overflow the OVSEL=0 threshold — chip reset before one instruction after the write, losing every candidate list (field-confirmed by a `timers=[none]` capture). Fixed by the two-step arm (clear while halted, then enable) |
| WDT-011 | **closed (v1.6)** | non-panic-safe `ktime_get_boottime_seconds()` ahead of the arm writes — replaced by the NMI-safe fast accessor, bench-verified end-to-end (§2) |
| WDT-012 | **closed (v1.5)** | record page now bound to the DT reservation via `memory-region` phandle (§2); was hard-coded |
| WDT-013 | open — accepted risk | record decode hardening: log injection / printk line length (§2) |
| WDT-014 | open — deferred | `bootstatus`/`WDIOF_CARDRESET` not wired; moot under WDT-001 (§2) |
| WDT-S01…S06 | **closed (v1.6)** | 6.18 simplifications implemented (§3); S06 replaces `max_timeout` with `max_hw_heartbeat_ms` |
| WDT-S07 | closed — obsolete | `<linux/of.h>` became a real dependency in v1.5 (`of_parse_phandle`); nothing to drop (§3) |

---

## 5. Conclusion

The v1.6 driver is in good shape: no security flaws, a panic path whose
ordering has been hardened by real field failure (WDT-010), and an API
surface that matches 6.18 idioms. **WDT-012 closed in v1.5** (record page
bound to the DT reservation), **WDT-011 and the whole S-batch closed in
v1.6** (panic-safe uptime read; canonical probe idiom; honest
`max_hw_heartbeat_ms` contract; constant-write kick that preserves
WDIND). Remaining open items are deliberate deferrals: WDT-001 (hardware),
WDT-013 (accepted risk), WDT-014 (moot under WDT-001).
