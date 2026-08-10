# Thread Mesh Range — Field Test Report

This document reports practical findings from systematic radio range testing
of the Thread mesh on a Lidl Silvercrest Gateway running custom firmware
(otbr-agent + EFR32MG1B OT-RCP). It targets users deploying this gateway in
their own homes who want to know how to configure radio parameters for
reliable operation.

The test focused on three configurable variables that are easy for end users
to influence: **TX power**, **Thread channel**, and **gateway orientation**.

## TL;DR — recommended defaults

| Setting | Recommendation | Rationale |
|:--|:--|:--|
| TX power | **3 dBm** for typical homes; **5 dBm** if many obstacles | Provides ≥6 dB margin on weakest observed links without unnecessary 2.4 GHz pollution; validated over a 12 h soak with 16/16 children |
| Thread channel | **Stay on the auto-assigned channel** | Channel migration provides minor measurable benefit (<1 dB pooled) for non-trivial operational risk |
| Gateway orientation | **Place it however is convenient**; avoid contact with metal surfaces | No globally-best orientation (per-sensor preferences scatter); just keep ≥10 cm from large metal objects |
| Sensor orientation | **Long-axis horizontal pointing toward the gateway**; keep front face exposed | A single sensor showed a 22 dB swing across orientations; orientation matters more than channel choice |

## Test environment

- 16 Matter SED (Sleepy End Device) sensors of mixed types: 10× IKEA TIMMERFLOTTE
  (temperature/humidity), 4× IKEA MYGGBETT (door/window), 1× MYGGSPRAY (motion),
  1× BILRESA (button). All operating as Thread children of a single Border Router.
- Sensors physically distributed across two floors of a typical residential home.
- Gateway located in a quiet RF area (no nearby active radios).
- WiFi network present on 2.4 GHz channel 6 (overlaps Thread channel 15).
- Baseline RSSI range across the 16 sensors: **-40 dBm** (closest) to **-91 dBm**
  (most distant). LQI distribution: 9 sensors at LQI=3, 4 at LQI=2, 3 at LQI=1.

This RSSI spread is representative of a "real" deployment with a mix of close
and far sensors, including a few marginal links.

---

## Phase 1 — TX power sweep

### Method

The EFR32MG1B radio's TX power was stepped from 10 dBm down to 0 dBm. The
chip has **six calibrated power levels**: 0, 1, 3, 5, 7, and 10 dBm. Other
requested values round to the nearest calibrated step.

For each step: 2 minutes of stabilization, then 10 minutes of measurement
at 30-second intervals. Per sensor, the gateway records average RSSI, last
RSSI, link quality (LQI 0–3), and attachment state.

If any sensor detached during a step, the test was set to abort and restore
TX to the previous safe value.

### Findings

**1. Uplink RSSI is essentially invariant across TX power levels.**

This is expected and confirmed by the data: when the gateway changes TX power,
the only thing that changes is *downlink* (gateway → sensor). The RSSI we
measure is *uplink* (sensor → gateway), where the sensor's own TX power is
unchanged. Across a 10 dB sweep, per-sensor uplink RSSI varied by less than
2 dB in either direction — well within measurement noise.

**Implication for users**: increasing TX power **does not** make sensors
appear stronger in your monitoring or HA dashboards. The improvement, if any,
is in the downlink reliability — visible only as fewer detach events or
faster reattach times.

**2. Downlink quality only manifests at the failure threshold.**

The only meaningful event during the entire sweep was a single sensor
detaching when TX was reduced from 1 dBm to 0 dBm. The sensor in question
had a baseline uplink RSSI of -91 dBm, suggesting symmetric path loss meant
the downlink dropped near or below the sensor's receive sensitivity. After
TX was restored to 7 dBm, the sensor reattached automatically within minutes.

All 15 other sensors maintained their attachment at every TX level, including
0 dBm. Their downlink margin was sufficient even at the lowest setting.

**3. LQI is computed from RSSI, not an independent measurement.**

LQI values for each sensor were stable across all TX power steps (LQI=3 stayed
LQI=3, LQI=1 stayed LQI=1). This confirms LQI is a function of uplink RSSI
and noise floor, not a separate per-link estimate.

