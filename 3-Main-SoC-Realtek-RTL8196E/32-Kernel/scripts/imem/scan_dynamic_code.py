#!/usr/bin/env python3
"""Find the code the kernel patches at runtime, and keep it out of I-MEM.

The hardware constraint, stated once:

    I-MEM is a non-coherent SRAM copy taken at boot. _imem_dmem_init()
    programs the COP3 instruction window and triggers IRAM Fill, which
    copies the SDRAM range into on-chip SRAM. Nothing refreshes it
    afterwards. A write to the SDRAM shadow therefore never reaches the
    instructions the CPU actually fetches.

So any code that something patches at runtime is ineligible for the window.
Not "discouraged", not "allowed with a note": ineligible, because the two
outcomes are a warning or -- worse -- a patch that reports success while the
CPU keeps executing the old instruction.

Linux keeps most of its patch sites in tables that name text addresses, so
the rule can be checked rather than reasoned about. This reads whichever of
those tables the image actually contains, maps every site onto the candidate
that owns it, and marks that candidate ineligible.

Two failure modes are treated as errors rather than as "nothing found",
because a scanner that silently reports an empty table would mark every
candidate eligible and hand the problem straight back to the linker:

  * a table whose symbols exist but whose entries do not decode to addresses
    inside [_stext, _end] -- the layout guess is wrong for this arch;
  * a configuration that patches text with no table at all. CONFIG_KPROBES
    can patch any instruction anywhere; there is no subset of the kernel it
    leaves alone, so it is incompatible with a non-coherent window and the
    scan refuses instead of producing a list that would look reassuring.

Usage:
  scan_dynamic_code.py --reference variants/E --manifest manifest/candidates.json \
      --config ../linux-6.18-rtl8196e/.config
  scan_dynamic_code.py ... --annotate manifest/candidates.json
  scan_dynamic_code.py --reference variants/T --manifest ... --gate-window
"""
import argparse
import bisect
import json
import os
import re
import subprocess
import sys

# Tables Linux uses to record "here is an instruction I may rewrite".
#
#   entry   bytes per record
#   at      byte offset of the text address inside a record
#   rel     the stored value is an offset from its own location
#
# A table is scanned when its delimiter symbols exist in the image. That is
# deliberate: keying off the config symbol instead would mean a mis-guessed
# name silently skips a live table.
TABLES = [
    {"name": "__jump_table", "start": "__start___jump_table",
     "stop": "__stop___jump_table", "entry": 12, "at": 0, "rel": False,
     "what": "static key"},
    {"name": "__mcount_loc", "start": "__start_mcount_loc",
     "stop": "__stop_mcount_loc", "entry": 4, "at": 0, "rel": False,
     "what": "ftrace call site"},
    {"name": "static_call_sites", "start": "__start_static_call_sites",
     "stop": "__stop_static_call_sites", "entry": 8, "at": 0, "rel": True,
     "what": "static call"},
    {"name": "altinstructions", "start": "__alt_instructions",
     "stop": "__alt_instructions_end", "entry": 12, "at": 0, "rel": True,
     "what": "alternative"},
]

# Patchers with no table: they can rewrite any instruction, so no candidate
# could ever be shown to be safe.
UNBOUNDED = {
    "CONFIG_KPROBES": "kprobes can patch any instruction in the kernel",
    "CONFIG_LIVEPATCH": "livepatch redirects arbitrary functions at runtime",
}


def die(msg):
    sys.exit(f"dynamic-code scan: {msg}")


def read_map(path):
    sym = {}
    for line in open(path):
        f = line.split()
        if len(f) >= 3:
            sym.setdefault(f[2], []).append(int(f[0], 16))
    return sym


def read_config(path):
    cfg = {}
    if not path or not os.path.exists(path):
        return cfg
    for line in open(path):
        line = line.strip()
        if line.startswith("CONFIG_") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k] = v
    return cfg


