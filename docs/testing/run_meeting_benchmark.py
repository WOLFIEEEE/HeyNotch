#!/usr/bin/env python3
"""Verify both meeting channels using generated speech, without live recording.

First populate --cache with run_speech_benchmark.py. Uses the same pinned SDK
and verified Turbo model, then compiles the current app's streaming primitives.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from run_speech_benchmark import ROOT, REVISION, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "heynotch-speech-check")
    parser.add_argument("--output", type=Path, default=Path("meeting-benchmark-local.json"))
    options = parser.parse_args()
    cache = options.cache.expanduser().resolve()
    sdk = cache / "argmax-oss-swift"
    actual = subprocess.check_output(["git", "-C", str(sdk), "rev-parse", "HEAD"], text=True).strip()
    if actual != REVISION:
        raise SystemExit("The cached SDK differs from the pinned revision.")
    model = next(m for m in json.loads((ROOT / "HeyNotch/Voice/Runtime/SpeechModels.json").read_text()) if m["id"] == "turbo")
    folder = cache / "models/turbo"
    for item in model["files"]:
        path = folder / item["path"]
        if not path.exists() or path.stat().st_size != item["size"] or digest(path) != item["sha256"]:
            raise SystemExit("Model verification failed. Run run_speech_benchmark.py to prepare the pinned cache.")
    project = cache / "meeting-benchmark"
    source = project / "Sources/Benchmark"
    source.mkdir(parents=True, exist_ok=True)
    for relative in ["Voice/Core/VoiceModels.swift", "Voice/Core/BoundedAudioBuffer.swift", "Voice/Runtime/LocalSpeechEngine.swift", "Meetings/Core/MeetingModels.swift"]:
        shutil.copy2(ROOT / "HeyNotch" / relative, source / Path(relative).name)
    shutil.copy2(Path(__file__).with_name("MeetingSpeechBenchmark.swift"), source / "Main.swift")
    package = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "HeyNotchMeetingCheck", platforms: [.macOS(.v14)],
    dependencies: [.package(path: SDK_PATH)],
    targets: [.executableTarget(name: "Benchmark", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")])])
'''.replace("SDK_PATH", json.dumps(str(sdk)))
    (project / "Package.swift").write_text(package)
    subprocess.run(["swift", "build", "-c", "release", "--package-path", str(project)], check=True)
    paths = []
    for name, text in [("microphone", "Do not send the invoice yet. The total is forty two dollars and fifty cents."),
                       ("call", "Please schedule the design review for Friday at ten thirty. Bring the updated notes.")]:
        path = cache / f"meeting-{name}.aiff"
        subprocess.run(["say", "-v", "Samantha", "-r", "155", "-o", str(path), text], check=True)
        paths.append(str(path))
    output = options.output.expanduser().resolve()
    subprocess.run([str(project / ".build/release/Benchmark"), str(folder), *paths, str(output)], check=True)
    print(f"Saved results to {output}")


if __name__ == "__main__":
    main()