### Recommendation

**Set TX power to 3 dBm by default.** This provides:

- Approximately 6 dB of margin above the failure threshold observed in this test
- Significantly less RF energy injected into the 2.4 GHz band shared with WiFi
  and other ISM-band devices
- Lower power consumption (modest, but non-zero)

For larger homes (>200 m²) or buildings with thick obstacles (concrete walls,
metal-plated doors), increase to **5 dBm** for additional headroom.

There is no measurable benefit to running at 7 or 10 dBm in a typical setup.
The default OpenThread value of 0 dBm is too low — it leaves no margin for
the most marginal links, so any environmental degradation (someone closing
a metal door, a new appliance starting up, body absorption) can drop a
weak sensor.

---

## Phase 2 — Channel comparison (15 vs 26)

### Method

The mesh was migrated between two Thread channels using the standard Thread
Pending Operational Dataset mechanism with a 120-second delay timer (this
ensures all devices switch simultaneously after receiving the announcement).

Three sampling windows of 5–10 minutes each:

1. Baseline on Channel 15 (the as-commissioned channel — overlaps WiFi Ch 6)
2. After migration to Channel 26 (top of 2.4 GHz band, no WiFi overlap)
3. Control sample on Channel 15 after migration back

### Findings

**1. Pooled mean RSSI gain on Channel 26: +0.86 dB.**

Across all 16 sensors and all sample windows, Channel 26 shows a marginally
higher mean RSSI than Channel 15. The difference is within the noise floor
of the measurement (typical per-sensor σ ≈ 0.7 dB) and not statistically
significant. **Channel choice does not provide a meaningful global benefit
in this setup.**

**2. Per-sensor variation between channels is large.**

Individual sensors showed RSSI deltas ranging from **-7.7 dB to +6.5 dB**
between Channel 15 and Channel 26. Some sensors clearly preferred one
channel; others the opposite. There was no predictable pattern based on
distance, sensor type, or RSSI strength.

**Cause**: frequency-selective multipath fading. The 55 MHz spacing between
Channel 15 (2425 MHz) and Channel 26 (2480 MHz) is large enough relative to
typical indoor coherence bandwidth that the radio path between gateway and
each sensor sees a substantially different channel response. A sensor sitting
in a destructive-interference null on Channel 15 may sit on a constructive
peak on Channel 26 — and vice versa for another sensor 30 cm away.

This is a fundamental property of indoor radio propagation and cannot be
predicted without site-specific channel measurement.

**3. Channel migration is reliable but not without risk.**

All 16 sensors successfully received the Pending Dataset announcement and
migrated to Channel 26. After the return migration, **15 of 16 sensors
reattached to Channel 15 normally**. The one exception was a marginal sensor
(baseline RSSI -89 dBm) that remained detached and required manual recovery
(battery removal/reinsertion).

This is the operational risk of channel migration: the most marginal sensors
can fail to track a channel change, particularly the **return** migration
when the network is "busier" with reattachment traffic. Plan for manual
recovery of 1–2 marginal sensors if you migrate.

### Recommendation

**Stay on the auto-assigned channel.** The gain from migrating to a "cleaner"
channel is too small to justify the risk in typical setups. The frequency-
selective fading effect means changing channels is essentially a coin flip
on whether any specific sensor benefits.

**Migrate only when:**

- You have measured documented WiFi co-channel interference (e.g., a strong
  WiFi neighbor permanently on Channel 1, 6, or 11 close to your gateway)
- All your Thread sensors are at LQI=3 with a comfortable RSSI margin (better
  than ~-75 dBm)
- You can physically reach all marginal sensors for manual recovery if needed

Migrate in this order: (1) verify all sensors are healthy, (2) execute
migration with delay 120 s, (3) wait 5 minutes after migration completes,
(4) verify all sensors still attached. If any are missing, recover them
before considering the migration successful.

---

## Phase 3 — Gateway antenna orientation

### Method

The gateway uses an internal PCB antenna (no external antenna), so changing
"antenna orientation" means physically rotating the entire gateway. Three
mutually-perpendicular orientations were tested with the gateway in the same
location, plus a control sample on return to the original position.

