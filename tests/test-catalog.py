#!/usr/bin/env python3
"""tests/test-catalog.py — keep the tool lists from drifting apart.

Fails if supported-tools.json, config.example.json, and 支持的软件列表.md
disagree on the set (and, for the two JSON files, the order) of target names.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_json(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as handle:
        return json.load(handle)


def main():
    catalog = load_json("supported-tools.json")
    example = load_json("config.example.json")
    catalog_names = [tool["name"] for tool in catalog["tools"]]
    example_names = list(example["targets"].keys())

    errors = []
    if catalog_names != example_names:
        errors.append(
            "supported-tools.json vs config.example.json names/order differ:\n"
            "  catalog: %s\n"
            "  example: %s" % (catalog_names, example_names)
        )

    list_path = os.path.join(ROOT, "支持的软件列表.md")
    with open(list_path, encoding="utf-8") as handle:
        listing = handle.read()
    missing_from_list = [name for name in catalog_names if name not in listing]
    if missing_from_list:
        errors.append(
            "支持的软件列表.md is missing: %s" % ", ".join(missing_from_list)
        )

    count_match = re.search(r"共\s*(\d+)\s*个", listing)
    if count_match and int(count_match.group(1)) != len(catalog_names):
        errors.append(
            "支持的软件列表.md says 共 %s 个 but catalog has %d"
            % (count_match.group(1), len(catalog_names))
        )

    def target_path(value):
        if isinstance(value, dict):
            return value.get("path") or value.get("skills")
        return value

    required_fields = ("name", "marker", "skills")
    for tool in catalog["tools"]:
        for field in required_fields:
            if not tool.get(field):
                errors.append("catalog entry %r missing %s" % (tool, field))
        example_val = example["targets"].get(tool["name"])
        if target_path(example_val) != tool["skills"]:
            errors.append(
                "example path for %s is %r, catalog skills is %r"
                % (tool["name"], example_val, tool["skills"])
            )
        if tool.get("mode"):
            if not isinstance(example_val, dict) or example_val.get("mode") != tool["mode"]:
                errors.append(
                    "example %s must be {path, mode=%r}, got %r"
                    % (tool["name"], tool["mode"], example_val)
                )

    if errors:
        print("FAIL: catalog drift")
        for err in errors:
            print("  -", err)
        return 1
    print("OK: catalog (%d tools) matches example config and 支持的软件列表.md"
          % len(catalog_names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
