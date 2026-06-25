# `rtl819x_wdt` — RTL8196E hardware watchdog driver

User-facing documentation. For internal design history, security and
performance findings, see `AUDIT.md` in this same directory; for the
exact code, see `rtl819x_wdt.c`.

---

## What this driver does

The RTL8196E SoC has a single hardware watchdog timer (WDT). If the
kernel or userspace stops kicking it before its overflow window expires,
the chip resets the whole SoC.

This driver gives the watchdog a name (`/dev/watchdog`), a soft timeout
contract with the standard Linux watchdog framework, and three automatic
recovery hooks that fire even when the BusyBox `watchdog` userspace
feeder cannot help:

| Event                                  | Reaction                                                                          |
|----------------------------------------|-----------------------------------------------------------------------------------|
| Userspace `/dev/watchdog` feeder dies  | Framework keeps the chip kicked at half-timeout until a new feeder shows up       |
| `reboot` / `shutdown -r now`           | Driver's `.restart` op arms the chip at the smallest bucket → reset in ~1.3 s     |
| Kernel `panic()` (incl. soft-lockup)   | Panic notifier arms the chip at the smallest bucket → reset in ~1.3 s             |
| Userspace stuck in a busy syscall      | Soft-lockup detector at 22 s → panic → same notifier path → ~23 s end-to-end      |

The watchdog is what makes the gateway recover **autonomously** from a
hang. Without it, a wedged firmware needs someone to physically pull the
power cable.

---

## What you'd actually do with it

In normal operation: nothing. The driver loads at boot, the BusyBox
`watchdog` feeder (`/etc/init.d/S25watchdog`) kicks `/dev/watchdog` every
30 s, and the chip never overflows.

You'd touch the driver only to:

- **Confirm it loaded** — see "Verifying" below.
- **Disable it temporarily** — for kernel-bringup work, where you do not
  want a hang to reboot the box. See "Disabling".
- **Change the soft timeout** — via device tree (`timeout-sec`) or
  `WDIOC_SETTIMEOUT` ioctl. See "Configuration".

---

## Verifying

### 1. Probe banner in `dmesg`

After a successful boot you should see, in order:

```
rtl819x-wdt 1800311c.watchdog: last reset: power-on / pin reset (WDTCNR=0x...)
rtl819x-wdt 1800311c.watchdog: bringup register dump (sysc+0x3100..0x3120):
rtl819x-wdt 1800311c.watchdog:   +0x3100: 0x........
... 9 lines ...
rtl819x-wdt 1800311c.watchdog: v1.6 (J. Nilo) - timeout:60s, nowayout:0
```

If `last reset:` reads `watchdog timeout` you are looking at a fresh
boot that followed a watchdog-initiated reset (recovery worked).
Caveat: on RTL8196E rev `0xb08` the indicator bit may read 0 even after
a watchdog-fired reset — see `WDT-001` in `AUDIT.md`.

### 2. Userspace device node

```
# ls -la /dev/watchdog
crw-------    1 root     root       10, 130 ... /dev/watchdog
```

### 3. sysfs surface

```
# cat /sys/class/watchdog/watchdog0/identity
rtl819x-wdt
# cat /sys/class/watchdog/watchdog0/timeout
60
# cat /sys/class/watchdog/watchdog0/nowayout
0
# cat /sys/class/watchdog/watchdog0/status
0x8000     # 0x8000 = WDOG_HW_RUNNING — the chip was already armed at probe
```

Notes (v1.6):

- `max_timeout` reads `0` — the driver declares the fixed ~671 s
  hardware window as `max_hw_heartbeat_ms` instead, so the framework
  accepts any soft timeout ≥ 1 s and bridges values beyond the window
  with its own pings.
- There is no `timeleft` attribute (and `WDIOC_GETTIMELEFT` returns
  `EOPNOTSUPP`): the hardware has no readable countdown, and earlier
  versions answered with the constant `timeout`, which was not a
  time-left.

### 4. The feeder is running

```
# pidof watchdog
123
# ps | grep [w]atchdog
  123 root      /sbin/watchdog -t 30 /dev/watchdog
```

### 5. Direct register read-back (optional)

The WDT control register lives at physical `0x1800311C` (`devmem` takes
physical addresses on this SoC):

```
# devmem 0x1800311C 32
0x00240000     # WDTE=0x00 (run), OVSEL=1001 (max bucket), WDTCLR auto-cleared
```

A value with the top byte `0xA5` (e.g. `0xA5240000`) means the chip is
stopped.

---

## Configuration

### Device tree (compile-time)

`arch/mips/boot/dts/realtek/rtl819x.dtsi`:

```dts
watchdog: watchdog@311c {
    compatible = "realtek,rtl8196e-wdt";
    reg = <0x0000311c 0x4>;
    timeout-sec = <60>;
};
```

`timeout-sec` sets the soft framework timeout. The chip itself is always
armed at OVSEL=1001 (~671 s ceiling at slowclk=25 kHz); the soft
timeout drives the **framework's** ping cadence (it pings at
`timeout/2`) and userspace's expectation of "how long can I be silent".

### Module parameter

The driver has one parameter, read-only at module load:

| Param      | Type | Default | Effect                                                                            |
|------------|------|---------|-----------------------------------------------------------------------------------|
| `nowayout` | bool | `0`     | If `1`, once the driver is open it cannot be disarmed (no Magic-Close, no stop)   |

Pass via kernel command line:

```
rtl819x_wdt.nowayout=1
```

(The driver is built `=y` in the current kernel config, so there is no
`insmod` to take a runtime arg.)