| Orientation | Physical position |
|:--|:--|
| A | Gateway upright, broad face parallel to a wall |
| B | Gateway upright, rotated 90° (broad face perpendicular to the same wall) |
| C | Gateway laid flat |
| A_ctrl | Returned to position A after the rotations |

Sample window: 10 minutes per orientation (5 minutes for the control), at
30-second intervals. TX power and channel held constant throughout.

### Findings

**1. No globally-best orientation.**

| Orientation | Pooled mean RSSI |
|:--|:--:|
| A (vertical, ‖ wall) | -75.9 dBm |
| B (vertical, ⊥ wall) | -75.1 dBm |
| C (flat) | -78.0 dBm |
| A_ctrl (return) | -73.4 dBm |

The pooled difference between any two orientations is within 3 dB. Position C
(flat) is marginally worse — possibly due to the antenna being closer to the
floor (a major reflector and absorber for 2.4 GHz). Positions A and B are
indistinguishable in aggregate.

**2. Per-sensor variation is large but inconsistent.**

While the *pooled* RSSI barely moves between orientations, individual sensors
show substantial variation:

- Median spread per sensor across A/B/C: **6.5 dB**
- Maximum observed spread: **16.7 dB** (a sensor very close to the gateway)
- 13 of 16 sensors had a spread > 3 dB

But the "best" orientation is **different for each sensor**. The 16 sensors
split as 7 preferring A, 5 preferring B, 4 preferring C. There is no
orientation that universally helps the marginal sensors.

This is the expected signature of a single PCB antenna interacting with
indoor multipath: each sensor's preferred orientation depends on its
position relative to the gateway and the surrounding reflectors. A
re-orientation that benefits one sensor will hurt another by roughly the
same amount.

**3. Link quality classifications were stable.**

The number of sensors at each LQI level (1, 2, or 3) was nearly identical
across all four sample windows. No orientation broke or saved any marginal
link.

**4. Antenna nulls do exist for very close sensors.**

The closest sensor (RSSI -40 dBm at position A) lost **17 dB** in position C
(flat). It remained at LQI=3 throughout, but the result confirms the PCB
antenna's radiation pattern has nulls visible at near-field distances. For
sensors a few meters away, the multipath averaging usually hides this.

### Recommendation

**Place the gateway wherever is visually and practically convenient.**
Antenna orientation has no measurable global effect in a typical home
deployment.

**One caveat — do not put the gateway against large metal objects** (fridge,
metal shelving, radiator, computer case). The metal acts as a ground plane
or reflector and creates deep nulls in the radiation pattern. Keep at least
10 cm of clearance from such surfaces.

**If a single sensor consistently underperforms** while everything else is
healthy, before moving the sensor try rotating the gateway 90° in two
different axes. The sensor's RSSI may shift by 5–10 dB in some orientation —
sometimes for the better, sometimes for the worse, but always worth a quick
empirical check before more invasive measures (relocating the sensor,
adding a Thread router, etc.).

---

## Phase 4 — Sensor orientation

### Method

A single representative sensor was selected (a Matter MYGGBETT door/window
sensor, baseline uplink RSSI ≈ −73 dBm at gateway, well attached at LQI 3)
and tested in **four physical orientations** without changing its location:

- **A** — long-axis horizontal, parallel to the corridor running toward the
  gateway
- **B** — long-axis horizontal, perpendicular to the corridor (90° rotation
  around the vertical axis)
- **C1** — long-axis vertical, front face pointing toward the gateway
- **C2** — long-axis vertical, front face pointing away from the gateway
  (180° rotation around the long-axis with respect to C1)

For each orientation: 2 minutes of stabilization, then 8 minutes of sampling
at 30 s intervals (17 samples per condition). The other 15 sensors were
monitored simultaneously to verify the test sensor was the only thing
changing in the RF environment.

Test conditions: TX = 3 dBm, channel 15, gateway in vertical reference
orientation, all other sensors static.

### Findings

**1. Orientation can change uplink RSSI by tens of dB on a single sensor.**

| Palier | Orientation | RSSI mean | LQI |
|:--:|:--|:--:|:--:|
| A | horizontal, parallel to corridor | **−73 dBm** | 3 |
| B | horizontal, perpendicular to corridor | −83 dBm | 2 |
| C1 | vertical, front toward gateway | −85 dBm | 2 |
| C2 | vertical, front away from gateway | **−95 dBm** | 1 |

