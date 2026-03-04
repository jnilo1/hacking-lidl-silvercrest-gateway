# Thread & Matter — A Primer for Zigbee Users

If you're familiar with Zigbee and wondering what Thread and Matter are about,
this guide explains the key concepts, compares them to Zigbee, and clarifies
how they work together in this project.

## The Big Picture

**Zigbee** is both a radio protocol AND an application layer. It handles
everything: how devices talk over the air, how they form networks, and what
"turn on a light" means.

**Thread** and **Matter** split these responsibilities:

| Layer | Zigbee | Thread/Matter |
|-------|--------|---------------|
| **Application** (what devices do) | Zigbee Cluster Library (ZCL) | **Matter** |
| **Network** (how devices communicate) | Zigbee network layer | **Thread** |
| **Radio** (physical layer) | IEEE 802.15.4 | IEEE 802.15.4 |

Thread and Matter are independent specifications that work together:
- **Thread** replaces the Zigbee network layer with an IPv6-based mesh
- **Matter** replaces the Zigbee application layer with a unified device model

They share the same radio (802.15.4) as Zigbee — which is why the same EFR32
hardware can run either protocol.

---

## Thread — The Network Layer

### What Thread Does

Thread is a low-power, IPv6 mesh networking protocol. Like Zigbee, it uses
IEEE 802.15.4 radio. Unlike Zigbee, every device gets a real IPv6 address.

### Thread vs Zigbee Network

| Aspect | Zigbee | Thread |
|--------|--------|--------|
| **Addressing** | 16-bit short addresses | IPv6 addresses |
| **Routing** | Tree + table routing | Mesh Link Establishment (MLE) |
| **Internet access** | Requires bridge (Z2M, ZHA) | Native via Border Router |
| **Coordinator** | Single coordinator (SPOF) | No single point of failure |
| **Self-healing** | Limited | Full mesh re-routing |
| **Max devices** | ~200 (practical) | ~250 per network |
| **Multicast** | Group IDs | IPv6 multicast |

### Key Thread Concepts

**Thread Border Router (OTBR)**
The equivalent of a Zigbee coordinator, but more capable. It bridges the
Thread mesh (802.15.4) to your IP network (Ethernet/Wi-Fi). Unlike a Zigbee
coordinator, you can have **multiple** border routers for redundancy — if one
goes down, the others keep the network running.

**Thread Router**
A mains-powered Thread device that routes packets for others. In Zigbee terms,
this is similar to a Zigbee Router (e.g., a smart plug that repeats). Thread
routers are elected dynamically — the network decides which devices should
route based on topology.

**Thread End Device / Sleepy End Device (SED)**
A battery-powered device that mostly sleeps and wakes up periodically to check
for messages. Equivalent to a Zigbee End Device. The IKEA TIMMERFLOTTE is a
Sleepy End Device — it wakes up, reports temperature/humidity, then goes back
to sleep.

**Thread Leader**
One router in the Thread network is elected as Leader. It manages router ID
assignment and network data distribution. If the leader fails, another router
takes over automatically. There is no equivalent in Zigbee (the coordinator
is fixed and cannot be replaced).

**Dataset**
The Thread equivalent of a Zigbee network key + PAN ID. It contains the
network name, channel, security key, and other parameters needed to join the
network. During Matter commissioning, this dataset is transferred to the
device over BLE.

### What Role Does the Lidl Gateway Play?

In this project, the Lidl gateway is a **Radio Co-Processor (RCP)** — it is
**not** a Thread router or border router. The EFR32 chip only handles the
802.15.4 radio layer (transmit/receive frames). All Thread networking logic
runs on the Docker host in the OTBR container.

```
┌─────────────────────────────────────────────────────┐
│                   Docker Host (your PC)              │
│                                                      │
│  ┌──────────────────────────────────────────┐        │
│  │  OTBR Container                          │        │
│  │  ┌─────────────────────────────────┐     │        │
│  │  │  Thread Stack (routing, leader  │     │        │
│  │  │  election, border routing,      │     │        │
│  │  │  IPv6 forwarding)              │     │        │
│  │  └──────────┬──────────────────────┘     │        │
│  │             │ Spinel/HDLC over TCP       │        │
│  └─────────────┼────────────────────────────┘        │
│                │ :8888                                │
└────────────────┼─────────────────────────────────────┘
                 │
     ┌───────────┼───────────┐
     │  Lidl Gateway (RCP)   │
     │  ┌────────┴────────┐  │
     │  │  serialgateway   │  │
     │  │  (TCP ↔ UART)    │  │
     │  └────────┬────────┘  │
     │  ┌────────┴────────┐  │
     │  │  EFR32 Radio     │  │  ← Only this: send/receive 802.15.4 frames
     │  │  (802.15.4)      │  │
     │  └─────────────────┘  │
     └───────────────────────┘
```

