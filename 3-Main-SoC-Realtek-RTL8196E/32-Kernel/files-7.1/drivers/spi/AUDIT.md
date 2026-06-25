# spi-rtl819x — driver audit

| | |
|---|---|
| **Audit date** | 2026-06-12 |
| **Driver version** | unversioned (no `DRV_VERSION`/`MODULE_VERSION`) |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`) |
| **Scope** | `spi-rtl819x.c` (411 raw / 333 pure LOC), `patches-6.18/drivers-spi-{Kconfig,Makefile}.patch` (`CONFIG_SPI_RTL819X=y`) |
| **Companion** | `DESIGN.md` (created with this audit) |

First standalone audit of this driver. Based solely on the current code.
Provenance matters here: the driver is adapted from Weijie Gao's
out-of-tree RTL819x SPI driver (`MODULE_AUTHOR` preserved); the register
semantics (READY bit written alongside CS, DATA-register-triggered
transfers) are vendor lore validated empirically — every JFFS2 mount and
flash backup exercises them — rather than from a datasheet.

This is a **storage-path driver**: it carries the 16 MB GD25Q127C NOR
holding all four partitions. Any behavioural change must be validated with
a full boot + JFFS2 stress + `backup_gateway.sh` byte-compare, not just a
smoke test.

---

## 1. Security review

### 1.1 Attack surface

None direct. The controller is reachable only through the SPI core from
`jedec,spi-nor`/mtd (root-only character devices, DT-described partitions
with `boot+cfg` marked `read-only` — enforced by the mtd core, not here).
Buffers come from kernel callers; there is no userspace-controlled input,
no DMA, no interrupt handler. The review is therefore about transfer
correctness on the flash path.

### 1.2 Verified correct

- **Bounded waits.** Every transfer polls `READY` through
  `readl_poll_timeout` (1 µs poll, 10 ms cap); a wedged controller yields
  `-ETIMEDOUT` up the mtd stack instead of a hang. No unbounded loop
  exists in the driver.
- **Big-endian data path.** `READ/WRITE_BYTE_ORDER` config bits are set
  under `CONFIG_CPU_BIG_ENDIAN`, with the partial-word shift helpers
  compensating for 1-byte accesses. Proven in production by every boot
  (squashfs rootfs and JFFS2 userdata both ride this path).
- **Alignment handling.** Both `rtk_read`/`rtk_write` drain leading
  unaligned bytes one at a time, then switch to 4-byte words, then mop up
  the tail — correct on a core with no `lwl`/`lwr` (the word loop even
  uses `get/put_unaligned` on top of the now-aligned pointer; pessimistic
  but safe, see §3 rejections).
- **Serialization.** No locking needed in `set_cs`/`transfer_one`: the SPI
  core's message queue guarantees a single in-flight transfer per
  controller, and `ioc_base` is only touched within that pipeline.
- **Lifecycle.** All-devm probe with the one non-devm resource (clk)
  correctly unwound on the only post-acquisition failure path. `remove`
  and `shutdown` park the hardware with both CS lines high and max
  deselect time.

### 1.3 Verdict

No security flaw. The real content of this audit is a cluster of
*advertised-but-not-implemented* capabilities (SPI-001..004) — all dormant
because the only client is the mode-0, 8-bit, CS0 flash chip — plus
hygiene items. Nothing requires action for the current board; all of it
matters the day a second SPI device or a board port shows up.

---

## 2. Findings

### SPI-001 — CS deselect drives the *other* CS line low (low, dormant)

`realtek_spi_set_cs()` deselecting CS0 writes `RTK_SPI_CS_0_HIGH` only —
which clears the CS1 bit, actively driving CS1 low (= asserted) for as
long as the bus idles. Deselect should park the bus at
`RTK_SPI_CS_ALL_HIGH`, exactly as probe/remove/shutdown already do. (The
assert path proves the polarity convention: selecting CS0 writes
`CS_1_HIGH`, i.e. "the other line high, mine low".) Dormant on the Lidl
board — only the flash sits on CS0 and the CS1 pad isn't wired to anything
that listens — but a second device on CS1 would see itself selected
whenever the flash is deselected, and vice versa. Fix is one line per
branch (SPI-S01), **flash-soak gated** like everything in this file.

### SPI-002 — `mode_bits` advertises CPOL/CPHA the driver never programs (low, dormant)

`SPI_CPOL | SPI_CPHA` are accepted at setup, but no register write anywhere
depends on `spi->mode` — the controller runs whatever mode the hardware
implements (mode 0, per the flash's requirements). A mode-3 client would
be silently driven in mode 0. Truth in advertising: `mode_bits` should be
`SPI_CS_HIGH` only (SPI-S02).

### SPI-003 — `bits_per_word_mask` advertises 16/24/32 bpw (low, dormant)

`transfer_one` treats every buffer as a byte stream; word sizes above 8
would need per-word endianness handling the driver doesn't do. spi-nor
only uses 8 bpw, so nothing breaks today. Narrow the mask to
`SPI_BPW_MASK(8)` (SPI-S02).

### SPI-004 — sub-12.5 MHz requests are silently overclocked (info)

`rtk_choose_div_idx()` scans div 2→16 for the first rate ≤ `speed_hz`; if
none fits (request below parent/16 = 12.5 MHz at 200 MHz LX), it falls
back to div 16 — *above* the requested ceiling. A hypothetical slow device
would be overclocked without a warning. The flash runs at 25 MHz (div 8,
exact); add a `dev_warn_once` or clamp when touched.

### SPI-005 — French comments throughout (hygiene)

The file header bullets and most inline comments are in French, violating
the repo rule that committed files are English-only. Oldest offender in
the tree (predates the rule's enforcement). Translate at next functional
touch (SPI-S03) — not worth a standalone kernel-partition release.

### SPI-006 — remove/shutdown order vs the devm-registered controller (info)

`remove()` parks the hardware and disables the clock, but the devm
unregister of the controller runs *after* `remove()` returns — a transfer
still queued in that window would time out against a clock-gated
controller. Harmless in practice (errors, not corruption; and the
controller never unbinds on this platform). `shutdown()` likewise assumes
mtd quiescence, which the init scripts provide (remount-ro/sync before
reboot). Recorded; mainline pattern would be a devm action for the clk.

### SPI-007 — no version identity (info)

Same as LED-004 for the LED driver: no `MODULE_VERSION`, no banner.
Add at next touch (SPI-S03).

### SPI-008 — dead full-duplex check, wrong errno (info)

`transfer_one` rejects `tx_buf && rx_buf` with `-EPERM`, but the core
already filters full-duplex transfers for `SPI_CONTROLLER_HALF_DUPLEX`
controllers at validation time (`-EINVAL`). The in-driver check is
unreachable defensive code with a misleading errno. Drop or fix the errno
when touched.

---

## 3. Simplification / 6.18 alignment

API level is current: `devm_spi_alloc_host`, `devm_spi_register_controller`,
`readl_poll_timeout`, `spi_get_chipselect`, void `remove`. Candidates:

| ID | Change | Value |
|---|---|---|
| SPI-S01 | deselect → `CS_ALL_HIGH` in both `set_cs` branches | Closes SPI-001; flash-soak gated |
| SPI-S02 | `mode_bits = SPI_CS_HIGH`; `bits_per_word_mask = SPI_BPW_MASK(8)` | Closes SPI-002/-003; makes the core reject what the driver can't do |
| SPI-S03 | English comments, `MODULE_VERSION`, `IS_ALIGNED()` instead of `% 4` casts | Closes SPI-005/-007 |
| SPI-S04 | drop the dead full-duplex check (or `-EINVAL`) | Closes SPI-008 |

### Considered and rejected (this audit)

- **Direct word access in the aligned loops.** After the alignment
  prologue the pointer *is* word-aligned, so `get/put_unaligned` (4 byte
  loads + shifts on a no-`lwl`/`lwr` core) is pessimistic. But the CPU
  cost (~tens of ns/word) vanishes against the 25 MHz wire time
  (~1.3 µs/word); zero measurable gain on a storage path that would still
  need a full re-validation. Not worth it.
- **Conversion to `spi-mem` ops.** Would let spi-nor use `exec_op` and
  shave per-message overhead, but this controller is a plain shift
  register with no acceleration to expose; large churn on the most
  corruption-sensitive path in the system for unmeasured benefit.
- **Interrupt-driven transfers.** No evidence the block has a usable IRQ
  (none described in the DT, none in the vendor lore); the 1 µs poll on a
  single-purpose flash bus is the right shape for this platform.
- **`clock-frequency`/fallback cleanup.** The triple fallback (clk →
  DT property → hardcoded 200 MHz) looks redundant but each layer is
  reachable depending on DT generation; harmless, keep.

---

## 4. Finding ID registry

| ID | Severity | Status | Summary |
|---|---|---|---|
| SPI-001 | low (dormant) | fixed (v1.1) | CS deselect drives the other CS line low |
| SPI-002 | low (dormant) | fixed (v1.1) | CPOL/CPHA advertised, never programmed |
| SPI-003 | low (dormant) | fixed (v1.1) | 16/24/32 bpw advertised, byte-stream only |
| SPI-004 | info | fixed (v1.1) | sub-12.5 MHz fallback now dev_warn_once |
| SPI-005 | hygiene | fixed (v1.1) | comments translated to English |
| SPI-006 | info | accepted | clk disabled in remove before devm unregister |
| SPI-007 | info | fixed (v1.1) | MODULE_VERSION + probe banner added |
| SPI-008 | info | fixed (v1.1) | dead full-duplex check dropped |
| SPI-S01..S04 | — | implemented (v1.1) | see §3 and the note in §5 |

---

## 5. Conclusion

The transfer engine — the part that holds 16 MB of everyone's data — is
sound: bounded polling, correct BE handling, correct alignment discipline,
serialized by the core. Every finding lives in the *capability
advertisement* layer (CS topology, modes, word sizes) where the single
flash client never looks, plus hygiene. The right move is one batched
cleanup commit (S01–S04) the next time the kernel partition ships anyway,
validated by a boot + JFFS2 stress + backup byte-compare; S01 is the only
change with electrical effect and the only one needing real attention in
review.

**Implementation note (2026-06-12):** S01–S04 implemented as driver
**v1.1** on maintainer request, plus the SPI-004 `dev_warn_once` on
divisor-range fallback. **Storage gate passed on the .88 gateway**:
boot from squashfs through the new driver; `boot+cfg` and `rootfs`
mtdblock md5s byte-identical to the pre-change baseline (before flash,
after flash, and again after stress); 4 MB of random data written to
JFFS2, page cache dropped, re-read from flash byte-identical. SPI-001's
deselect now parks `CS_ALL_HIGH`; the advertised-capability layer
matches the hardware (`SPI_CS_HIGH` only, 8 bpw only); all comments are
English; `MODULE_VERSION`/banner present.
