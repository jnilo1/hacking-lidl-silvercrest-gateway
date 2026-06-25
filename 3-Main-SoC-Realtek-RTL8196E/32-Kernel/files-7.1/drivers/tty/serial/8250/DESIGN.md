# 8250_rtl819x — design notes

| | |
|---|---|
| **Last updated** | 2026-06-12 |
| **Driver version** | 1.4 |
| **Active release** | v3.10.0 (kernel `6.18.35-rtl8196e-v3.10.0`) |

Architecture companion to [`AUDIT.md`](AUDIT.md). This is the glue
driver for **UART1 = ttyS1 = the EFR32 radio link** — the wire under
the uart-bridge, Z2M/cpcd/otbr-agent, and `flash_efr32.sh`. UART0
(console, ttyS0) deliberately stays on the stock `ns16550a` path; this
driver never touches it.

## 1. Why a glue driver at all

A plain `ns16550a` node almost works — and "almost" cost weeks of
debugging across three issues. The SoC needs four things the generic
driver cannot provide:

1. **Pin mux.** Bits 1/3/6 of `PIN_MUX_SEL` (syscon offset 0x40) must be
   set or UART1 runs perfectly *inside* the SoC (THRE fires) while no
   electrical signal reaches the EFR32. Our bootloader, unlike Tuya's,
   does not set them, and the ethernet drivers historically clobbered
   the neighbouring field. Probe sets them via syscon/regmap and treats
   lookup failure as fatal (AUDIT 8250RTL-001).
2. **The SoC flow-control gate.** RTS/CTS needs bit 29 of the 32-bit
   word at +0x10 — which is nothing exotic: it is `UART_MCR_AFE` seen
   through the BE bus's byte-lane routing (the core's MCR byte writes
   land in bits 31:24). CRTSCTS in termios alone is not sufficient; the
   driver syncs the flag into the hardware on every set_termios call.
3. **The N+1 divisor quirk.** DLL/DLM are interpreted as (N+1), not N —
   the stock bootloader's `clock/16/baud - 1` is the tell. Harmless
   inside 16550 tolerance at ≤230400, catastrophic (~3% error, ~40%
   framing errors) at 460800. `set_divisor` programs `quot - 1`.
4. **ttyS1 as a platform contract.** The DT keeps a single
   `realtek,rtl8196e-uart` compatible (no `ns16550a` fallback — the
   6.18 of_platform matcher would hand the node to `8250_of.c` and skip
   the pin mux, the exact rx=0 failure the dtsi comment documents), and
   probe fails outright if the core assigns any line but 1
   (AUDIT 8250RTL-002).

Everything else is the stock 8250 core: this driver registers a port
with `serial8250_register_8250_port()` and overrides exactly three
hooks.

## 2. The three hooks — one field incident each

| Hook | Incident | What it does |
|---|---|---|
| `set_termios` | #89 — RX overruns at 460800 | After `serial8250_do_set_termios()`, syncs the bit-29 gate to the *absolute* CRTSCTS state (v1.3 — transitions-only left `flow_active` stale, AUDIT 8250RTL-008), with the RMW under `port->lock` (the core's competing MCR byte writes hold the same lock) |
| `set_divisor` | framing errors at 460800 | N+1 compensation (`quot - 1`) |
| `set_mctrl` | #109 — OTBR wedge after days of uptime | While `supports_afe && flow_active`, re-ORs `TIOCM_RTS`: `uart_throttle()` clears RTS in software when CRTSCTS is set but `UPSTAT_AUTORTS` is not advertised (the 8250 core never advertises it), and under AFE a cleared MCR-RTS pins physical RTS deasserted forever — the EFR32 is told "do not send" and Spinel dies. Real backpressure remains AFE's job, gated on FIFO level |

The flow-control enable path deliberately forces the **full** MCR
pattern (DTR|RTS|OUT2|AFE = 0x2B000000) rather than just setting AFE:
the v3.5.1 incident showed the core's byte writes rebuilding the MCR
from its mctrl shadow, leaving 0x20000000 (AFE alone, RTS low) — same
wedge, different door. Three layers, one invariant: **while AFE owns
the line, the MCR never says RTS-low.**

## 3. Probe sequence (order matters)

1. devm alloc + plain `devm_ioremap` of 0x18002100+0x100 — deliberately
   **without** claiming the mem region: the 8250 core claims it itself in
   `config_port`, and claiming it first silently reverts the port to
   FIFO-off char mode (AUDIT 8250RTL-007, fixed in v1.3).
2. Pin mux via syscon — fatal on failure, before anything can appear to
   work.
3. Optional clk; IRQ from DT; uartclk from `clock-frequency` (the dtsi
   provides 200 MHz = the LX bus clock all baud math uses).
4. Hooks installed; AFE pre-enabled (port=NULL — pre-registration, no
   concurrency) when DT says `auto-flow-control`/`uart-has-rtscts`.
5. `serial8250_register_8250_port()`, assert line 1, pin the RX FIFO
   trigger to 1 (invariant 7), then re-assert the MCR pattern to cover
   core writes during registration.

`remove` unregisters and drops the clock; the pin mux is left set
(harmless, and the console UART never depends on it).

## 4. Consumers

```
8250_rtl819x (ttyS1)
  └── rtl8196e-uart-bridge (tty_port client_ops, TCP:8888)
        ├── Z2M / ZHA (EZSP)            ├── cpcd → zigbeed (CPC)
        ├── otbr-agent (Spinel)         └── flash_efr32.sh (Xmodem)
```

The bridge owns the tty in production and drives CRTSCTS through its
`flow_control` parameter; `flash_efr32.sh` drops flow control around
Xmodem transfers. Baud changes arrive via the bridge's `baud` knob →
termios → `set_divisor`. The supported ladder (115200 / 460800 /
691200 / 892857) tops out at the N+1 divisor minimum (200 MHz ÷ 16 ÷ 14).

## 5. Invariants

1. **The DT node keeps a single compatible.** Adding an `ns16550a`
   fallback re-creates the silent rx=0 failure on 6.18.
2. **The pin-mux write stays fatal-on-failure and stays in this
   driver** until pinctrl provably owns it — a ttyS1 that exists but
   isn't wired is the worst failure mode this platform has produced.
3. **While AFE owns the line, no path may leave MCR-RTS low.** Any new
   code touching MCR goes through the existing helpers under
   `port->lock`, and the `set_mctrl` guard stays until
   `UPSTAT_AUTORTS` is adopted deliberately (see AUDIT §3 rejection).
4. **`set_divisor` keeps the N+1 compensation and the `quot > 1`
   floor.** Verified on the wire at 460800; the floor is the guard
   against a zero divisor.
5. **ttyS1 or fail.** The line number is API for the bridge,
   `S50uart_bridge`, `S70otbr` and `radio.conf`.
6. **Probe never claims the UART mem region.** The 8250 core requests it
   in `config_port`; a prior devm claim makes that fail silently and the
   port runs FIFO-off with `rx_trig_bytes` missing (AUDIT 8250RTL-007 —
   the v1.2 regression this driver lived with from F-08 to v1.3).
7. **The RX FIFO trigger stays pinned at 1.** Silicon erratum: trigger
   levels above 1 overrun erratically and non-monotonically under
   sustained line-rate load (AUDIT 8250RTL-009, full bench table there).
   Trigger 1 + enabled FIFO = the full 16-byte latency cushion and the
   exact wire behaviour every v3.x release was validated on. Raising it
   via `rx_trig_bytes` is for experiments only.
