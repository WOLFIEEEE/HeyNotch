#!/usr/bin/env python3
"""Measure native animation lifecycle callbacks without launching HeyNotch."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[2]
FACE = Path("HeyNotch/components/AnimatedFace.swift")
SPECTRUM = Path("HeyNotch/components/Music/MusicVisualizer.swift")


def replace_once(source, old, new):
    count = source.count(old)
    if count != 1:
        raise ValueError(f"Probe hook expected once, found {count}: {old!r}")
    return source.replace(old, new, 1)


def instrument_face(source):
    if "private func blinkWhileVisible() async {" in source:
        source = replace_once(source, ".task {\n            await blinkWhileVisible()",
                              ".task {\n            TimerProbe.faceAppears += 1\n"
                              "            defer { TimerProbe.faceDisappears += 1 }\n"
                              "            await blinkWhileVisible()")
        source = replace_once(source, "private func blinkWhileVisible() async {",
                              "private func blinkWhileVisible() async {\n        TimerProbe.faceStarts += 1")
        source = replace_once(source, "            withAnimation(.spring(duration: 0.2)) {\n                isBlinking = true",
                              "            TimerProbe.faceTicks += 1\n"
                              "            withAnimation(.spring(duration: 0.2)) {\n                isBlinking = true")
    else:
        source = replace_once(source, ".onAppear {\n            startBlinking()\n        }",
                              ".onAppear {\n            TimerProbe.faceAppears += 1\n            startBlinking()\n        }\n"
                              "        .onDisappear { TimerProbe.faceDisappears += 1 }")
        source = replace_once(source, "func startBlinking() {",
                              "func startBlinking() {\n        TimerProbe.faceStarts += 1")
        source = replace_once(source, "repeats: true) { _ in",
                              "repeats: true) { _ in\n            TimerProbe.faceTicks += 1")
    return source


def instrument_spectrum(source):
    source = source.split("#Preview", 1)[0]
    source = replace_once(source, "animationTimer = Timer.scheduledTimer",
                          "TimerProbe.spectrumStarts += 1\n        animationTimer = Timer.scheduledTimer")
    source = replace_once(source, "repeats: true) { [weak self] _ in",
                          "repeats: true) { [weak self] _ in\n            TimerProbe.spectrumTicks += 1")
    if "deinit {" in source:
        source = replace_once(source, "deinit {", "deinit {\n        TimerProbe.spectrumDeinits += 1")
    else:
        source = replace_once(source, "class AudioSpectrum: NSView {",
                              "class AudioSpectrum: NSView {\n    deinit { TimerProbe.spectrumDeinits += 1 }")
    return source


def validate(result):
    rows = {row["phase"]: row for row in result["phases"]}
    failures = []
    for phase in ("mounted-1", "mounted-2"):
        for key in ("faceTicks", "spectrumTicks"):
            if rows[phase][key] <= 0:
                failures.append(f"{phase}: {key} did not advance")
    for phase in ("removed-1", "removed-2"):
        for key in ("faceTicks", "spectrumTicks"):
            if rows[phase][key] != 0:
                failures.append(f"{phase}: {key} continued after removal")
    for phase in ("native-hidden", "native-paused", "native-detached-released"):
        if rows[phase]["spectrumTicks"] != 0:
            failures.append(f"{phase}: spectrum timer continued")
    for phase in ("native-attached-playing", "native-unhidden-playing", "native-resumed"):
        if rows[phase]["spectrumTicks"] <= 0:
            failures.append(f"{phase}: spectrum timer did not resume")
    if rows["removed-2"]["faceAppears"] != 2 or rows["removed-2"]["faceDisappears"] != 2:
        failures.append("Expected two complete SwiftUI appearance/disappearance cycles")
    if not result["spectrumReleased"]:
        failures.append("Detached spectrum was not released")
    if result["panelWasVisible"]:
        failures.append("Probe panel unexpectedly became visible")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=REPOSITORY,
                        help="Root holding the two production files; defaults to this checkout")
    parser.add_argument("--output", type=Path, required=True,
                        help="New JSON evidence file; existing files are not overwritten")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This probe requires macOS and an installed Xcode Swift toolchain")
    if args.output.exists():
        parser.error(f"Output already exists: {args.output}")
    sources = {path: (args.source_root / path).read_text() for path in (FACE, SPECTRUM)}
    with tempfile.TemporaryDirectory(prefix="heynotch-animation-probe-") as folder:
        work = Path(folder)
        (work / "Face.swift").write_text(instrument_face(sources[FACE]))
        (work / "Spectrum.swift").write_text(instrument_spectrum(sources[SPECTRUM]))
        executable = work / "animation-lifecycle-probe"
        target = f"{platform.machine()}-apple-macos14.0"
        compile_result = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-strict-concurrency=targeted", "-target", target,
            str(HERE / "AnimationLifecycleProbe.swift"), str(work / "Face.swift"), str(work / "Spectrum.swift"),
            "-o", str(executable)
        ], capture_output=True, text=True, timeout=90, check=True)
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=45, check=True)
    result = json.loads(run.stdout)
    failures = validate(result)
    report = {
        "schemaVersion": 1,
        "recordedAtUTC": datetime.now(timezone.utc).isoformat(),
        "host": {"macOS": platform.mac_ver()[0], "architecture": platform.machine()},
        "sourceSHA256": {str(path): hashlib.sha256(text.encode()).hexdigest() for path, text in sources.items()},
        "method": "Unshown nonactivating NSPanel, native SwiftUI mount/remove cycles and NSView hide/pause/release",
        "scope": "Callback counts, not a whole-app CPU, energy, or frame-rate benchmark",
        "compilerDiagnostics": compile_result.stderr,
        "runtimeDiagnostics": run.stderr,
        "result": result,
        "passed": not failures,
        "failures": failures,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    print(json.dumps(report, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, subprocess.SubprocessError, OSError) as error:
        print(f"Animation lifecycle probe failed: {error}", file=sys.stderr)
        raise SystemExit(2)
