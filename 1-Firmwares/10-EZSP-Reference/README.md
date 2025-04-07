# EmberZNet and EZSP Reference

This page clarifies the differences between various firmware modes (NCP,
RCP), the role of EmberZNet, and the meaning of EZSP versions — common
sources of confusion when flashing or configuring Zigbee firmware.

______________________________________________________________________

## 🧠 What is EmberZNet?

**EmberZNet** is Silicon Labs’ official Zigbee stack. It provides:

- [IEEE 802.15.4](https://en.wikipedia.org/wiki/IEEE_802.15.4)
  [MAC](https://en.wikipedia.org/wiki/IEEE_802.15.4#The_MAC_layer) and
  [PHY](https://en.wikipedia.org/wiki/IEEE_802.15.4#The_physical_layer)
- Zigbee Network layer (routing, addressing)
- Zigbee Application layer (clusters, ZCL)
- Security and commissioning logic

It can run in multiple modes:

### ✅ SoC Mode

- Full Zigbee stack **and** application run on the EFR32 chip.
- No external host required.

### ✅ NCP Mode (Network Co-Processor)

- The Zigbee stack runs on the EFR32.
- An external Linux host communicates via **EZSP** protocol over UART.

### ✅ RCP Mode (Radio Co-Processor)

- Only PHY and MAC run on the EFR32.
- The Zigbee or Thread stack runs on the Linux host.
- Requires CPC daemon (`cpcd`) on host.

______________________________________________________________________

## 🔌 What is EZSP?

EZSP = **Ember Zigbee Serial Protocol**

It is a **binary protocol** developed by Silicon Labs to control a Zigbee
NCP over a serial link.

The Linux host communicates with the NCP using EZSP commands for:

- Forming/joining a Zigbee network
- Sending/receiving messages
- Managing clusters, endpoints
- Security, stack control

______________________________________________________________________

## 🧾 EZSP Versions

| EmberZNet Version | EZSP Version | Notes                                          |
| ----------------- | ------------ | ---------------------------------------------- |
| 6.5.x.x           | V7           | Found in original Lidl firmware                |
| 6.7.x.x           | V8           | Used in Paul Banks’ project                    |
| 7.4.x.x           | V13          | Compatible with `ember` adapter in Z2M and ZHA |

______________________________________________________________________

## 🧩 Compatibility with Zigbee2MQTT and ZHA

### Zigbee2MQTT

| EZSP Version | Z2M Adapter           |
| ------------ | --------------------- |
| V7/V8        | `ezsp` (deprecated)   |
| V13+         | `ember` (recommended) |

```yaml
# Zigbee2MQTT example
serial:
  port: tcp://192.168.1.x:8888
  adapter: ember
```

### Home Assistant (ZHA)

ZHA supports all EZSP versions but recommends EZSP V13+ for recent stacks.

______________________________________________________________________

## 📦 Available Firmware Versions

- 🔸 **EZSP V8**: Used to update
  [Paul Banks](https://paulbanks.org/projects/lidl-zigbee/) hack with a
  firmware provided by Gary Robas:
  [Download .gbl](https://github.com/grobasoz/zigbee-firmware/raw/master/EFR32%20Series%201/EFR32MG1B-256k/NCP/NCP_UHW_MG1B232_678_PA0-PA1-PB11_PA5-PA4.gbl)

- 🔸 **EZSP V13**: Built from Simplicity Studio Gecko SDK 4.4.x, they
  provide the most recent EMberZNet 7.4.x versions available at the time of
  this writing. See [NCP-UART-HW section](../14-NCP-UART-HW/firmware)

______________________________________________________________________

## 🛑 Important Notes

- EZSP is **not compatible** with RCP firmwares (use CPC instead).
- Z2M is phasing out support for `ezsp` adapter; prefer `ember`.
- The firmware must match the **hardware pinout** (PA0/PA1/etc.).

______________________________________________________________________

## 📚 References

- [Silicon Labs EZSP Protocol Guide](https://www.silabs.com/documents/public/user-guides/ug100-ezsp-reference-guide.pdf)
- [EmberZNet SDK documentation](https://docs.silabs.com/zigbee/latest/)
- [Zigbee2MQTT EZSP support](https://www.zigbee2mqtt.io/guide/adapters/emberznet.html)
