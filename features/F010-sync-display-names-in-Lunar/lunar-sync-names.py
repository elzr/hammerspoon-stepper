#!/usr/bin/env python3
"""Update Lunar display names based on UUID-to-position mapping.

Usage:
    lunar-sync-names.py '{"uuid1": "←Left", "uuid2": "Right→", ...}'

Reads Lunar's plist, finds display entries matching each UUID (serial field),
updates the name field, and writes back. Exits with code 0 if any names
changed, 1 if nothing to do, 2 on error.
"""

import sys
import json
import plistlib
import subprocess
import os

LUNAR_DOMAIN = "fyi.lunar.Lunar"

def read_plist():
    """Read Lunar's preferences via defaults export."""
    tmp = "/tmp/lunar-sync-names.plist"
    result = subprocess.run(
        ["defaults", "export", LUNAR_DOMAIN, tmp],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Error reading Lunar prefs: {result.stderr}", file=sys.stderr)
        sys.exit(2)
    with open(tmp, "rb") as f:
        return plistlib.load(f)

def write_plist(data):
    """Write modified preferences back via defaults import."""
    tmp = "/tmp/lunar-sync-names.plist"
    with open(tmp, "wb") as f:
        plistlib.dump(data, f)
    result = subprocess.run(
        ["defaults", "import", LUNAR_DOMAIN, tmp],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Error writing Lunar prefs: {result.stderr}", file=sys.stderr)
        sys.exit(2)

def main():
    if len(sys.argv) < 2:
        print("Usage: lunar-sync-names.py '{uuid: name, ...}'", file=sys.stderr)
        sys.exit(2)

    uuid_to_name = json.loads(sys.argv[1])
    data = read_plist()
    displays = data.get("displays", [])

    changed = []
    for i, d_str in enumerate(displays):
        d = json.loads(d_str)
        serial = d.get("serial", "")
        if serial in uuid_to_name:
            new_name = uuid_to_name[serial]
            old_name = d.get("name", "")
            if old_name != new_name:
                d["name"] = new_name
                displays[i] = json.dumps(d)
                changed.append(f"{old_name!r} -> {new_name!r}")

    if not changed:
        print("No name changes needed")
        sys.exit(1)

    data["displays"] = displays
    write_plist(data)

    for c in changed:
        print(f"Updated: {c}")
    print(f"Total: {len(changed)} display(s) renamed")

if __name__ == "__main__":
    main()