Total span: **22 dB** between the best and worst orientation of the same
sensor at the same physical location. RSSI was stable within each condition
(stddev ≤ 1 dB), so this is a real orientation effect, not measurement noise.

**2. Front/back asymmetry is not negligible.**

The 10 dB gap between **C1** and **C2** — a single 180° flip around the
sensor's long axis, with no change in position — shows that the integrated
PCB antenna of this Matter sensor has a strongly asymmetric radiation
pattern. The front face is a far better radiator than the rear face when
the sensor is oriented vertically.

This effect is *intrinsic to the sensor design*, not to its environment.
A sensor placed face-against-wall is not just "blocked by the wall"; even
without obstacle, the back-side radiation is fundamentally weaker on this
device.

**3. The other 14 sensors were unaffected.**

Pooled mean RSSI of the other sensors across the four conditions: −72.4, −72.8,
−72.8, −72.8 dBm. Span: **0.4 dB**. Confirms that the 22 dB swing on the
test sensor was a property of *its own orientation*, not of an RF
environment shift triggered by handling the device.

(One marginal sensor at −94 dBm baseline was already in a yo-yo state
between attached and detached during this test window; it did not influence
the conclusion.)

### Implication for users

For Matter sensors with internal PCB antennas, **orientation matters as
much as TX power and far more than channel choice**. A sensor mounted
"the wrong way" can lose 20+ dB without anyone noticing — until the link
breaks.

Practical guidance:

- **For each sensor, prefer a horizontal long-axis pointing toward the
  most direct line of sight to the gateway.** This was reliably the best
  orientation in the test deployment.
- **Avoid mounting sensors face-against-wall when their long-axis is
  vertical.** Whenever possible, keep the front face exposed.
- If a marginal sensor is hard to fix by relocating, **try rotating it in
  place**. A 5–15 dB improvement is often available essentially for free.

This is a per-sensor-model result; sensors with external antennas, or
different vendors' implementations, may behave differently. But the
underlying mechanism — asymmetric integrated antennas — is common across
small Thread devices, so the principle generalises.

---

## Validation soak at TX = 3 dBm

### Method

After the three sweep phases, the gateway was left running for 12 hours at
the recommended configuration (TX = 3 dBm, channel 15, vertical orientation
parallel to the street wall) with the same 16 sensors deployed in their
final positions. Per-child RSSI/LQI was sampled every 5 minutes; gateway
health (CPU load, memory, UART error counters, Ethernet error counters,
Thread state) was sampled every minute.

The goal was to validate that the recommendation holds beyond the brief
sampling windows of the sweep phases — specifically, to look for natural
detach events, RSSI drift, RF interference bursts, and any drift in
gateway-side resource usage.

### Findings

**1. Mesh stability — 16/16 children held continuously for 9 h 45 min.**

After a 2 h 20 min warm-up during which the weakest sensor (uplink RSSI
−94 dBm, LQI = 1) was unattached, all 16 sensors were attached
continuously through the rest of the soak. **Zero spontaneous detach
events** occurred for the 15 sensors that started attached.

The marginal sensor (uplink RSSI between −97 and −92 dBm, average LQI
0.99) attached at the 2 h 20 min mark and remained attached for the rest
of the run. This is the practical lower bound at TX = 3 dBm in this
deployment: a sensor consistently below −92 dBm is "on the edge" and may
take minutes to attach, but once attached can be stable.

**2. RF environment — extremely stable, no interference bursts.**

Per-sensor RSSI standard deviation across the 12 h:

| Sensors | Std-dev range |
|:--|:--|
| 14 of 16 | 0–1 dB |
| 1 (Matter-IKEA, session re-attach mid-night) | 2.2 dB |
| 1 (marginal at −94 dBm) | 0.9 dB |

No cycle had a mesh-wide mean RSSI deviation ≥ 1 dB. 123 of 145 cycles
were within ±0.25 dB of the per-sensor mean. The largest single-cycle
mean deviation was 0.67 dB. **No synchronised dips** that would indicate
WiFi/microwave bursts were observed.

