#!/usr/bin/env python3
"""Fail unless a local-hole candidate is structurally equivalent to its reference."""

import argparse
import json
import os
import re
import subprocess


def run(command):
    return subprocess.run(command, check=True, capture_output=True,
                          text=True).stdout


def symbols(path):
    result = {}
    duplicates = set()
    for line in open(path, encoding="utf-8"):
        fields = line.split()
        if len(fields) < 3:
            continue
        if fields[2] in result:
            duplicates.add(fields[2])
        else:
            result[fields[2]] = int(fields[0], 16)
    for name in duplicates:
        result.pop(name, None)
    return result


def output_sections(cross, path):
    result = {}
    for line in run([cross + "readelf", "-SW", path]).splitlines():
        match = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+"
                         r"[0-9a-f]+\s+([0-9a-f]+)", line)
        if match:
            result[match.group(1)] = (int(match.group(2), 16),
                                      int(match.group(3), 16))
    return result


def section_bytes(cross, obj, section):
    process = subprocess.run([cross + "objcopy", "-O", "binary",
                              "--only-section=" + section, obj, "/dev/stdout"],
                             check=True, capture_output=True)
    return process.stdout


def linked_input_sections(path, build):
    """Return exact linked addresses keyed by (object, input section)."""
    result = {}
    pending = None
    for line in open(path, encoding="utf-8", errors="replace"):
        fields = line.split()
        if len(fields) == 1 and fields[0].startswith(".text."):
            pending = fields[0]
            continue
        if (len(fields) >= 4 and fields[0].startswith(".text.")
                and fields[1].startswith("0x") and fields[2].startswith("0x")):
            section, address, size, obj = fields[0], fields[1], fields[2], fields[3]
        elif (pending and len(fields) >= 3 and fields[0].startswith("0x")
              and fields[1].startswith("0x")):
            section, address, size, obj = pending, fields[0], fields[1], fields[2]
        else:
            pending = None
            continue
        pending = None
        if not obj.endswith(".o"):
            continue
        start, length = int(address, 16), int(size, 16)
        if not length or start < 0x80000000:
            continue
        obj = os.path.relpath(os.path.abspath(os.path.join(build, obj)), build)
        key = (obj, section)
        if key in result:
            raise SystemExit(f"duplicate linked input section in reference map: {obj}:{section}")
        result[key] = (start, length)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--build-dir", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--cross", default="mips-lexra-linux-musl-")
    args = parser.parse_args()
    manifest = json.load(open(args.manifest, encoding="utf-8"))
    selected = sorted((item for item in manifest["candidates"]
                       if item.get("selected")),
                      key=lambda item: (item["address"], item["object"],
                                        item["section"]))
    ref_map = symbols(os.path.join(args.reference, "System.map"))
    cand_map = symbols(os.path.join(args.candidate, "System.map"))
    ref_elf = os.path.join(args.reference, "vmlinux")
    cand_elf = os.path.join(args.candidate, "vmlinux")
    ref_inputs = linked_input_sections(os.path.join(args.reference, "link.map"),
                                       os.path.abspath(args.build_dir))
    ref_sections = output_sections(args.cross, ref_elf)
    cand_sections = output_sections(args.cross, cand_elf)
    failures = []

    for name in (".text", ".rodata", ".data", ".bss", ".init.text", ".init.data"):
        if ref_sections.get(name) != cand_sections.get(name):
            failures.append(f"output section {name} changed: "
                            f"{ref_sections.get(name)} -> {cand_sections.get(name)}")
    iram_start = cand_map.get("__iram")
    iram_tail = cand_map.get("__iram_tail")
    if iram_start is None or iram_tail is None:
        failures.append("candidate lacks __iram/__iram_tail")
        iram_start = iram_tail = 0
    occupation = iram_tail - iram_start
    if occupation > manifest["budget"]:
        failures.append(f"I-MEM occupation {occupation} exceeds {manifest['budget']}")

    expected_roots = set()
    for order, item in enumerate(selected):
        root = f"__imem_hole_{order:04d}"
        expected_roots.add(root)
        linked = ref_inputs.get((item["object"], item["section"]))
        if linked is None:
            failures.append(f"reference map lacks {item['object']}:{item['section']}")
            continue
        expected, expected_size = linked
        if expected_size != item["size"]:
            failures.append(f"reference size changed for {item['object']}:"
                            f"{item['section']}: {item['size']} -> {expected_size}")
        if cand_map.get(root) != expected:
            failures.append(f"{root} is {cand_map.get(root)}, expected 0x{expected:08x}")
        obj = os.path.join(args.build_dir, item["object"])
        pristine = obj + ".imem-pristine"
        moved = f".iram.sel.{order:04d}"
        try:
            original_code = section_bytes(args.cross, pristine, item["section"])
            moved_code = section_bytes(args.cross, obj, moved)
            hole = section_bytes(args.cross, obj, item["section"])
        except subprocess.CalledProcessError as error:
            failures.append(f"cannot inspect {item['object']}:{item['section']}: {error}")
            continue
        if original_code != moved_code:
            failures.append(f"code changed for {item['object']}:{item['section']}")
        if len(hole) != len(original_code) or any(hole):
            failures.append(f"local hole is not exact zero padding for {item['section']}")

    for name, address in ref_map.items():
        candidate_address = cand_map.get(name)
        if candidate_address is None or candidate_address == address:
            continue
        if name == "__iram_tail" or name in expected_roots:
            continue
        if iram_start <= candidate_address < iram_tail:
            continue
        failures.append(f"external symbol moved: {name} "
                        f"0x{address:08x}->0x{candidate_address:08x}")
        if len(failures) >= 50:
            break

    result = {
        "pass": not failures,
        "selected_sections": len(selected),
        "occupation": occupation,
        "budget": manifest["budget"],
        "output_sections_checked": 6,
        "failures": failures,
    }
    with open(args.out, "w", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    if failures:
        for failure in failures:
            print("FAIL:", failure)
        raise SystemExit(1)
    print(f"local-hole invariants: PASS ({len(selected)} sections, "
          f"{occupation}/{manifest['budget']} bytes)")


if __name__ == "__main__":
    main()
