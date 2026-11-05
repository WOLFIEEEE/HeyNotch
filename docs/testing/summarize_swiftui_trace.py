#!/usr/bin/env python3
"""Summarize xctrace XML exports without copying process environment or user data.

Export swiftui-updates and swiftui-update-groups from the same trace first.
Durations of nested SwiftUI updates overlap; they are not elapsed CPU or frame time.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def load(path):
    root = ET.parse(path).getroot()
    refs = {element.attrib["id"]: element for element in root.iter() if "id" in element.attrib}

    def resolve(element):
        return refs[element.attrib["ref"]] if "ref" in element.attrib else element

    def text(element):
        element = resolve(element)
        return element.attrib.get("fmt") or element.text or ""

    schema = root.find(".//schema")
    columns = [column.findtext("mnemonic") for column in schema.findall("col")]
    rows = [dict(zip(columns, row)) for row in root.findall(".//row")]
    return rows, resolve, text


def summarize(updates, groups):
    rows, resolve, text = load(updates)
    counts, durations, types = Counter(), Counter(), Counter()
    for row in rows:
        description = text(row["description"])
        counts[description] += 1
        durations[description] += int(resolve(row["duration"]).text or "0")
        types[text(row["update-type"])] += 1
    selected = {
        name: {"count": count, "nested_duration_ms": durations[name] / 1_000_000}
        for name, count in counts.items()
        if any(token in name for token in (
            "AppBodyAccessor<DynamicNotchApp>", "ViewBodyAccessor<ContentView>",
            "ViewBodyAccessor<GeneralSettings>"))
    }
    rows, resolve, text = load(groups)
    causes = Counter()
    for row in rows:
        for frame in resolve(row["cause-backtrace"]).findall("frame"):
            name = resolve(frame).attrib.get("name", "")
            if name.startswith("MeetingCoordinator."):
                causes[name] += 1
                break
    return {
        "update_types": dict(types),
        "selected_view_updates": selected,
        "meeting_invalidation_causes": dict(causes),
        "limitations": "Nested update durations overlap. Counts are trace observations, not FPS or battery measurements."
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("updates", type=Path)
    parser.add_argument("groups", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = json.dumps(summarize(args.updates, args.groups), indent=2) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")
