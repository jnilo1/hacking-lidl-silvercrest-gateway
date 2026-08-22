#!/usr/bin/env python3
"""Decode a big-endian /proc/profile histogram into per-function weights."""

import argparse
import bisect
import json
import struct

LINE = 16
TEXT_TYPES = set("tTwW")
IDLE = "realtek_wait"


def symbols(path):
    by_addr = {}
    for line in open(path, encoding="utf-8"):
        fields = line.split()
        if len(fields) == 3 and fields[1] in TEXT_TYPES:
            by_addr.setdefault(int(fields[0], 16), []).append(fields[2])
    return sorted(by_addr.items())


def profile(path):
    raw = open(path, "rb").read()
    if len(raw) < 4 or (len(raw) - 4) % 4:
        raise SystemExit(f"invalid /proc/profile dump: {path}")
    step = struct.unpack(">I", raw[:4])[0]
    count = (len(raw) - 4) // 4
    return step, struct.unpack(f">{count}I", raw[4:])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", required=True)
    parser.add_argument("--idle", action="append", required=True)
    parser.add_argument("--symbols", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--duration", type=float, required=True)
    args = parser.parse_args()

    syms = symbols(args.symbols)
    addrs = [addr for addr, _ in syms]
    stext = next(addr for addr, names in syms if "_stext" in names)
    etext = next(addr for addr, names in syms if "_etext" in names)
    step, load = profile(args.load)
    idle_profiles = [profile(path) for path in args.idle]
    if step != LINE or any(s != LINE for s, _ in idle_profiles):
        raise SystemExit("all captures must use profile=4 (16-byte buckets)")
    if any(len(values) != len(load) for _, values in idle_profiles):
        raise SystemExit("load and idle profile lengths differ")
    idle = [sum(column) / len(idle_profiles)
            for column in zip(*(values for _, values in idle_profiles))]

    funcs = {}
    work_total = 0.0
    for index, raw_hits in enumerate(load):
        hits = raw_hits - idle[index]
        if hits <= 0:
            continue
        addr = stext + index * step
        pos = bisect.bisect_right(addrs, addr) - 1
        if pos < 0 or not (stext <= addr < etext):
            continue
        sym_addr, aliases = syms[pos]
        if IDLE in aliases:
            continue
        end = addrs[pos + 1] if pos + 1 < len(addrs) else etext
        name = sorted(aliases, key=lambda value: (value.startswith("__"),
                                                  len(value), value))[0]
        entry = funcs.setdefault(sym_addr, {
            "name": name,
            "aliases": sorted(aliases),
            "addr": f"0x{sym_addr:08x}",
            "size": end - sym_addr,
            "samples": 0.0,
            "lines": {},
        })
        entry["samples"] += hits
        offset = addr - sym_addr
        entry["lines"][str(offset)] = entry["lines"].get(str(offset), 0.0) + hits
        work_total += hits

    names = {}
    for entry in funcs.values():
        names[entry["name"]] = names.get(entry["name"], 0) + 1
    functions = []
    for entry in funcs.values():
        entry["samples"] = round(entry["samples"], 3)
        entry["lines"] = {key: round(value, 3)
                          for key, value in entry["lines"].items()}
        entry["share"] = entry["samples"] / work_total if work_total else 0.0
        entry["name_copies_sampled"] = names[entry["name"]]
        functions.append(entry)
    functions.sort(key=lambda entry: -entry["samples"])
    result = {
        "label": args.label,
        "duration_s": args.duration,
        "step": step,
        "stext": f"0x{stext:08x}",
        "etext": f"0x{etext:08x}",
        "samples_work": round(work_total, 3),
        "functions": functions,
    }
    with open(args.out, "w", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(f"{args.label}: {work_total:.0f} net work samples, "
          f"{len(functions)} sampled functions")


if __name__ == "__main__":
    main()
