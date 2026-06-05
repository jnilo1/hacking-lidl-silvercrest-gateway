# Changelog — Zigbee Radio / Silabs EFR32 (Lidl Silvercrest Gateway)

All notable changes to the EFR32 firmware and tooling are documented here.

---

## [3.8.0] - 2026-06-02

Companion entry to the [v3.8.0 RTL8196E
release](../3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md#380---2026-06-02).
**No EFR32 firmware change** — same `.gbl` artefacts as before. The
host-side RCP stack (`cpcd`) gains a native TCP bus, plus two tooling
fixes.

### `cpcd` — native TCP bus (drops the `socat` PTY shim)

`cpcd` only spoke `bus_type: UART`/`SPI`, so the RCP host stack put a
`socat` in front of it to turn the gateway's in-kernel UART↔TCP bridge
(`TCP:8888`) into a PTY (`/tmp/ttyCpcRcp`). On any TCP blip that `socat`
recreated the PTY, `cpcd`'s serial fd went stale, and `cpcd` + `zigbeed`
had to restart in cascade.

A native `bus_type: TCP` lets `cpcd` dial the bridge directly and own its
own reconnection — no `socat` shim, no stale-PTY restart cascade. Because
a bridge drop loses only the host-side TCP (not the EFR32), the CPC
reliability layer (sequence numbers + ACK + RTO retransmit) recovers the
gap when the link returns: the session resumes with sequence continuity,
no secondary reset, no daemon restart.

Validated against a live EFR32MG1B RCP: the full CPC handshake completes
over the TCP bus, and a mid-session link drop (bridge disarm/re-arm) is
recovered transparently with NOOP keep-alives flowing straight through.

* The cpcd source is a gitignored build clone, so the change is carried as
  `25-RCP-UART-HW/cpcd/tcp-bus.patch` (cpcd v4.5.3) and applied
  idempotently by `build_cpcd.sh` (mirrors the existing `cmakeLists.patch`
  flow). New config keys: `bus_type: TCP`, `tcp_server_address`,
  `tcp_server_port`.
* The Docker stack (`25-RCP-UART-HW/docker/cpcd-zigbeed/`) is wired for it:
  `cpcd.conf.template` uses `bus_type: TCP` and `supervisord.conf` no
  longer runs a `socat-cpc` program. The `Dockerfile.multiarch` builder
  now `git apply`s `tcp-bus.patch` onto its cpcd v4.5.3 clone, so the
  image ships the same patched `cpcd` as the host build — without it the
  image would bundle a stock `cpcd` that rejects `bus_type: TCP` and fail
  to start. The build context is widened to `25-RCP-UART-HW/` (with a
  `.dockerignore` keeping it minimal) so the Dockerfile can reach the
  single-source patch; the CI workflow's `context:` is repointed to match.
  Set `bus_type: UART` with `uart_device_file` to fall back to the classic
  socat-PTY path.
* The native `rcp-stack` (systemd `--user`) flow is migrated too: it
  generates a `bus_type: TCP` `cpcd.conf` from `RCP_ENDPOINT` and the
  `socat-cpc-rcp.service` PTY shim (and its `rcp-socat-rcp` helper) are
  removed — `cpcd-bringup.service` now dials the gateway directly. The
  downstream `socat-zigbeed-pty` (zigbeed↔Z2M) is unchanged.

### `flash_efr32.sh` — false-negative on the post-flash `radio.conf` write

For RCP/NCP/Router flashes (where the `MODE=` line is empty), the SSH
command that rewrites `/userdata/etc/radio.conf` ended in a brace group
whose last statement was `[ -n '' ] && echo` — which exits 1. The whole
remote command returned non-zero, so the script printed "failed to write
/userdata/etc/radio.conf" and aborted before rebooting, even though the
`sed` + appends had all succeeded and `radio.conf` was correct.

Fix: the optional-key lines now use `if … fi` (returns 0 when the key is
absent). Genuine SSH transport failures still surface (`ssh` returns 255).

### `cpcd.conf` — drop the unrecognized `socket_folder` key

cpcd v4.5.3 has no config-file parser for `socket_folder`; it is set only
at build time from `CPC_SOCKET_DIR` (`/dev/shm`) and the per-instance
socket path is hardcoded as `<socket_folder>/cpcd/<instance_name>/`. Every
`cpcd.conf` that set `socket_folder` therefore got a "key not recognized"
warning and the value was silently ignored (and would have double-nested
the path if it had been honoured). The dead line is removed from the three
places that emitted it — the Docker template, the `rcp-stack` example, and
`rcp-stack`'s generated conf — with a comment so it is not re-added. Inert:
the `/dev/shm` default already yields the documented
`/dev/shm/cpcd/<instance>/` path.

### Docker `socat-zigbeed` — one Z2M client at a time

The container exports the shared zigbeed PTY to Z2M over TCP with
`socat tcp-listen:9999,…,fork`, which forks a handler per connection. Two
overlapping Z2M connections (e.g. a Z2M restart racing the old session)
both relayed onto the same PTY, interleaving bytes and corrupting the EZSP
stream — the multi-PID-over-shared-PTY failure seen in Discussion #112.
Adding `max-children=1` keeps the listener alive (so reconnects still work)
but stops it accepting while a client is connected; a second connection is
queued and served only once the active one closes.

* `25-RCP-UART-HW/cpcd/tcp-bus.patch`, `25-RCP-UART-HW/cpcd/build_cpcd.sh`
* `25-RCP-UART-HW/docker/cpcd-zigbeed/{cpcd.conf.template,supervisord.conf}`
* `25-RCP-UART-HW/rcp-stack/examples/cpcd.conf.example`,
  `25-RCP-UART-HW/rcp-stack/bin/rcp-stack`
* `25-RCP-UART-HW/README.md`, `25-RCP-UART-HW/EMBERZNET-8.x-GUIDE.md`
* `flash_efr32.sh`

---

## [3.4.1] - 2026-05-02

Companion entry to the [v3.4.1 RTL8196E
release](../3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md#341---2026-05-02).
**No EFR32 firmware change** — same `.gbl` artefacts as v3.4.0. One
`flash_efr32.sh` fix.

### `flash_efr32.sh` — silent abort when USF doesn't log the bootloader version (#96)

Reported by @frtz13 on a fresh `ncp → otrcp` flash. Symptoms: USF
uploaded the GBL cleanly to 100 %, then the script printed "Flash did
not complete successfully" and left `/userdata/etc/radio.conf` with
the previous `FIRMWARE_BAUD` — the gateway booted at the wrong baud
on the next reboot.

Root cause: the post-flash step that persists `BOOTLOADER_VERSION` to
`radio.conf` greps USF's log for `Detected bootloader version 'X.Y.Z'`.
USF only emits that line when the chip is already in the Gecko
Bootloader at probe time (or when `--bootloader-reset` wired up an
external GPIO/RTS-DTR entry). On the common app→bootloader transition
path (running NCP/RCP/OT-RCP → `launchStandaloneBootloader` → upload),
the version is detected internally but never logged at INFO. The grep
returns 1, `set -euo pipefail` propagates that out of the command
substitution, and the script aborts *before* writing `radio.conf`.

Fix: `|| true` on the grep | tail | sed pipeline so a missing version
line is treated as "version unknown" instead of a fatal error. The
`radio.conf` write proceeds regardless, just without the
`BOOTLOADER_VERSION=` key on this path.

The comment block above the grep is also updated — the previous text
claimed USF emits the line "every time it enters the bootloader",
which was wrong and misled the original change.

### `26-OT-RCP/range-testing/` — Thread mesh range-test toolset and field-test report

Reusable scripts plus a written report for users who want to characterise
their own deployment instead of relying on defaults:

* `gateway/range_test.sh` — generic per-cycle CSV sampler driven by
  `ot-ctl neighbor table`; one invocation = one experimental palier.
* `gateway/phase1_tx_sweep.sh` — TX power sweep with abort-on-detach
  safety, restoring TX to a known-good value on exit.
* `gateway/phase2_channel_migration.sh` — Thread channel migration via
  Pending Operational Dataset, including a back-migration control sample.
* `gateway/orientation_runner.sh` — operator-paced orientation runner
  for either gateway-antenna or sensor-body rotation tests.
* `gateway/healthmon.sh` — opt-in host-side health sampler (memory, CPU
  load, UART1 error counters on the OT-RCP link, Thread role and child
  count, Ethernet errors) at 1 Hz/min. Not a permanent service; users
  start it before a long test and stop it after.
* `analysis/ha_matter_map.py` — bridges HA Matter friendly labels with
  Thread `ext_mac` via the HA WebSocket API (Matter rotates the
  `ext_mac` at every commissioning, so labels can't be inferred from
  the mesh alone).
* `analysis/analyze.py` — pure-stdlib stats (n, mean, median, stddev,
  min/max, mean LQI) per palier and per sensor.

`REPORT.md` documents a 16-sensor home deployment across four phases
(TX power, channel, gateway orientation, sensor orientation) plus a
12 h validation soak. Headline takeaways: TX = 3 dBm carries enough
margin for typical homes, channel choice has sub-dB pooled effect, and
sensor orientation alone can move the uplink RSSI by 22 dB on a single
Matter device — the largest single-axis effect observed in the run.

Recipe 3 ("Recovering a stuck Matter sensor") now leads with a
**non-physical, non-destructive first step** that an SSH into the
gateway can do: `ot-ctl srp server disable && sleep 30 && ot-ctl srp
server enable`. Validated on a 16-sensor run: zero attached sensors
lost, all attached sensors re-publish their SRP record within 1–2 min,
and a fraction of stuck sensors recover in the process. Battery pull
and HA delete+re-pair remain documented as Step 2 and Step 3.

Added `gateway/ha_link_publisher.sh` (+ annotated conf template) — an
opt-in BusyBox shell daemon that polls `ot-ctl neighbor table` at a
configurable interval and pushes one HA entity per Thread child via the
HA REST API: `sensor.thread_<slug>_rssi` with state = avg uplink RSSI
(dBm) and attributes for LQI, last-seen age, RLOC, ext_mac and an
attached/detached flag. Detached devices keep their HA entity alive with
a growing `age_s` so dashboards can flag stale links. Resource footprint
at 60 s cadence with 16 sensors: ~1 % CPU, ~500 KB transient RSS,
~24 MB/day HA traffic, **zero JFFS2 wear** (push-only, no local logs) —
lighter than `healthmon.sh`.

An optional auto-start init script
`gateway/examples/S75ha_link_publisher` is shipped alongside (not in
the default rootfs skeleton — install per-gateway). It is gated on
`/userdata/etc/ha_link_publisher.conf` being present, so it stays inert
on a gateway that does not use the publisher.

## [3.4.0] - 2026-05-01

Companion entry to the [v3.4.0 RTL8196E
release](../3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md#340---2026-05-01).
**No EFR32 firmware change** — same `.gbl` artefacts as v3.3.0 for NCP /
RCP / OT-RCP / Router / Bootloader. No tooling change in this directory
either; `flash_efr32.sh` is unchanged.

The release on the gateway side is a kernel-driver hardening pass plus a
perf tuning that lowers the latency tail on the UART1 path used by the
EFR32 radio. Re-flashing the radio is **not** required for the upgrade.

### Why this matters here even with no firmware change

The kernel `irq-rtl819x` driver now routes UART1 (the line carrying the
Spinel / EZSP / CPC traffic to this chip) on MIPS IP4 instead of IP3, so
under simultaneous Ethernet + radio activity the UART RX ISR runs first.
At 460800 baud with the 16-byte RX FIFO that absorbs ~350 µs of latency
budget, the change makes the gateway slightly more tolerant to bursts
during heavy LAN traffic — particularly during Matter commissioning
attestation while the host is doing iperf-class TCP at the same time.
Validated with an overnight OT-RCP soak: zero overruns on `ttyS1` over
8h+, two paired Sleepy End Devices stable.

The `8250_rtl819x` driver fixes from v3.3.0 (`MCR_AFE` plumbing for #89)
are unchanged.

---

## [3.3.0] - 2026-04-30

Companion entry to the [v3.3.0 RTL8196E
release](../3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md#330---2026-04-30).
The EFR32 firmwares are unchanged from v3.2.x — same `.gbl` artefacts —
but tooling and host-side integration changed substantially.

### `flash_efr32.sh` — refactor (TODO-v3.3 #1, #2, #5)

* **Bridge ↔ `radio.conf` reconciliation** — switching modes by
  editing `radio.conf` no longer requires manual sysfs rearm.
* **Symmetric baud-fallback sweep** `{115200, 230400, 460800, 691200,
  892857}` — chip auto-detected even when `radio.conf` is stale, in
  either direction.
* **`--firmware-file PATH`** for explicit GBL selection; refuses
  ambiguous matches (used to silently pick newest by mtime).
* **USF venv version pin sanity check** — abort on drift.
* **`assert_bridge_idle()`** + read-back-verified sysfs writes.

### Documentation

- [`26-OT-RCP/README.md`](26-OT-RCP/README.md) "Hardware flow control"
  note expanded to document the v3.3.0 root-cause fix for
  [#89](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/issues/89):
  the host-side `&uart-flow-control=true` in `S70otbr`'s spinel radio
  URL is required for reliable operation at 460800 — the EFR32 firmware
  always had RTS/CTS enabled, but without the host flag the kernel
  UART would not engage `MCR_AFE` and the RX FIFO could overrun.

---

## [3.1.1] - 2026-04-27

Companion entry to the [v3.1.1 RTL8196E
release](../3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md#311---2026-04-27)
— the heavy lifting (kernel UART-bridge hardening,
`flash_efr32.sh` TCP-client safety check, `radio.conf`
simplification) lives there. EFR32 side has only documentation
cleanups in this cycle.

### Documentation

- `23-Bootloader-UART-Xmodem/firmware/README.md` — drop the dead
  link to the unshipped Stage-2-only
  `bootloader-uart-xmodem-2.4.2.s37` (`*.s37` is gitignored except
  the `-combined.s37` artefact, see commit `7d67772`); replaced with
  a "build it locally" pointer. Restored a green `mkdocs --strict`
  CI build.
- Per-firmware READMEs (`24-NCP`, `25-RCP`, `26-OT-RCP`, `27-Router`)
  + the top-level `README.md` updated for the new single-key
  `radio.conf` model: `FIRMWARE_BAUD` is now the canonical baud
  reference (chip-side = host-side, since both ends of the UART
  link must agree). Legacy `BRIDGE_BAUD` / `OTBR_BAUD` references
  removed from user-facing prose; `flash_efr32.sh` stops emitting
  them and strips them from existing configs on every flash.
- `26-OT-RCP/docker/README.md` — three-case switching recipe
  (ZoH / OTBR-host / OTBR-gateway) collapses to a one-line `sed`
  flipping `MODE=otbr` on/off; no more `BRIDGE_BAUD` ↔ `OTBR_BAUD`
  swap.

---

## [3.1.0] - 2026-04-26

Build matrix and documentation pass. Each per-firmware `build_*.sh`
script now takes the UART baud as a positional argument and emits
baud-aware filenames so multiple bauds can coexist in `firmware/`. A
new top-level `make-all-bauds.sh` builds the full matrix in one run.
Pre-built artefacts ship for every supported baud point so users
without a Silabs toolchain can flash any combination directly. The
companion `flash_efr32.sh` (top-level, see
`../3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md` for the full refactor
notes) resolves the right `.gbl` via a glob — no more EmberZNet SDK
lookup.

### Build matrix

- Per-firmware build scripts (`build_ncp.sh`, `build_rcp.sh`,
  `build_ot_rcp.sh`, `build_router.sh`) take an optional positional
  baud:
  ```
  ./build_ncp.sh                # default per-firmware baud
  ./build_ncp.sh 460800         # explicit override
  ```
- Output `.gbl` / `.s37` filenames embed the baud:
  ```
  ncp-uart-hw-7.5.1-<baud>.gbl
  rcp-uart-802154-<baud>.gbl
  ot-rcp-<baud>.gbl
  z3-router-7.5.1-<baud>.gbl
  ```
- New `make-all-bauds.sh` wrapper builds all variants in one run
  (NCP×5, RCP×3, OT-RCP×1, Router×1), idempotent (skips files that
  already exist), with `--force` and `--list` options.

### Pre-built firmware shipped

| Firmware | Baud points |
|---|---|
| NCP-UART-HW (7.5.1) | 115200 / 230400 / 460800 / 691200 / 892857 |
| RCP-UART-HW | 115200 / 230400 / 460800 *(cpcd POSIX baud ceiling)* |
| OT-RCP | 460800 *(matches OpenThread default)* |
| Z3 Router (7.5.1) | 115200 *(no UART data path)* |

End-to-end validated on hardware against Z2M (NCP & RCP), the ZoH
adapter (OT-RCP bridge mode), `otbr-agent` in Docker, and on-gateway
`otbr-agent`.

### `firmware/` directory cleanup

Two batches of dead weight removed from the per-firmware `firmware/`
directories:

* **Unshipped `.s37` artefacts** — every per-firmware build emits
  both `.gbl` (UART/OTA path) and `.s37` (J-Link/SWD path), but only
  the *combined-bootloader* `.s37` is end-to-end useful for users
  (the one-shot J-Link image to install Stage 1 + Stage 2 on a virgin
  chip). Dropped 15 orphan `.s37` files (~1.4 MiB) from `23-`, `24-`,
  `25-`, `26-`, `27-` and tightened `.gitignore` so future builds
  don't re-introduce them. Kept:
  `23-Bootloader-UART-Xmodem/firmware/bootloader-uart-xmodem-2.4.2-combined.s37`.

* **Pre-v3.0 manual-flash legacy in `24-NCP-UART-HW/firmware/`** —
  the directory still carried `flash_ezsp{7,8,13}.sh` plus a MIPS
  `sx` xmodem-send binary (~166 KiB) from the pre-v3.0 workflow
  (scp the script to the gateway, push the `.gbl` over `sx` on the
  serial line). Replaced end-to-end by the repo-root `flash_efr32.sh`
  driving `universal-silabs-flasher` over the in-kernel UART bridge —
  these scripts have been unreachable from the docs since v3.0.
  Removed.

### `POST-MORTEM-bootloader-recovery.md`

New top-of-tree post-mortem documenting why a hardware `nRST` pulse
on the EFR32 cannot enter the Gecko Bootloader on this gateway, and
what was tried:

- PIN reset always boots the application slot — Gecko Stage-2 only
  enters its UART menu on `SYSREQ`+magic or a `BTL_GPIO_ACTIVATION`
  pin pulled by the host, neither of which is wired on the Lidl PCB.
- `PB11` (the canonical `BTL_GPIO_ACTIVATION` pin in old Gecko
  bootloaders) was checked empirically — not routed to the RTL8196E.
- Tuya stock firmware confirms the limit: zero `/sys/class/gpio`
  references, recovery is software-only via
  `ezspLaunchStandaloneBootloader`.

Lists two untested alternative paths (A: chip-reset on every reboot;
B: `PA5`/CTS as `BTL_GPIO_ACTIVATION`) for future work — Alternative
A landed in v3.1 (see RTL8196E CHANGELOG); B is parked.

### Documentation

- Per-firmware READMEs (`24-NCP`, `25-RCP`, `26-OT-RCP`, `27-Router`)
  rewritten for v3.1: new `flash_efr32.sh` CLI, baud-aware
  filenames, gateway-side `radio.conf` keys (`MODE`, `BRIDGE_BAUD`,
  `OTBR_BAUD`) plus the new chip-identity keys (`FIRMWARE`,
  `FIRMWARE_VERSION`, `FIRMWARE_BAUD`) shown in every "Gateway state
  after flash" snippet.
- `2-Zigbee-Radio-Silabs-EFR32/README.md` adds a "Gateway-side
  runtime configuration" section, a per-firmware supported-baud
  table, and splits the `radio.conf` keys into "chip-identity" vs
  "daemon-routing" so readers see at a glance what's informational
  vs operational.
- `22-Backup-Flash-Restore/README.md` and
  `23-Bootloader-UART-Xmodem/README.md` refreshed (USF probe-methods
  patch reference; chained bootloader+app flash walkthrough).
- `26-OT-RCP/docker/README.md` lays out the three OT-RCP use cases
  side-by-side with their gateway-side configuration; emphasises
  that all three share `FIRMWARE=otrcp` (the chip is the same; only
  the daemon-routing keys differ).
- `25-RCP` and `26-OT-RCP` Z2M `configuration.yaml` examples now
  externalise the device list (`devices: devices.yaml`) like 24-NCP
  does — keeps personal IEEE addresses out of git.

> Canonical full reference for `radio.conf` keys (including the new
> `FIRMWARE` / `FIRMWARE_VERSION` / `FIRMWARE_BAUD`) lives in
> [`../3-Main-SoC-Realtek-RTL8196E/34-Userdata/README.md`](../3-Main-SoC-Realtek-RTL8196E/34-Userdata/README.md#radioconf-keys-full-reference);
> per-firmware READMEs link to it instead of duplicating.

---

## [3.0.0] - 2026-04-16

### UART baud rates — 230400 ceiling removed

The long-standing 230400 baud limit has been eliminated across all
firmwares. The root cause was an RTL8196E UART divisor N+1 quirk (see
`3-Main-SoC-Realtek-RTL8196E/32-Kernel/POST-MORTEM-6.18.md`), not
userspace latency as previously believed.

**Tested baud rates with zero framing/overrun errors:**

| Firmware | Default baud | Max tested | Transport |
|----------|-------------|------------|-----------|
| NCP-UART-HW | 115200 | 892857 | in-kernel UART↔TCP bridge |
| RCP-UART-HW | **460800** | 460800 | cpcd via in-kernel UART↔TCP bridge (cpcd has no 892857 support) |
| OT-RCP | **460800** | 460800 | otbr-agent (direct UART, on-gateway) |
| Router | 115200 | N/A | No UART data path |

### 26-OT-RCP
- **Default baud raised to 460800** — aligns with OpenThread's own
  default. Firmware, S70otbr init script, docker compose, and all
  documentation updated. OTBR users get 4× throughput with no
  configuration change.
- Pre-built firmware rebuilt at 460800.

### 24-NCP-UART-HW
- **Firmware rebuilt at 460800** for testing (committed earlier on
  `kernel-6.18` branch). Default distribution remains 115200; power
  users can rebuild at up to 892857 and set the in-kernel UART bridge
  baud to match via `/userdata/etc/radio.conf:BRIDGE_BAUD=`.
- Z2M `configuration.yaml` updated with `baudrate: 460800`.

### flash_efr32.sh
- **Flash any firmware from any baud/mode state.** The script now handles
  all transitions (NCP↔OT-RCP↔RCP) regardless of the current firmware
  baud rate (115200–892857).
- **Smart detection via radio.conf**: reads the persistent radio mode
  (`MODE=otbr` → Spinel@460800) and `BRIDGE_BAUD=` to pick the right
  probe speed, instead of relying on `ps | grep` (which missed crashed
  daemons on the old serialgateway-based path).
- **Targeted probing**: OT-RCP probes `spinel:460800` only (~15ms);
  NCP/RCP probes `ezsp`+`cpc` at detected baud. No more 30s full scan.
- **FailedToEnterBootloaderError recovery**: when USF detects the
  firmware and enters the Gecko Bootloader (baud changes to 115200),
  the script automatically switches the in-kernel bridge to 115200
  (flow control off) and flashes via `bootloader:115200`.
- **TCP port readiness**: `wait_for_port` polls TCP:8888 after every
  bridge reconfiguration, replacing fragile `sleep 1`. Prevents USF
  `AssertionError` crashes on unstable connections.
- **USF probe retry**: transient transport errors (TCP not fully ready)
  trigger one automatic retry instead of aborting.
- **radio.conf cleanup**: NCP/RCP/Router flash deletes radio.conf
  (`rm -f`) instead of leaving a 0-byte ghost file.
- **USF probe patch regenerated**: all bauds 115200–892857 for EZSP,
  Spinel, and CPC protocols.

### 25-RCP-UART-HW
- **RCP@460800 validated**: pre-built firmware rebuilt at 460800 baud.
  Tested with cpcd 4.5.3 + zigbeed 8.2.2 (EZSP v18) + Z2M. cpcd
  does not support non-standard bauds (892857), so 460800 is the RCP
  maximum.
- **Simplicity SDK 2025.6.2 → 2025.6.3**: zigbeed build updated to
  latest patch (Feb 2026). End-device move delay config, Green Power
  fixes. EmberZNet stays 8.2.2 (build 436→532), EZSP v18.
- **Removed MEMO-uart-bridge-kernel.md** — kept on `kernel-6.18` branch.

### 25-RCP-UART-HW — multipan POC explored, tested, dropped

A Zigbee + Thread multipan Docker stack (cpcd + zigbeed on IID=1 +
otbr-agent on IID=2) was drafted and added to the tree during v3.0
dev. End-to-end test on hardware: cpcd connects, zigbeed attaches on
IID=1 (EZSP v18), but **otbr-agent fails on IID=2** with
`GetIidListFromUrl: InvalidArgument`. Root cause is a hardware limit —
Silicon Labs' Concurrent Multiprotocol (CMP, concurrent Zigbee + Thread
on one radio) is a **Series 2-only** feature; our EFR32MG1B is
Series 1 and only supports Dynamic Multiprotocol (BLE + one of
Zigbee/Thread, never both 15.4 protocols together). GSDK 4.5.0 has no
multi-PAN RCP sample for MG1B.

Since the gateway's hardware will never change, the whole POC was
dropped: `docker-compose-multipan.yml`,
`cpcd-zigbeed-otbr/Dockerfile.multiarch`,
`z2m/configuration-multipan.yaml`, and the CI workflow that built
`:poc`. A short `cpcd-zigbeed-otbr/README.md` remains as a tombstone
pointing at the working single-protocol paths
(Zigbee via `docker-compose-zigbee.yml`, Matter-over-Thread via
`../../26-OT-RCP/docker/docker-compose-otbr-host.yml`).

### Firmware rebuild against v3.0 sources

All five firmwares rebuilt against the current sources (GSDK 4.5.0 +
ARM GCC 12.2). Stage 2 bootloader `.gbl`/`.s37`, NCP and Router
produce **bit-identical binaries** (deterministic build, sources
unchanged). RCP and OT-RCP pick up a +88 B delta coming from the
`.slcp` baudrate cleanup below. The Stage 2+Stage 1 combined `.s37`
sees a small metadata-only delta.

### 25-RCP, 26-OT-RCP — .slcp baudrate realigned with .h override

In `rcp-uart-802154.slcp` and `ot-rcp.slcp`, the `BAUDRATE` config
value was 115200 at the `.slcp` level but 460800 in the `.h` patches
that overlay the generated config. The `.h` wins at compile time, so
runtime was already 460800 — but the two layers disagreeing misled
anyone reading the `.slcp`. Normalised to 460800 on both; the Silabs
Configuration Wizard `<i> Default: 115200` hints are kept since they
legitimately document the upstream SDK default.

### 24-NCP-UART-HW — Z2M device list externalised

- `z2m/configuration.yaml` no longer carries a hard-coded `devices:`
  block; the list lives in a separate `devices.yaml`. Device-roster
  updates no longer churn the main config.
- Unused `baudrate:` dropped from the Z2M config (inherited from the
  serial adapter URL).

### Tooling

- `25-RCP-UART-HW/patches/measure_uart_overruns.sh` — dev helper that
  reads UART framing/overrun counters via sysfs during RCP stress tests.

### Documentation
- All firmware READMEs (24-NCP, 25-RCP, 26-OT-RCP, 27-Router) updated:
  replaced "460800+ not supported" with full baud rate table; removed
  all references to in-kernel UART bridge.
- EMBERZNET-8.x-GUIDE.md: removed "overruns" warning.

---

## [2.1.5] - 2026-04-04

### 26-OT-RCP (OTBR on gateway)
- **HA REST API: PascalCase kept**. `python-otbr-api` 2.9.0 (HA 2026.4)
  still sends PascalCase in PUT requests — upstream camelCase `otbr-agent`
  rejects them. PascalCase `otbr-agent` works with all HA versions.
  See [python-otbr-api#238](https://github.com/home-assistant-libs/python-otbr-api/issues/238).

---

## [2.1.3] - 2026-04-01

### 26-OT-RCP (OTBR on gateway)
- **IPv6 mDNS fix (`accept_ra=2`)**: `S70otbr` enabled IPv6 forwarding
  which silently disabled Router Advertisement processing. The gateway
  never acquired a GUA via SLAAC, so mDNS only announced the IPv4
  address. Fixed: set `accept_ra=2` on eth0 after enabling forwarding. (#77)
- **Channel Manager enabled**: `otbr-agent` now built with
  `OT_CHANNEL_MANAGER` and `OT_CHANNEL_MONITOR` (+14 KB). Enables
  `ot-ctl channel manager` for graceful channel changes across the
  Thread mesh. Channel change also works from the HA Thread UI.
- **HA REST API compatibility**: `build_otbr.sh` patches ot-br-posix
  REST API JSON keys from camelCase back to PascalCase at build time.
  Fixes "Failed to call OTBR API" in Home Assistant's Thread integration
  (`python-otbr-api` < 2.9.0 expects PascalCase).

---

## [2.1.1] - 2026-03-22

### flash_efr32.sh
- **Auto-reinstall USF on patch change**: `flash_efr32.sh` now stores the
  md5 hash of the applied `silabs-flasher-probe-methods.patch` in the venv.
  On next launch, if the patch has changed, the venv is removed and USF is
  reinstalled with the new patch automatically.

---

## [2.1.0] - 2026-03-21

### 24-NCP-UART-HW
- **Docker Compose stack**: new `docker/` directory with Mosquitto + Zigbee2MQTT
  (ember adapter) + Home Assistant. Self-contained for NCP users.

### flash_efr32.sh
- **OTBR support**: stops otbr-agent, cpcd, zigbeed before starting serialgateway
  in flash mode — no longer requires manual daemon management.
- **Remove 460800 baud**: gateway UART unreliable at 460800 (see 25-RCP-UART-HW).
  Removed from baud rate recovery scan and USF probe patch. Saves ~30s on flash.

### silabs-flasher-probe-methods.patch
- Drop all 460800 entries (EZSP, SPINEL, CPC). Add EZSP@230400, SPINEL@115200,
  SPINEL@230400.

### 22-Backup-Flash-Restore
- MEMO-universal-silabs-flasher.md: document 460800 removal rationale.

---

## [2.0.0] - 2026-03-11

### 26-OT-RCP
- **3 use cases, 1 firmware:** ZoH (Zigbee on Host), OTBR on host (Docker),
  OTBR on gateway (native) — all use the same OT-RCP firmware
- 3 Docker Compose stacks: `docker-compose-zoh.yml`, `docker-compose-otbr-host.yml`,
  `docker-compose-otbr-gateway.yml`
- Radio mode switching support in Docker compose files
- Thread network formation guide (use case 3: OTBR on gateway)
- Tested devices: IKEA TIMMERFLOTTE, BILRESA, MYGGSPRAY (all Matter/Thread)
- README restructured around the 3 use cases with architecture diagrams

### 22-Backup-Flash-Restore
- Technical memo: [MEMO-universal-silabs-flasher.md](22-Backup-Flash-Restore/MEMO-universal-silabs-flasher.md)
  — how USF works over TCP, baud rate mismatch problem, recovery mechanism

### flash_efr32.sh
- **Auto-recovery from non-standard baud rates:** when firmware runs at 230400
  or 460800 (e.g., after a custom build), the script scans baud rates, lets USF
  detect and enter the Gecko Bootloader, restarts serialgateway at 115200, and
  flashes. Tested with Spinel (OT-RCP) and EZSP (NCP).
- Patches USF probe methods at install time (`silabs-flasher-probe-methods.patch`)
  to add SPINEL@115200, SPINEL@230400, EZSP@230400
- SSH `-n` flag prevents stdin conflicts when piping firmware selection
- Default gateway IP: 192.168.1.88 (replaces placeholder throughout docs)

### Documentation
- IP placeholders replaced with default 192.168.1.88 across all Docker and Z2M configs

---

## [1.2.1] - 2026-03-05

### 26-OT-RCP
- Docker Compose stack for Thread/Matter: OTBR + Matter Server + Home Assistant
- Docker Compose stack for Zigbee: Zigbee2MQTT with zigbee-on-host (`zoh`) adapter
- Matter commissioning via HA Companion App (replaces chip-tool)
- Documented full setup: IPv6 forwarding, OTBR integration, Thread credentials sync
- Thread/Matter primer for Zigbee users (`THREAD-MATTER-PRIMER.md`)
- Tested: IKEA TIMMERFLOTTE (22.8 °C, 54.69 %, battery 100 %)
- Removed erroneous 460800 baud memo (actual root cause: PCB signal integrity)

### Build environment
- Unified build scripts: `build_rtl8196e.sh` (bootloader + kernel + rootfs + userdata), `build_efr32.sh` (all 5 firmware)
- Fixed Docker builds: GLIBC mismatch, lzma conflict, tool path detection
- All 9 build scripts work both in Docker and natively
- `nano` and `serialgateway` binaries now committed to skeleton for fresh clones

---

## [1.2.0] - 2026-03-02

### flash_efr32.sh (new — repository root)
- OTA flash script for EFR32 via SSH + universal-silabs-flasher
- Firmware selection menu: bootloader, NCP-UART-HW, RCP-UART-HW, OT-RCP, Z3-Router
- Bootloader flash automatically chains application firmware
- SSH retry (3 attempts, ConnectTimeout=10) for unreliable networks
- Progress bar visible for normal firmware flash
- Prerequisite checks: python3, python3-venv

### 23-Bootloader-UART-Xmodem
- Pre-built UART Xmodem firmware v2.4.2

### 26-OT-RCP
- Rebuilt firmware with PTI warning fix and Spinel bootloader reset support
- Removed orphan iostream config; clarified uartdrv vs iostream usage in README

### Documentation
- All firmware READMEs (23, 24, 25, 26, 27) updated: flash instructions now reference `flash_efr32.sh`
- Set `JAVA_TOOL_OPTIONS` in all build scripts so slc finds the trusted SDK

---

## [1.1.0] - 2026-01-25

### Build environment
- Updated Silabs toolchain: slc-cli 5.11, GSDK 4.5.0
- Silabs tools installed in project directory (like x-tools)

### 23-Bootloader-UART-Xmodem
- Aligned with Simplicity Studio standard project structure

### 25-RCP-UART-HW (new)
- Pre-built RCP firmware (CPC Protocol v5, GSDK 4.5.0)
- `rcp-stack` systemd service manager for cpcd + zigbeed chain
- zigbeed build scripts for EmberZNet 7.5.1 and 8.2.2
- Docker stack: cpcd-zigbeed + Zigbee2MQTT (amd64/arm64), based on Nerivec pre-built binaries
- cpcd/zigbeed build: fixed interactive prompts, dropped unused deps, added `--local`/`--deb` flags
- rcp-stack: fixed crash on empty env file, unbound variable on first run, symlink cleanup race

### 26-OT-RCP (new)
- OpenThread RCP firmware for zigbee-on-host (Z2M `zoh` adapter)
- Fixed flow control configuration for serialgateway compatibility

### 27-Router (new)
- Zigbee 3.0 Router SoC firmware with auto-join and network steering
- Mini-CLI: `bootloader reboot`, `network status/leave/steer`, `version`, `info`, `help`
- ZCL Basic Cluster: LidlRouter model, Silvercrest manufacturer, SW Build ID 1.0.0

---

## [1.0.0] - 2025-12-18

Initial release.

### 22-Backup-Flash-Restore
- Documentation for backing up and restoring the EFR32 via universal-silabs-flasher

### 23-Bootloader-UART-Xmodem
- Build script for Gecko UART Xmodem bootloader

### 24-NCP-UART-HW
- Pre-built NCP firmware v7.5.1 (EZSP v13, EmberZNet 7.5.1)
- Build script and patch system for customization
