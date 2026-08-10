# RTL8196E kernel diagnostic tools

These tools run on the gateway but are not installed in the default firmware.
Copy only the tool needed for a specific diagnostic session.

## UART overrun monitor

`uart-overrun-monitor` samples the kernel's cumulative UART counters and writes
their per-interval differences to CSV. It defaults to UART1 (`ttyS1`), the link
between the RTL8196E and EFR32 radio, and applies to every radio mode.

From the repository root:

```bash
scp -O 3-Main-SoC-Realtek-RTL8196E/32-Kernel/tools/uart-overrun-monitor \
  root@<gateway-ip>:/tmp/
ssh root@<gateway-ip> 'chmod +x /tmp/uart-overrun-monitor'
ssh root@<gateway-ip> \
  '/tmp/uart-overrun-monitor -i 2 -d 120 -o /tmp/uart-errors.csv'
scp -O root@<gateway-ip>:/tmp/uart-errors.csv .
```

Generate normal radio traffic during the capture: commission devices, send
group commands, or reproduce the failure under investigation.

Interpret the delta columns rather than the absolute totals:

| Column | Meaning | Interpretation when positive |
| --- | --- | --- |
| `d_oe` | UART RX overrun errors | Hardware dropped incoming bytes |
| `d_fe` | Framing errors | Baud, signal, or clocking problem |
| `d_pe` | Parity errors | Serial configuration or signal problem |
| `d_brk` | Break detections | Reset, bootloader transition, or line disturbance |

A non-zero historical total is not proof of a current problem. A positive delta
during the reproduced workload is. Confirm `/userdata/etc/radio.conf`, the
running firmware baud, and the board's flow-control wiring before changing the
speed. The Sengled G4 has no RTS/CTS and normally uses lower board defaults.