This is the same architecture as Zigbee with zigbee-on-host (`zoh`):
the EFR32 provides the radio, and the "brain" runs on the host. The
difference is which stack runs on the host: zigbee-on-host (for Zigbee)
or OpenThread (for Thread).

---

## Matter — The Application Layer

### What Matter Does

Matter defines **what devices are and what they can do**. It replaces the
Zigbee Cluster Library (ZCL) with a unified device model that works across
Thread, Wi-Fi, and Ethernet.

### Matter vs Zigbee Application Layer

| Aspect | Zigbee (ZCL) | Matter |
|--------|-------------|--------|
| **Transport** | Zigbee only | Thread, Wi-Fi, Ethernet |
| **Device types** | ZCL clusters | Matter device types |
| **Commissioning** | Permit join + install code | BLE + QR code |
| **Multi-admin** | Not supported | Up to 5 fabrics (controllers) |
| **Interoperability** | Vendor-specific profiles | Mandatory certification |
| **Updates** | Vendor-dependent | OTA built into spec |

### Key Matter Concepts

**Fabric**
A Matter fabric is like a "home" or "controller domain". When you commission
a device, it joins your fabric. A device can belong to up to 5 fabrics
simultaneously — for example, your Home Assistant fabric AND your Google
Home fabric can both control the same light. This is called **multi-admin**
and has no equivalent in Zigbee.

**Commissioning**
The process of adding a device to your Matter fabric. Unlike Zigbee (where
you just "permit join" and hope), Matter uses a secure, deliberate process:

1. You scan the device's QR code (or enter its 11-digit setup code)
2. Your phone connects to the device via **BLE** (Bluetooth Low Energy)
3. The phone verifies the device's identity (attestation)
4. The phone sends the Thread network credentials over BLE
5. The device joins the Thread network and is added to your fabric

This is fundamentally different from Zigbee pairing, which happens entirely
over 802.15.4.

**Matter Server (python-matter-server)**
The Matter "controller" that manages your fabric — it holds the encryption
keys, the list of commissioned devices, and handles communication with them.
In this project, it runs as a Docker container. Think of it as the equivalent
of Zigbee2MQTT but for Matter devices.

**Matter Controller (Home Assistant / Companion App)**
The user interface that talks to the Matter Server. Home Assistant is the
dashboard, and the Companion App on your phone is used for BLE commissioning
(because your PC may not have Bluetooth, but your phone does).

### Matter Commissioning Flow (vs Zigbee)

**Zigbee pairing:**
```
Z2M: "Permit join" → Device: joins over 802.15.4 → Done
(all over the same radio, simple but less secure)
```

**Matter commissioning:**
```
Phone: scan QR code → BLE to device → verify identity →
send Thread credentials → device joins Thread → Matter Server
registers device → appears in Home Assistant
(two radios involved: BLE for setup, 802.15.4 for operation)
```

---

## The Complete Stack — Who Does What

Here's the full picture of every component and its role:

| Component | Role | Zigbee Equivalent |
|-----------|------|-------------------|
| **EFR32 (RCP)** | 802.15.4 radio transceiver | Same (RCP radio) |
| **serialgateway** | UART-to-TCP bridge | Same |
| **OTBR** | Thread border router + mesh routing | Zigbee coordinator |
| **Matter Server** | Fabric controller, device registry | Zigbee2MQTT |
| **Home Assistant** | Dashboard, automations | Home Assistant |
| **Companion App** | BLE commissioning from phone | Z2M "Permit join" button |
| **Phone BLE** | Initial device pairing | Not needed in Zigbee |

### Data Flow — Normal Operation

Once commissioned, a Matter/Thread device communicates like this:

```
IKEA TIMMERFLOTTE
  │  802.15.4 (Thread mesh)
  ▼
EFR32 (RCP radio)
  │  UART (Spinel/HDLC)
  ▼
serialgateway
  │  TCP :8888
  ▼
OTBR (Thread → IPv6)
  │  IPv6 (local network)
  ▼
Matter Server
  │  WebSocket
  ▼
Home Assistant → your dashboard
```

