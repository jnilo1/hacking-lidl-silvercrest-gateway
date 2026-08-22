#!/usr/bin/env python3
"""Gate the linked structure of a production RTL8196E I-MEM policy."""

import argparse
import json
import os
import re
import subprocess

IMEM_BUDGET = 15872


def command(*args):
    return subprocess.check_output(args, text=True, errors="replace")


def symbols(nm, image):
    result = {}
    for line in command(nm, "-n", image).splitlines():
        fields = line.split()
        if len(fields) >= 3 and re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
            result[fields[2]] = int(fields[0], 16)
    return result


def section_size(objdump, image, name):
    for line in command(objdump, "-h", image).splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[1] == name:
            return int(fields[2], 16)
    raise SystemExit(f"linked output section {name} is absent")


def policy_entries(path):
    entries = []
    with open(path, encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, 1):
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 2 or not all(fields):
                raise SystemExit(f"{path}:{line_number}: invalid policy entry")
            entries.append(tuple(fields))
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--cross", default="mips-lexra-linux-musl-")
    args = parser.parse_args()

    with open(args.report, encoding="utf-8") as stream:
        report = json.load(stream)
    if report.get("schema") != 1:
        raise SystemExit("unsupported or missing policy-report schema")
    if report.get("budget") != IMEM_BUDGET:
        raise SystemExit(f"policy report budget is not {IMEM_BUDGET} bytes")
    expected = policy_entries(args.policy)
    reported = [(item["object"], item["section"])
                for item in report["entries"]]
    if reported != expected:
        raise SystemExit("policy report does not reproduce the versioned entry order")
    if report["sections"] != len(expected):
        raise SystemExit("policy report section count is inconsistent")
    if not expected:
        raise SystemExit("production I-MEM policy is empty")

    image = os.path.join(os.path.abspath(args.build_dir), "vmlinux.unstripped")
    table = symbols(args.cross + "nm", image)
    required = ("_stext", "_etext", "__iram", "__iram_tail")
    missing = [name for name in required if name not in table]
    if missing:
        raise SystemExit("missing linked boundary symbol(s): " + ", ".join(missing))
    roots = {name: address for name, address in table.items()
             if re.fullmatch(r"__imem_hole_[0-9]{4}", name)}
    expected_roots = {f"__imem_hole_{index:04d}" for index in range(len(expected))}
    if set(roots) != expected_roots:
        raise SystemExit("linked local-hole root set differs from the policy")
    outside_text = [name for name, address in roots.items()
                    if not table["_stext"] <= address < table["_etext"]]
    if outside_text:
        raise SystemExit("local-hole root(s) outside .text: " + ", ".join(outside_text))
    in_window = [name for name, address in roots.items()
                 if table["__iram"] <= address < table["__iram_tail"]]
    if in_window:
        raise SystemExit("local-hole root(s) incorrectly linked into I-MEM")

    linked_size = section_size(args.cross + "objdump", image, ".iram")
    if linked_size != report["occupation"]:
        raise SystemExit(f"linked .iram size {linked_size} != policy occupation "
                         f"{report['occupation']}")
    if linked_size > report["budget"]:
        raise SystemExit("linked .iram exceeds the hardware policy budget")
    if table["__iram_tail"] - table["__iram"] != linked_size:
        raise SystemExit("I-MEM boundary symbols disagree with the output section size")

    print("=== production I-MEM structural gate ===")
    print(f"  policy entries : {len(expected)}")
    print(f"  local holes    : {len(roots)} (all inside .text)")
    print(f"  linked .iram   : {linked_size}/{report['budget']} bytes")
    print("  result         : PASS")


if __name__ == "__main__":
    main()