def sections(cross, elf):
    out = []
    for line in subprocess.run([cross + "readelf", "-SW", elf],
                               capture_output=True, text=True,
                               check=True).stdout.splitlines():
        m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+"
                     r"([0-9a-f]+)\s+([0-9a-f]+)", line)
        if m and int(m.group(3), 16):
            out.append((m.group(1), int(m.group(3), 16), int(m.group(5), 16)))
    return out


def bytes_at(cross, elf, secs, addr, length):
    """Raw image bytes for a virtual address range."""
    host = next((s for s in secs if s[1] <= addr < s[1] + s[2]), None)
    if host is None:
        die(f"no section contains 0x{addr:08x}")
    name, base, _ = host
    tmp = f"/tmp/.dyn-{os.getpid()}.bin"
    subprocess.run([cross + "objcopy", "-O", "binary", "--only-section=" + name,
                    elf, tmp], check=True, capture_output=True)
    data = open(tmp, "rb").read()
    os.unlink(tmp)
    return data[addr - base: addr - base + length], name


def scan(cross, elf, mapfile, cfg):
    """Every runtime-patch site the image declares."""
    sym = read_map(mapfile)
    secs = sections(cross, elf)
    stext, end = sym["_stext"][0], sym.get("_end", sym.get("_edata"))[0]

    blocked = [f"{k}: {why}" for k, why in UNBOUNDED.items()
               if cfg.get(k) == "y"]
    if blocked:
        die("this configuration patches text with no table to bound it, so no "
            "function can be shown safe for a non-coherent window:\n  "
            + "\n  ".join(blocked))

    sites, scanned, absent = [], [], []
    for t in TABLES:
        if t["start"] not in sym or t["stop"] not in sym:
            absent.append(t["name"])
            continue
        lo, hi = sym[t["start"]][0], sym[t["stop"]][0]
        n = (hi - lo) // t["entry"]
        if n == 0:
            scanned.append((t["name"], 0))
            continue
        if (hi - lo) % t["entry"]:
            die(f"{t['name']} spans {hi - lo} B, not a multiple of the "
                f"{t['entry']} B record this tool expects")
        raw, _ = bytes_at(cross, elf, secs, lo, hi - lo)
        found = []
        for i in range(n):
            off = i * t["entry"] + t["at"]
            v = int.from_bytes(raw[off:off + 4], "big")
            a = (lo + off + v) & 0xffffffff if t["rel"] else v
            found.append(a)
        # A layout guess that is wrong for this arch decodes to nonsense.
        # Saying so is the whole point: an empty or garbage table would
        # otherwise read as "no site here, everything is eligible".
        strays = [a for a in found if not (stext <= a <= end)]
        if strays:
            die(f"{t['name']}: {len(strays)} of {n} entries decode outside "
                f"[_stext, _end] (first 0x{strays[0]:08x}). The record layout "
                f"assumed here does not match this kernel -- fix it rather "
                f"than trusting the result.")
        sites += [(a, t["name"], t["what"]) for a in found]
        scanned.append((t["name"], n))
    return sites, scanned, absent, sym


