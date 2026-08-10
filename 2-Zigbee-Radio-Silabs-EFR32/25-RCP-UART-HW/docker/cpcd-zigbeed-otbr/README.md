# Use case 2 — Multipan (Zigbee + Thread concurrent) — **not supported on Series 1 radios**

This directory used to hold a `Dockerfile.multiarch` that built an image
bundling `cpcd`, `zigbeed` and `otbr-agent` into one container, with
`cpcd` dispatching CPC traffic to `zigbeed` on IID=1 and to `otbr-agent`
on IID=2 — the classic "multi-PAN host" pattern.

The Dockerfile and its companion compose file were removed from the repo
because **concurrent Zigbee + Thread is not achievable on a Series 1
EFR32**, and every board this firmware supports carries one. Keeping
unreachable infrastructure in the tree was only going to mislead future
readers.

## Why it cannot work here

The Zigbee radio is an **EFR32MG1B** on the Lidl board and an **EFR32MG13P**
on the Sengled G4 — both Silicon Labs **Series 1**.
Concurrent Zigbee + Thread over a single RCP requires Silicon Labs'
**Concurrent Multiprotocol (CMP)**, which is a **Series 2-only** feature
(EFR32MG21 / MG24). On Series 1, RAIL only supports **Dynamic Multiprotocol
(DMP)** — BLE + one of Zigbee/Thread, never Zigbee + Thread together.

Symptomatic evidence: `otbr-agent` attaching on IID=2 against an MG1B RCP
dies at commissioning time with

```
[C] Platform------: GetIidListFromUrl() at spinel_manager.cpp:175: InvalidArgument
```

because the RCP advertises only IID=0 (or IID=1 in single-PAN mode) — it
has no way to report a valid IID list that contains 2.

GSDK 4.5.0 (the last SDK that targets MG1B) also has **no multi-PAN RCP
sample for Thread** — its `zigbee_multi_pan` component (AN724) covers a
different scenario (two simultaneous Zigbee networks on the same channel).

## What to do instead

On these gateways, run **one protocol at a time** by reflashing the EFR32
with the appropriate single-protocol firmware:

| I want… | Flash | Host docker |
|---|---|---|
| Zigbee (EmberZNet 8.2.2, EZSP v18) | `./flash_efr32.sh rcp` | [`../docker-compose-zigbee.yml`](../docker-compose-zigbee.yml) |
| Thread / Matter-over-Thread | `./flash_efr32.sh otrcp` | `../../../26-OT-RCP/docker/docker-compose-otbr-host.yml` |

Swapping is ~30 s via `flash_efr32.sh` from the repo root.
