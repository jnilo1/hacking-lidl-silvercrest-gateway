# Thread range testing

This toolkit measures how a Thread mesh behaves in your home: link quality,
transmit power margin, channel choice, and the effect of device orientation.
The gateway-side essentials are deliberately kept in **one command**.

For the results from a real 16-sensor deployment and guidance on interpreting
them, read the [field report](REPORT.md).

## What is included

```text
range-testing/
├── README.md
├── REPORT.md
├── gateway/
│   ├── thread-range-test
│   └── optional/
│       ├── thread-health-monitor
│       └── home-assistant/
│           ├── thread-link-publisher
│           ├── thread-link-publisher.conf.example
│           └── S75thread-link-publisher
└── analysis/
    ├── analyze-results.py
    └── map-ha-devices.py
```

Start with `thread-range-test`. The health monitor and Home Assistant publisher
are optional integrations; they are not required for ordinary measurements.

## Quick start

Run these commands from this `range-testing` directory on your computer.
Replace `192.168.1.88` with the gateway address.

```bash
scp -O gateway/thread-range-test root@192.168.1.88:/usr/bin/
ssh root@192.168.1.88 'chmod +x /usr/bin/thread-range-test'
```

Take a two-minute sample, retrieve it, then print summary statistics:

```bash
ssh root@192.168.1.88 \
  'OT_CTL=/userdata/usr/bin/ot-ctl thread-range-test sample smoke 120 30'
scp -O root@192.168.1.88:/userdata/log/range_smoke.csv .
python3 analysis/analyze-results.py range_smoke.csv
```

The `OT_CTL` override is only needed when `ot-ctl` is not already on the
gateway's `PATH`.

## The four experiments

| Question | Command | What changes |
|---|---|---|
| Is data collection working? | `sample` | Nothing; records the current mesh |
| How much transmit-power margin is available? | `tx-power` | Gateway TX power |
| Would another 802.15.4 channel work better? | `channel` | Thread network channel |
| Does physical placement matter? | `orientation` | Gateway or sensor orientation |

Every command has built-in help:

```bash
thread-range-test --help
thread-range-test tx-power --help
```

### Record one condition

```bash
thread-range-test sample <label> <duration_seconds> [interval_seconds]
thread-range-test sample baseline 600 30
```

The result is `/userdata/log/range_<label>.csv`. Each row contains a timestamp,
RLOC, role, age, average and last RSSI, inbound link quality, and extended MAC.

### Sweep transmit power

```bash
thread-range-test tx-power expected_children=16 sample_sec=300
```

The default sweep requests 10, 7, 5, 3, 1, and 0 dBm. The radio may clamp a
requested value; the actual value is recorded in each CSV. The command stops
if the attached-child count drops and restores 7 dBm on completion or signal.
Omit `expected_children` to use the count observed at startup.

### Compare channels

```bash
thread-range-test channel to=20 sample_sec=300
```

The command records the current channel, migrates the whole Thread network
through a Pending Operational Dataset, records the target, then migrates back
and takes a control sample. Battery devices may take several minutes to follow
a migration. Do not power-cycle the gateway or interrupt the command while a
migration is pending.

### Compare orientations

Start the runner:

```bash
thread-range-test orientation gateway 'front left right' sample_sec=300
```

For each requested position, physically move the subject and acknowledge it
from a second SSH session:

```bash
touch /tmp/thread-range-orientation.ack
```

Use a stable label without spaces for `subject`, such as `gateway` or
`bedroom_sensor`.

## Analyse several results

`analyze-results.py` uses only the Python standard library:

```bash
python3 analysis/analyze-results.py range_*.csv
```

To show Home Assistant labels instead of extended MAC addresses, first create
a mapping. This optional helper needs the `websockets` package and a Home
Assistant long-lived access token:

```bash
python3 -m venv .venv
.venv/bin/pip install websockets
HA_URL=homeassistant.local:8123 \
HA_TOKEN='<long-lived-token>' \
  .venv/bin/python analysis/map-ha-devices.py > labels.csv
python3 analysis/analyze-results.py --map labels.csv range_*.csv
```

Treat the token as a password. Do not add it to this repository or copy it to
the gateway unless you intentionally enable the publisher below.

## Optional: monitor gateway health

The health monitor adds one host-side sample per minute: memory, load, UART1
errors, Thread state and child count, and Ethernet errors.

```bash
scp -O gateway/optional/thread-health-monitor root@192.168.1.88:/usr/bin/
ssh root@192.168.1.88 'chmod +x /usr/bin/thread-health-monitor'
ssh root@192.168.1.88 \
  'OT_CTL=/userdata/usr/bin/ot-ctl thread-health-monitor start'
ssh root@192.168.1.88 'thread-health-monitor status'
ssh root@192.168.1.88 'thread-health-monitor stop'
```

It writes `/userdata/log/health.csv` and a final
`/userdata/log/dmesg.snapshot`. Stop it after the experiment.

## Optional: publish link quality to Home Assistant

The publisher sends each attached child's average RSSI and link attributes to
the Home Assistant REST API. It is opt-in because it stores a Home Assistant
token on the gateway and creates one REST request per child per interval.

1. Copy and edit the configuration locally:

   ```bash
   cp gateway/optional/home-assistant/thread-link-publisher.conf.example \
     thread-link-publisher.conf
   # Set HA_URL, HA_TOKEN, and LABEL_<ext_mac> entries.
   ```

2. Install the configuration and command:

   ```bash
   scp -O thread-link-publisher.conf \
     root@192.168.1.88:/userdata/etc/thread-link-publisher.conf
   scp -O gateway/optional/home-assistant/thread-link-publisher \
     root@192.168.1.88:/usr/bin/
   ssh root@192.168.1.88 'chmod +x /usr/bin/thread-link-publisher && \
     OT_CTL=/userdata/usr/bin/ot-ctl thread-link-publisher once'
   ```

3. If the one-shot test succeeds, start and inspect the daemon:

   ```bash
   ssh root@192.168.1.88 'thread-link-publisher start'
   ssh root@192.168.1.88 'thread-link-publisher status'
   ```

To start it automatically, install the provided init script:

```bash
scp -O gateway/optional/home-assistant/S75thread-link-publisher \
  root@192.168.1.88:/userdata/etc/init.d/
ssh root@192.168.1.88 \
  'chmod +x /userdata/etc/init.d/S75thread-link-publisher'
```

The publisher is a measurement aid, not part of the default firmware. Its
configuration contains a bearer token and should remain readable only by root.

## Measurement cautions

- RSSI and LQI from `ot-ctl neighbor table` are measured at the gateway. They
  describe the child's uplink, not necessarily its downlink.
- Change one variable at a time and keep the gateway, sensors, furniture, and
  traffic conditions stable during a comparison.
- Allow battery devices time to wake and follow topology or channel changes.
- Prefer repeated samples over a conclusion based on one RSSI value.
- Record the attached-child count; good averages are meaningless if a weak
  device disappeared from the table.