**3. Gateway resources — flat over 12 h.**

| Metric | Value |
|:--|:--|
| CPU load (1 min avg) | 0.04 average, 0.39 peak |
| Free memory drift | 176 KB band, no leak signature |
| UART1 frame/overrun/parity errors | 0 / 0 / 0 over 725 samples |
| Ethernet RX/TX errors | 0 / 0 |
| Thread role | `leader` for 100% of samples |

The in-kernel UART↔TCP bridge handled the entire night without a single
frame error. No `otbr-agent` or `matter-server` restarts were needed.

### Implication for users

The TX = 3 dBm recommendation is robust over a long observation window
in this deployment. If your weakest sensor sits below ≈ −92 dBm uplink
RSSI at TX = 3 dBm, expect occasional reattach delays and consider
TX = 5 dBm for that sensor's sake (it is the *downlink* margin that
helps it stay attached, not the uplink RSSI you can see).

---

## Caveats

1. **Topology specificity.** This test ran with a single Thread Border Router
   (the gateway itself) and 16 children — no intermediate routers, no FTDs.
   In a multi-router mesh, TX power has additional effects (parent selection,
   route quality), and the conclusions above may not apply directly.

2. **Time-bounded RF environment.** The measurements were taken during a
   relatively quiet RF window. WiFi traffic, microwave usage, and other
   2.4 GHz activity vary throughout the day. The Channel 15 vs 26 finding
   may differ in households with heavier WiFi load.

3. **Uplink-only RSSI.** RSSI is measured at the gateway from incoming sensor
   frames. The downlink (gateway → sensor) is invisible to direct measurement;
   we infer its quality only through detach events.

4. **Single home, single setup.** N=1 study. Treat findings as indicative,
   not as definitive thresholds. Your home will differ.

## Recipes

### Recipe 1 — Changing TX power

```sh
# Set the new value (rounds to nearest calibrated step: 0, 1, 3, 5, 7, 10 dBm)
ot-ctl txpower 3

# Read back what the radio actually applied
ot-ctl txpower
```

To make the change persistent across reboots, edit the `txpower` line in
`/userdata/etc/init.d/S70otbr` (the line that runs `ot-ctl txpower N` shortly
after `otbr-agent` startup).

### Recipe 2 — Migrating to a different Thread channel

The Thread Pending Operational Dataset mechanism propagates the channel
change to all devices simultaneously, so they switch in lockstep at the
delay time. Without this, sensors would detach as the gateway switches and
they don't.

```sh
#!/bin/sh
# migrate_channel.sh — change the Thread network channel
# Usage: migrate_channel.sh <new_channel>   (valid range 11..26)

NEW_CH="$1"
[ -z "$NEW_CH" ] && { echo "usage: $0 <11..26>" >&2; exit 1; }

NOW_US=$(date +%s)000000
ACTIVE_US=$(($(date +%s) + 300))000000

ot-ctl dataset init active                 # copy current dataset to pending
ot-ctl dataset channel "$NEW_CH"           # change just the channel
ot-ctl dataset pendingtimestamp "$NOW_US"  # "now" reference
ot-ctl dataset activetimestamp "$ACTIVE_US" # bump active timestamp
ot-ctl dataset delay 120000                # devices commit in 120 s
ot-ctl dataset commit pending              # publish to the network

echo "Channel migration to $NEW_CH announced; switchover in 120 s"
echo "Wait ~3 minutes, then verify with: ot-ctl channel"
echo "Then check all sensors are still attached: ot-ctl child table"
```

After the migration, **always verify** all sensors reattached. If 1–2 are
missing, see Recipe 3 to recover them.

### Recipe 3 — Recovering a stuck Matter sensor

After a gateway reboot, a channel migration, or any disruptive event, some
Matter sensors may stop reporting in Home Assistant even though they are
visible at the Thread layer. Symptoms:

- Entity is `unavailable` in HA but the device is alive
- `matter-server` logs show `Subscription failed CHIP Error 0x32 Timeout`
- The sensor is missing from `ot-ctl srp server host` output, or has it
  but is not in `ot-ctl child table`

