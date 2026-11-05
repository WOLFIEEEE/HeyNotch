#!/usr/bin/env python3
"""Compile/run the synthetic task query harness. Does not use Apple Reminders."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true", help="One 100-reminder sample instead of the full fixture matrix")
    parser.add_argument("--store-source", type=Path, help="Optional historical TaskBoardStore.swift to compare with the current source")
    parser.add_argument("--output", type=Path, help="Save metadata and CSV output to this file")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    sources = [
        repo / "HeyNotch/Tasks/Core/TaskModels.swift",
        repo / "HeyNotch/Tasks/Core/TaskDateParser.swift",
        repo / "HeyNotch/Tasks/Core/TaskKanbanModels.swift",
        args.store_source.resolve() if args.store_source else repo / "HeyNotch/Tasks/Core/TaskBoardStore.swift",
        repo / "HeyNotch/Processing/Core/ProcessingModels.swift",
        repo / "docs/testing/TaskBoardBenchmark.swift",
    ]
    metadata = ["# source_sha256 " + hashlib.sha256(path.read_bytes()).hexdigest() + " " + str(path) for path in sources]
    with tempfile.TemporaryDirectory(prefix="heynotch-task-benchmark-") as directory:
        executable = Path(directory) / "benchmark"
        subprocess.run(["swiftc", "-O", "-whole-module-optimization", "-parse-as-library",
                        *map(str, sources), "-o", str(executable)], check=True)
        command = [str(executable)] + (["--smoke"] if args.smoke else [])
        result = subprocess.run(command, check=True, capture_output=True, text=True)
    output = "\n".join(metadata) + "\n" + result.stdout
    if args.output:
        args.output.write_text(output)
    else:
        print(output, end="")


if __name__ == "__main__":
    main()
