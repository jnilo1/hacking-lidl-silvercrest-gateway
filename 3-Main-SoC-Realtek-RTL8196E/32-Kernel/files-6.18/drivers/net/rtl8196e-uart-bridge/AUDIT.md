# rtl8196e-uart-bridge — driver audit

| | |
|---|---|
| **Audit date** | 2026-06-12 |
| **Driver version** | 1.3 (`DRV_VERSION` in `rtl8196e_uart_bridge_main.c`) |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`) |
| **Scope** | `rtl8196e_uart_bridge_main.c` (1 785 raw / 1 098 pure LOC), `Kconfig`, `Makefile` |
| **Companions** | `DESIGN.md` (architecture), `README.md` (operator reference), `SECURITY.md` (deployment hardening) |

First standalone audit of this driver (the existing `DESIGN.md` / `SECURITY.md`
pre-date it and remain the architecture and deployment references). Based
solely on the current code; every claim below was verified against the source
in this tree, including the kernel-side `kernel/params.c` behaviour the driver
implicitly depends on (§1.2, BRIDGE-001).

Method: full read of the single source file, cross-checked against the 6.18
tty (`tty_kopen_exclusive`, `tty_port.client_ops`), socket (`kernel_*msg`,
`kernel_sock_shutdown`) and gpiod consumer APIs, plus `kernel/params.c`
(`param_attr_store` / `param_attr_show`) in `linux-6.18-rtl8196e/`.

---

## 1. Security review

### 1.1 Attack surface

| Surface | Who can reach it | Exposure |
|---|---|---|
| TCP listener (default `0.0.0.0:8888`) | any peer that can route to the gateway | **Unauthenticated, plaintext EZSP/CPC/Spinel session with the radio.** Deliberate, documented, mitigated by `BRIDGE_BIND=127.0.0.1` + SSH tunnel (`SECURITY.md`). A new connection **evicts** the connected client (see BRIDGE-002). |
| UART RX bytes (radio side) | EFR32 firmware (or whoever flashed it) | In `flow_control=sw`, bare 0x11/0x13 gate the TCP→UART direction — bounded to 1 s by the fail-open timer, so a hostile/wedged radio cannot park the worker or hang disarm. In hw/none modes, bytes are forwarded verbatim. |
| Module parameters (sysfs) | root only — all files are root-owned with modes 0600/0644/0444/0200; write bit is owner-only on every knob | Validated setters (§1.3). Side effect: pulse knobs hold the **global** built-in `param_lock` for their duration (BRIDGE-003). |
| Device tree `/radio-bridge` node | build-time (trusted) | Seeds `nrst_gpio` / `blmode_gpio` / `flow_control` defaults only; range-checked (`args[0] <= 31`), unknown `flow-control` strings rejected with a warning. |

### 1.2 Verified correct

Concurrency and lifecycle — the historically dangerous part of this driver —
hold up under line-by-line review:

- **`client_sock` ownership discipline.** `bridge_send_to_client_locked()`
  never releases the socket on error; it only `kernel_sock_shutdown()`s it
  (state flip, no free) to wake the worker out of `kernel_recvmsg()`. The
  final `sock_release()` is owned by exactly one party: the worker's phase-2
  cleanup if `state.client_sock == newsock` still holds, otherwise whoever
  NULLed the pointer under `bridge_lock` (disarm, reconfig, or the
  replace-client path). No UAF, no double-free path found.
- **`stopping_worker` handshake.** A connection accepted inside a
  disarm/reconfig tear-down window is released immediately instead of being
  installed as state the outgoing teardown no longer knows about. The flag is
  re-checked after the replace-client path re-acquires `bridge_lock`, closing
  the window opened by the intermediate `sock_release(old)`.
- **`listen_sock` lifetime vs the lockless reader.** The worker reads
  `state.listen_sock` with `READ_ONCE()` outside any lock; disarm keeps the
  pointer populated until the synchronous `kthread_stop()` has returned, and
  only then NULLs it. `bridge_reconfig_listen_locked()` deliberately defers
  installing the new socket until the old worker is gone, for the same reason.
- **Bounded XOFF gate.** The sw-mode TX pause is a 1 s fail-open wait that
  also polls `kthread_should_stop()`, so a lost XON can neither stall the
  host→radio path indefinitely nor hang the disarm path's `kthread_stop()`.
  A network client cannot inject flow control at all: the XON/XOFF scan runs
  only on the UART→TCP direction, and the host→radio stream is never filtered.
- **nRST / blmode pulses.** Open-drain semantics throughout — the pad is
  driven low or floated, never driven high against the EFR32's RESETn
  pull-up. Both knobs are write-only mode 0200 (root), serialized by
  `nrst_pulse_lock`, and claim the lines per-pulse so they stay free between
  pulses. `blmode_pulse` validates `blmode_gpio >= 0` and
  `blmode_gpio != nrst_gpio`, and its error path releases the already-claimed
  blmode line before returning.
- **Input validation.** baud 1200–4 000 000; port 1–65535; gpio lines 0–31
  (blmode −1–31); brightness 0–255; `bind_addr` through `in4_pton()` before
  acceptance; `flow_control` parsed into a closed enum (numeric ABI preserved
  for `flash_efr32.sh` readback); all string params copied with `strscpy`
  into fixed buffers with explicit `-ENAMETOOLONG` on overflow.
- **No torn reads.** All `u64` counters are read and written under
  `bridge_lock` (32-bit MIPS has no atomic 64-bit loads); every getter takes
  the lock; the two lockless reads (`sw_tx_paused`, `listen_sock`,
  `rtl_flow_control` in the worker) are `READ_ONCE`/`WRITE_ONCE` pairs with
  documented staleness tolerance.
- **`kernel_getpeername()` into `struct sockaddr_in`** is safe on an AF_INET
  socket (inet writes exactly `sizeof(struct sockaddr_in)`).
- **Arm error unwind** restores `saved_client_ops` and closes the tty in the
  correct order under `tty_lock`; `tty_kopen_exclusive` guarantees no
  userspace open can race the kernel-side claim.

### 1.3 Standing risk — the unauthenticated TCP endpoint

Unchanged and deliberate: anyone who can reach the listen port owns the
radio. The complete threat model and the loopback+SSH mitigation live in
`SECURITY.md`. This audit's one correction to that model: eviction is
immediate (BRIDGE-002) — the attacker does not have to wait for the
legitimate client to disconnect. `SECURITY.md` has been amended accordingly.

### 1.4 Verdict

No remotely exploitable memory-safety flaw found. The socket/worker/tty
lifecycle is correct under the locking that actually executes (including the
implicit global param lock, see BRIDGE-001). The residual risks are the
documented unauthenticated endpoint (mitigated by deployment, §1.3) and the
low-severity items below.

---

## 2. Findings

### BRIDGE-001 — config-transition atomicity silently depends on the global kernel param lock (low, latent)

`bridge_disarm_locked()` and `bridge_reconfig_listen_locked()` drop
`bridge_lock` mid-operation (around `kernel_sock_shutdown` + synchronous
`kthread_stop()`), then re-acquire it to finish clearing state. Taken in
isolation, that window would let a concurrent `enable=1` (after a `tty`
change, or timed between `tty_kclose()` and the re-lock) arm a fresh
worker/tty/socket that the resuming disarm would then wipe —
`state.listen_sock` NULLed under a live worker means a NULL dereference in
`kernel_accept()`, plus an orphaned kthread and leaked socket/tty refs.

**Why it is not reachable today:** every sysfs write to a built-in module's
parameters runs inside `param_attr_store()` → `kernel_param_lock(NULL)` →
the **global** `param_lock` mutex (`kernel/params.c`; verified in this tree).
Getters serialize the same way. So no two setters of this driver can ever
interleave, and the mid-disarm window is unobservable. Boot-time cmdline
parsing is single-threaded.

**Risk:** the invariant lives entirely outside the driver and is not recorded
in it. Any future non-param entry point that calls arm/disarm — a reboot
notifier, a platform-driver conversion, an ioctl — would reopen the race for
real.

**Fix direction (later):** a one-paragraph comment above
`bridge_disarm_locked()` naming the dependency; optionally an explicit
driver-level config mutex taken at the top of every setter as belt-and-braces
(zero hot-path cost — the hot path never touches it).

### BRIDGE-002 — replace-on-connect vs "refuses additional connects" in the docs (low, doc/threat-model — **docs corrected in this pass**)

The code replaces an existing client on every new accept: the worker releases
the old socket (`"replacing previous client"`) and installs the new one.
`DESIGN.md` ("Single-client listener") claimed the bridge *refuses* additional
connects until the first closes, and `SECURITY.md`'s threat model said an
attacker could impersonate the host "once the legitimate client disconnects".
Both understated the behaviour: any peer that can reach the port can evict
the connected client **at any time**.

The replace policy itself is sound — it is what lets a restarted Z2M/cpcd
reclaim the bridge without operator action, and an attacker who can connect
already owns the radio under this threat model, eviction or not. The defect
was documentation. Both files are corrected as of this audit; no code change
needed.

### BRIDGE-003 — pulse knobs hold the global built-in param_lock for their whole duration (info)

Because of the same `kernel/params.c` serialization, `nrst_pulse` holds the
global `param_lock` for ~100 ms and `blmode_pulse` for ~5.1 s. During that
time **every** sysfs parameter read/write of **every built-in module on the
system** blocks — including this driver's own `stats`/`armed` getters. The
in-code comment above `nrst_pulse_lock` ("it should not stall a concurrent
stats reader") is therefore inaccurate at the sysfs layer; only the UART→TCP
hot path (`bridge_port_receive_buf`, which goes nowhere near the param
machinery) is genuinely unaffected, and that is the claim that matters.

Operationally harmless (both knobs are rare, root-triggered maintenance
actions). Fix is a comment correction when the file is next touched; moving
the sleeps out of the setter is not worth the asynchrony it would buy.

### BRIDGE-004 — connection-lifecycle pr_info is not ratelimited (low)

`"client connected from %pI4"`, `"replacing previous client"` and
`"client disconnected"` are plain `pr_info()`. A LAN peer can flap
connections in a tight loop and churn the kmsg buffer / ramfs
`/var/log/messages` (3 MB rotation) at no cost, washing out diagnostics. The
error paths already use `pr_warn_ratelimited`; the connect/replace/disconnect
trio should follow when next touched.

### BRIDGE-005 — worker kthread name truncated (info)

`DRV_NAME "-worker"` = `rtl8196e-uart-bridge-worker` exceeds
`TASK_COMM_LEN`; `ps` shows `rtl8196e-uart-b`, indistinguishable from a
hypothetical sibling. Cosmetic.

### BRIDGE-006 — stale ancillary text (info)

- `Kconfig` help describes `nrst_pulse`/`nrst_gpio` but predates v1.3's
  `blmode_pulse`/`blmode_gpio`.
- `README.md` said "~1400 lines" for the source file (actual: 1 785 raw,
  1 098 pure LOC) — corrected in this pass.

### BRIDGE-007 — DT gpio phandle controller is ignored (info, accepted)

`bridge_seed_defaults_from_dt()` consumes only the line number of
`nrst-gpios`/`blmode-gpios`; the pulse paths always claim through the
`"gpio-rtl819x"` label regardless of which controller the DT cell named.
Irrelevant on this SoC (single gpiochip) and already documented in
`README.md` ("only the line numbers are consumed"). Recorded here so a
future multi-gpiochip port knows to revisit.

### BRIDGE-008 — tty path→devt TOCTOU (info, negligible)

`resolve_tty_devt()` resolves the path, then `tty_kopen_exclusive()` opens by
`dev_t`; the path could in principle be swapped in between. Requires root,
on a static devtmpfs, to attack a root-only knob. No action.

---

## 3. Simplification / 6.18 alignment

The driver is already shaped for 6.18 (`tty_kopen_exclusive`,
`tty_port.client_ops`, gpiod consumer API, `sock_set_*` helpers, LED trigger
API). Remaining items are small:

| ID | Change | Value |
|---|---|---|
| BRIDGE-S01 | Comment (or explicit config mutex) recording the param-lock dependency | Closes BRIDGE-001's latency before it bites a future refactor |
| BRIDGE-S02 | `pr_info_ratelimited` on the connection-lifecycle messages | Closes BRIDGE-004 |
| BRIDGE-S03 | Refresh `Kconfig` help (blmode knobs) and the inaccurate stats-reader comment | Closes BRIDGE-003/-006 leftovers |

### Considered and rejected (this audit)

- **Platform-driver conversion** to bind the `/radio-bridge` node properly
  (would also fix BRIDGE-007). Rejected — already evaluated in `DESIGN.md`;
  churn on a field-stable driver for zero functional gain, and it would turn
  BRIDGE-001's latent race into a live one unless S01 lands first.
- **Persistent gpiod descriptors** instead of claim-per-pulse. Rejected —
  claim-per-pulse keeps the lines free for other consumers and makes
  `nrst_gpio` changes stateless (`DESIGN.md` rationale stands).
- **`tty_dev_name_to_number()`** instead of `kern_path()`. Rejected — the
  parameter is a path; name-based lookup would silently drop symlink
  semantics for no robustness gain.
- **Spinlock or lock-free hot path.** Rejected — measured mutex cost ≈ 8 µs
  per `receive_buf` at 892 857 baud, ~2.5 % worker CPU (`DESIGN.md`,
  "Stability properties"). No headroom problem exists.
- **`sk->sk_data_ready` callbacks instead of the blocking worker.** Rejected —
  the single blocking kthread is the simplest correct shape for one client at
  a time; callback-driven TX would need its own queue and flush discipline
  for zero measured benefit.
- **Table-driven param boilerplate.** The eleven setters share a
  lock/validate/rollback pattern that could be factored, but each rollback is
  subtly different (re-arm, re-termios, re-listen); a generic helper would
  obscure more than it saves.
- Previously rejected in `DESIGN.md` and still valid: line discipline hook,
  multi-client fan-out, netlink control plane, IRAM placement of the hot
  path.

---

## 4. Finding ID registry

| ID | Severity | Status | Summary |
|---|---|---|---|
| BRIDGE-001 | low (latent) | mitigated (v1.4) | dependency now documented in-code at both sites; still latent by design |
| BRIDGE-002 | low | **docs fixed 2026-06-12** | replace-on-connect (eviction) vs docs claiming refuse-while-busy |
| BRIDGE-003 | info | comment fixed (v1.4) | pulses hold global built-in param_lock 100 ms / ~1.1 s; in-code comment now accurate |
| BRIDGE-004 | low | fixed (v1.4) | connect/replace/disconnect now pr_info_ratelimited |
| BRIDGE-005 | info | open | worker kthread comm truncated to `rtl8196e-uart-b` |
| BRIDGE-006 | info | fixed (v1.4) | Kconfig help covers blmode knobs; README line count fixed earlier |
| BRIDGE-007 | info | accepted | DT gpio controller phandle ignored, line number only |
| BRIDGE-008 | info | accepted | tty path→devt TOCTOU, root-only, negligible |
| BRIDGE-S01..S03 | — | implemented (v1.4) | see §3 and the note in §5 |

---

## 5. Conclusion

The bridge is in the best shape of the custom drivers audited so far: a
single file with an explicitly documented concurrency contract, and the
contract holds — the one thing it gets "for free" without saying so is the
global param-lock serialization (BRIDGE-001/-003), which this audit pins
down. No security flaw beyond the deliberate, documented open endpoint; the
only substantive corrections were to the documentation's claims about
single-client semantics (BRIDGE-002, fixed). Code-side candidates when an
implementation slot opens: BRIDGE-S01 (one comment or one mutex) and
BRIDGE-S02 (three ratelimited prints).

**Implementation note (2026-06-12):** S01–S03 implemented as driver
**v1.4** on maintainer request: BRIDGE-001's param_lock dependency is now
documented at the `bridge_lock` definition and at the disarm
drop-and-retake site (the latent race stays latent *and* visible to the
next refactor); the four remote-triggerable connection-lifecycle
messages are `pr_info_ratelimited`; the inaccurate stats-reader claim in
the `nrst_pulse_lock` comment now states the param_lock blocking
behaviour (BRIDGE-003), and the Kconfig help covers the blmode knobs
(BRIDGE-006). Bench-verified on .88: armed at boot, three
connect/disconnect cycles logged normally.