### Kernel config dependencies

The recovery story relies on three Kconfig options being set. All three
are wired in the kernel line's config (`config-6.18-realtek.txt` or
`config-7.1-realtek.txt`):

| Option                                | Why it matters                                           |
|---------------------------------------|----------------------------------------------------------|
| `CONFIG_RTL819X_WDT=y`                | The driver itself                                        |
| `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED` | Framework adopts a pre-armed chip without disarming it   |
| `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y` | Soft-lockup → `panic()` → our notifier → chip reset      |

---

## Disabling the watchdog (for debug)

There is no module to `rmmod` (`=y` build) and no sysfs disable.
Three practical options:

1. **Stop the feeder and let `nowayout=0` apply**

   ```
   # /etc/init.d/S25watchdog stop
   # printf 'V' > /dev/watchdog        # graceful Magic Close → disarm
   ```

   Note: this disarms the chip until someone re-opens `/dev/watchdog`.
   If you also do not want the framework to re-adopt on next open,
   either skip opening the device, or rebuild the kernel without
   `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED`.

2. **Force-stop without `V`** — *not* a clean disarm: the framework
   keeps the chip kicked from kernel context until the next open. Use
   only if you want to preserve safety while killing a misbehaving
   userspace feeder.

3. **Boot-time disable via DT removal** — comment out the
   `watchdog@311c` node in the DTS and rebuild the kernel.
   Reserved for kernel-bringup work where any reboot interferes with
   the debug session.

---

## Recovery scenarios in detail

### Restart path (`reboot`, `shutdown -r now`, `sysrq-b`)

The driver registers `watchdog_set_restart_priority(192)` at probe.
On reboot, the kernel calls `.restart` which writes `0` to `WDTCNR`:
WDTE=0x00 (run), OVSEL=0 (smallest bucket = 2^15 ticks ≈ 1.31 s at
25 kHz CDBR), WDTCLR=0. The chip overflows and resets the SoC within
the bucket window — typically observed at ~1.3 s wall time.

Priority 192 beats the arch-level `_machine_restart` fallback
(priority ~128), so our path wins whenever the driver has probed.

### Panic notifier path (kernel panic, soft-lockup, hard hangs)

`atomic_notifier_chain_register(&panic_notifier_list, ...)` with
`priority = INT_MAX`. When `panic()` fires, our callback runs first in
the chain and does the same `writel(0, base)` as the restart path —
chip reset within ~1.3 s.

We return `NOTIFY_DONE`, so other panic notifiers (crashlog dumpers,
console flushers) still get a turn inside the ~1.3 s grace window
before the chip overflows. They just no longer gate our reset write.

Without this path, a soft-lockup would spam the console every 22 s
indefinitely (the framework's auto-kicker keeps petting the chip from
softirq context, which still runs because syscall-return path drains).
With the path, a soft-lockup reboots the box autonomously in ~23 s —
22 s detection + ~1.3 s chip overflow.

### Userspace feeder failure

`/etc/init.d/S25watchdog` runs `watchdog -t 30 /dev/watchdog`.

| Failure mode                          | Outcome                                                                  |
|---------------------------------------|--------------------------------------------------------------------------|
| Feeder killed with `kill -9` (no `V`) | Framework auto-kicker keeps chip armed; safety net preserved             |
| Feeder closes with Magic-Close `V`    | Chip disarmed (`WDTE=0xA5`); next `/dev/watchdog` open re-arms it        |
| Userspace deadlocked, syscalls run    | Soft-lockup detector → panic → notifier path (see above)                 |
| Userspace deadlocked, no syscalls     | Soft-lockup detector → panic → notifier path (UP/PREEMPT_NONE assumption)|

---

## Troubleshooting

| Symptom                                                   | Likely cause / where to look                                                                 |
|-----------------------------------------------------------|----------------------------------------------------------------------------------------------|
| No `rtl819x-wdt` lines in `dmesg`                         | DT node missing / disabled, or `CONFIG_RTL819X_WDT` not set                                  |
| `last reset: watchdog timeout` after every boot           | Feeder not kicking, or kernel hangs during init                                              |
| Box reboots every ~60 s                                   | No userspace feeder + framework not adopting (check `WDOG_HW_RUNNING` in sysfs `status`)     |
| Box never reboots from a hang                             | `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC` not set, or panic chain wedged before our notifier       |
| `/dev/watchdog` open fails with `-EBUSY`                  | Another process already holds it (`fuser /dev/watchdog`)                                     |
| `WDTCNR` reads `0xA5...` after probe                      | Driver loaded but chip stopped — usually means userspace did a Magic-Close and never re-opened|

For the validation suite that covers all the above, see the test plan
at `~/.claude/plans/drifting-finding-lantern.md` (developer-side; not
checked into the public tree).

---

## Pointers

- Source: `rtl819x_wdt.c` (this directory).
- Design log + per-finding history: `AUDIT.md` (this directory).
- Device tree: `arch/mips/boot/dts/realtek/rtl819x.dtsi`, node
  `watchdog@311c`.
- Kernel config: `config-<line>-realtek.txt` (`config-6.18-realtek.txt` /
  `config-7.1-realtek.txt`) at the kernel build root.
- Userspace feeder init: `34-Userdata/skeleton/etc/init.d/S25watchdog`.
- BusyBox watchdog applet: `busybox.config` (`CONFIG_WATCHDOG=y`).
- Datasheet reference: RTL8196E-CG, Track ID JATR-3375-16 Rev. 1.0,
  table 27 (WDTCNR field layout).