Cause: the gateway's SRP server (used for Matter device discovery) loses
its records on restart, but the sensor's local SRP-client thinks its
registration lease is still valid (default 2-hour lease). The sensor
doesn't push a fresh record, so Home Assistant cannot discover its IPv6
address and re-establish the Matter session.

Three recovery options, ordered from cheapest to most disruptive. **Try
them in order**; only escalate when the previous step did not work.

#### Step 1 — SRP server reset (no physical action)

```sh
ssh root@192.168.1.88 'ot-ctl srp server disable && sleep 30 && ot-ctl srp server enable'
```

This clears the gateway's SRP server table for ~30 seconds. Sensors that
re-publish during this window discover the freshly-reset server and push
a clean SRP record, which makes them visible again to `matter-server`.

Observed behaviour on a 16-sensor home (1 Border Router, no leaf routers):

- All sensors that were Thread-attached re-published their SRP record
  within 1 to 2 minutes.
- Zero attached sensors were lost during the reset.
- Of three sensors that were stuck before the reset, **one recovered
  fully** (reattached at the Thread layer and re-published SRP); two
  remained silent (probably because they were also out of RF reach
  after the gateway moved). Your hit rate will depend on whether the
  stuck sensor wakes up to poll during the 30 s window.

The reset is safe: the entire mesh re-publishes within minutes, no Matter
session is destroyed, no commissioning state is lost.

#### Step 2 — Long battery pull (≥ 60 s)

If the SRP server reset did not recover a specific sensor:

1. Remove the battery.
2. Wait **at least 60 seconds** (longer is safer; 2 minutes is plenty).
   Short battery pulls (< 30 s) often fail because capacitors keep the
   device's RAM state alive long enough that no re-registration happens
   on power-on.
3. Reinsert the battery.

The device boots fresh, re-discovers the Thread network, and pushes a
new SRP record. Works often, but is hit-or-miss depending on firmware
behaviour. Combine with Step 1 (SRP reset on the gateway in parallel)
to maximise the chance of a clean re-registration.

#### Step 3 — Delete and re-pair

If neither Step 1 nor Step 2 recovered the sensor, the universal fix is
to delete and re-pair:

1. Open Home Assistant → Settings → Devices & Services → Matter
2. Find the silent device → kebab menu (⋮) → **Delete**
3. Re-pair using the physical commissioning button + Matter QR code,
   the same way you originally paired it

The re-pair completes in 30 to 90 seconds. The device gets a fresh
Matter node-id, a fresh SRP key, a fresh SRP record, and resumes
reporting immediately.

#### What does NOT reliably work

- **Restarting `matter-server`** — only helps devices that are already
  SRP-registered; truly stuck sensors stay stuck.
- **Waiting** — the SRP lease is typically 2 hours, but some clients
  only refresh near the much longer key-lease expiry (~7 days).
- **Short battery pulls** (< 30 s) — see Step 2.

#### Underlying issue

`otbr-agent`'s SRP server keeps its table in RAM, so a gateway restart
loses every record. The standard SRP client behaviour does not detect
the loss until its own lease expires. Step 1 above is a workaround that
forces a synchronisation; a proper upstream fix would persist the SRP
table to flash.

## Methodology notes

If you want to reproduce these tests in your own deployment:

- The gateway exposes `ot-ctl` for setting TX power (`ot-ctl txpower <N>`)
  and querying mesh state (`ot-ctl child table`, `ot-ctl neighbor table`)
- Per-sensor RSSI/LQI is in `ot-ctl neighbor table` (gateway-side measurement)
- The published [`thread-range-test`](gateway/thread-range-test) command
  reproduces the sampling, TX-power, channel, and orientation experiments.
  It polls the neighbor table at fixed intervals, logs per-child RSSI/LQI to
  CSV, and restores the safe TX-power or original channel where applicable.
- [`analyze-results.py`](analysis/analyze-results.py) aggregates the CSV files
  offline and can optionally apply Home Assistant device labels.

If you find your sensors detaching frequently or behaving differently from
this report, please open a GitHub Discussion with your topology details
(sensor count, distance to gateway, WiFi environment, observed RSSI ranges).
The Thread mesh is a living system and community data improves the defaults.