Compare with Zigbee (zoh mode):

```
Xiaomi LYWSD03MMC
  │  802.15.4 (Zigbee)
  ▼
EFR32 (RCP radio)
  │  UART (Spinel/HDLC)
  ▼
serialgateway
  │  TCP :8888
  ▼
Zigbee2MQTT (zigbee-on-host)
  │  MQTT
  ▼
Home Assistant → your dashboard
```

The radio path is identical — only the upper layers differ.

---

## Advantages and Drawbacks

### Thread vs Zigbee

| | Thread | Zigbee |
|---|---|---|
| **IPv6 native** | Devices have real IP addresses | Requires bridge for IP access |
| **No single point of failure** | Multiple border routers supported | Coordinator is a SPOF |
| **Self-healing mesh** | Full re-routing if a node fails | Limited re-routing |
| **Interoperability** | Standard IPv6, any controller | Vendor-specific bridges |
| **Maturity** | Newer, smaller ecosystem | 20 years, huge device catalog |
| **Complexity** | More moving parts (OTBR, IPv6) | Simpler to set up |
| **Device availability** | Growing but limited | Thousands of devices |

### Matter vs Zigbee (Application Layer)

| | Matter | Zigbee |
|---|---|---|
| **Multi-admin** | Up to 5 controllers simultaneously | One controller only |
| **Commissioning** | Secure (BLE + QR code) | Open join (less secure) |
| **Transport agnostic** | Thread, Wi-Fi, Ethernet | Zigbee only |
| **Certification** | Mandatory → guaranteed interop | Optional → fragmented |
| **Local control** | Always local, no cloud required | Depends on implementation |
| **Ecosystem** | Apple, Google, Amazon, Samsung... | Zigbee Alliance members |
| **Device variety** | Still limited (lights, sensors, locks) | Very broad |
| **Maturity** | v1.0 released Oct 2022 | v3.0 mature and stable |

### Bottom Line

- **Thread** is technically superior to Zigbee's network layer (IPv6, no SPOF,
  better mesh), but adds complexity (OTBR, IPv6 forwarding, border routing).
- **Matter** promises universal interoperability (one device works with all
  controllers), but the ecosystem is still young and device choice is limited.
- **Zigbee** remains the pragmatic choice today for most smart home setups:
  mature, simple, thousands of affordable devices.
- You can run **both** on the same hardware — just switch Docker stacks.

---

## Glossary

| Term | Definition |
|------|-----------|
| **802.15.4** | The radio standard shared by Zigbee and Thread (2.4 GHz, low power) |
| **BLE** | Bluetooth Low Energy — used only for Matter commissioning, not for ongoing communication |
| **Border Router** | Bridges Thread mesh (802.15.4) to IP network (Ethernet/Wi-Fi) |
| **Commissioning** | Adding a device to a Matter fabric (via BLE + QR code) |
| **Dataset** | Thread network credentials (key, channel, PAN ID) — like a Zigbee network key |
| **Fabric** | A Matter controller domain — a device can belong to multiple fabrics |
| **Leader** | The Thread router that manages network data — elected automatically |
| **Matter** | Application-layer protocol defining device types and interactions |
| **MLE** | Mesh Link Establishment — Thread's routing protocol |
| **Multi-admin** | Matter feature allowing a device to be controlled by multiple ecosystems |
| **OTBR** | OpenThread Border Router — open-source Thread border router |
| **RCP** | Radio Co-Processor — the EFR32 provides only the radio, stack runs on host |
| **SED** | Sleepy End Device — battery-powered, wakes periodically (like Zigbee End Device) |
| **Spinel** | Protocol between RCP radio and host Thread stack (over HDLC/UART) |
| **Thread** | IPv6 mesh network protocol for IoT devices |

---

## References

- [Thread Group](https://www.threadgroup.org/) — Thread specification
- [OpenThread](https://openthread.io/) — Open-source Thread implementation (by Google)
- [Connectivity Standards Alliance](https://csa-iot.org/) — Matter specification (formerly Zigbee Alliance)
- [Home Assistant Matter integration](https://www.home-assistant.io/integrations/matter/)
- [Thread vs Zigbee (Nordic Semiconductor)](https://www.nordicsemi.com/Products/Thread)