def owners(sites, man, sym):
    """Map each site onto the candidate whose slot contains it.

    Slot addresses come from the reference image, where every candidate is
    still in .text at its own slot -- so ownership is read off the layout
    rather than guessed from the nearest symbol.
    """
    slots = []
    for c in man["candidates"]:
        tag = f"__imem_slot_{c['slot']:03d}"
        if tag not in sym:
            die(f"{tag} is not defined: this reference was not built with the "
                f"arena, so ownership cannot be established")
        a = sym[tag][0]
        slots.append((a, a + c["size"], c))
    slots.sort()
    starts = [s[0] for s in slots]

    hits = {}
    for addr, table, what in sites:
        i = bisect.bisect_right(starts, addr) - 1
        if i < 0:
            continue
        lo, hi, c = slots[i]
        if lo <= addr < hi:
            hits.setdefault(c["section"], []).append(
                {"addr": addr, "table": table, "what": what})
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference", required=True,
                    help="a build directory with vmlinux and System.map")
    # Needed only to say which candidate owns a site. The window gate is a
    # statement about the hardware, so it must not depend on a campaign
    # artefact being present -- it has to run on an ordinary build too.
    ap.add_argument("--manifest")
    ap.add_argument("--config", help="the .config that was built")
    ap.add_argument("--cross", default="mips-lexra-linux-musl-")
    ap.add_argument("--annotate", help="rewrite this manifest with eligibility")
    ap.add_argument("--gate-window", action="store_true",
                    help="fail if any site sits inside [__iram, __iram_tail)")
    ap.add_argument("--json", help="write the findings here")
    a = ap.parse_args()

    elf = os.path.join(a.reference, "vmlinux")
    mapfile = os.path.join(a.reference, "System.map")
    cfg = read_config(a.config)
    if not a.gate_window and not a.manifest:
        die("--manifest is needed to attribute sites to candidates; "
            "--gate-window works without it")

    sites, scanned, absent, sym = scan(a.cross, elf, mapfile, cfg)

    print("=== runtime code-patching scan ===")
    for name, n in scanned:
        print(f"  {name:20s} {n:5d} site(s)")
    for name in absent:
        print(f"  {name:20s}     - not present in this image")

    if a.gate_window:
        if "__iram" not in sym:
            print("\n  ok    no I-MEM window in this image")
            return
        lo, hi = sym["__iram"][0], sym["__iram_tail"][0]
        inside = [(addr, t, w) for addr, t, w in sites if lo <= addr < hi]
        if inside:
            print(f"\n  FAIL  {len(inside)} runtime-patch site(s) inside the "
                  f"I-MEM window 0x{lo:08x}-0x{hi:08x}:")
            for addr, t, w in sorted(inside):
                print(f"        0x{addr:08x}  {t}  ({w})")
            print("        I-MEM is a non-coherent copy: these would either "
                  "warn or be patched in SDRAM only.")
            sys.exit(1)
        print(f"\n  ok    no runtime-patch site inside the I-MEM window "
              f"0x{lo:08x}-0x{hi:08x}")
        return

    man = json.load(open(a.manifest))
    hits = owners(sites, man, sym)
    print(f"\n  {len(hits)} of {len(man['candidates'])} candidates host a "
          f"runtime-patch site and are ineligible for I-MEM:\n")
    by_section = {c["section"]: c for c in man["candidates"]}
    for s in sorted(hits, key=lambda s: by_section[s]["slot"]):
        c, h = by_section[s], hits[s]
        kinds = sorted({x["what"] for x in h})
        print(f"    slot {c['slot']:3d}  {c['name']:42s} {c['size']:5d} B  "
              f"{len(h)} site(s), {', '.join(kinds)}")

    if a.json:
        json.dump({"scanned": dict(scanned), "absent": absent,
                   "ineligible": {s: hits[s] for s in hits}},
                  open(a.json, "w"), indent=1, sort_keys=True)

    if a.annotate:
        n_in = 0
        for c in man["candidates"]:
            h = hits.get(c["section"])
            if h:
                c["imem_eligible"] = False
                c["ineligible_reason"] = sorted({
                    f"{x['table']} ({x['what']})" for x in h})
                n_in += 1
            else:
                c["imem_eligible"] = True
                c.pop("ineligible_reason", None)
        man["eligibility"] = {
            "rule": "I-MEM is a non-coherent SRAM copy taken at boot, so a "
                    "candidate containing any instruction the kernel patches "
                    "at runtime is ineligible. There is no allowlist.",
            "tables_scanned": dict(scanned),
            "tables_absent": absent,
            "ineligible": n_in,
            "eligible": len(man["candidates"]) - n_in,
        }
        json.dump(man, open(a.annotate, "w"), indent=1)
        print(f"\n  annotated {a.annotate}: "
              f"{len(man['candidates']) - n_in} eligible, {n_in} ineligible")
        print("  slots are unchanged -- an ineligible candidate keeps its slot, "
              "so the arena, the layout and the profile stay valid.")


if __name__ == "__main__":
    main()
