# RTL8196E I-MEM optimization tools

These tools implement the bounded I-MEM procedure for a new kernel release.
Generated references, raw profiles, candidates and benchmark results live below
`imem-work/` and are deliberately ignored by git.

The procedure starts from an empty 16 KiB I-MEM window. It does not inherit a
previous release's function list. The previous production policy is rebuilt on
the new kernel only as the independent confirmation baseline.

## Safety invariants

- Every patch must apply without warning, fuzz or offset.
- Profiling uses an empty I-MEM window and the in-kernel 250 Hz PC sampler.
- Runtime-patched text (`__jump_table`, `__mcount_loc`, static calls and
  alternatives when present) is excluded from I-MEM.
- Moving a selected input section leaves an equal-size local hole in `.text`.
  The invariant checker compares the candidate against the exact empty-window
  production link map.
- Every reboot used for performance testing is followed by a `dmesg` gate and
  by stopping OTBR, netwatch, button and UART-bridge userland. A surviving
  process or an armed in-kernel UART bridge aborts the point.
- Raw selection output becomes a production policy only after structural
  checks and the standard 11-run release benchmark pass. A 12-round paired
  comparison is reserved for marginal candidates or causal measurement.

## Campaign outline

Build the empty profiling reference:

```sh
scripts/imem/build_profile_reference.sh 6.18
scripts/imem/build_profile_reference.sh 7.1
```

Capture two idle, two TX and two RX profiles with
`capture_profile.sh`, then decode and solve them with
`analyze_captures.sh`. The exact knapsack objective is mean net TX samples; the
bootstrap byte-retention gate must pass before a candidate may be built.

Build the production-layout candidate from the resulting manifest:

```sh
scripts/imem/build_optimized_candidate.sh 6.18 \
  imem-work/6.18.45/profile-captures/selection-manifest.json
```

Run the standard release benchmark on the exact candidate. It uses 11 TX and
11 RX repetitions so each reported median is an observed run. A large-margin
candidate may take the bounded fast path when TX is at least 80 Mbit/s, RX at
least 90 Mbit/s, retransmissions and hard counters remain zero, and both
`dmesg` gates pass. The exact policy is then recorded under `policies/` and is
automatically applied by normal production builds of that kernel release.

For a marginal result, or when a precise causal estimate is wanted, compare the
candidate (`C`) with the previous production policy rebuilt on the same kernel
(`I`):

```sh
scripts/imem/confirm_candidates.sh \
  --candidate imem-work/6.18.45/production/candidate/kernel.img \
  --incumbent imem-work/6.18.45/production/incumbent/kernel.img \
  --output imem-work/6.18.45/confirmation-run1 \
  --expect 6.18.45- 192.168.1.88
```

This optional confirmation freezes six randomized order draws and their six exact
reverses before the first point. Each of the 24 points reboots and flashes the
gateway, flushes host TCP metrics, then records the median of three TX and three
RX measurements. Aggregate results remain sealed until all points are valid.

Confirmation requires a narrowly scoped host sudoers rule for:

```text
/bin/ip tcp_metrics flush all
```

The harness proves this permission before creating the output directory or
touching the gateway. It never falls back to a run without the flush.

`confirm_results.py` performs the one pre-registered paired analysis. A
candidate is confirmed only when the 95% TX interval excludes zero, mean TX is
at least +0.7 Mbit/s, and the RX lower bound remains above -0.5 Mbit/s.

## Structural equivalence

Structural equivalence is decided by the tools, not by visual review. The
local-hole invariant checker verifies selected section sizes, preserved holes,
code identity and linked I-MEM occupation against the exact reference map. The
dynamic-code scanner independently rejects any runtime patch site in the I-MEM
window. A failed check reopens the campaign; it cannot be waived by the
optimizer.
