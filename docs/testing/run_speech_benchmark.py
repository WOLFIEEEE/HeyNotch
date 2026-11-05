#!/usr/bin/env python3
"""Reproduce the local speech check using generated audio and pinned model assets.

Run on macOS with Xcode's Swift toolchain. Downloads about 800 MB on first use.
This never records the microphone, reads user documents, or calls an AI provider.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
REVISION = "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4"


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
        return value.hexdigest()


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "heynotch-speech-check")
    parser.add_argument("--output", type=Path, default=Path("speech-benchmark-local.json"))
    options = parser.parse_args()
    cache = options.cache.expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    sdk = cache / "argmax-oss-swift"
    if not sdk.exists():
        run("git", "clone", "--depth", "1", "--branch", "v1.1.1", "https://github.com/argmaxinc/argmax-oss-swift.git", str(sdk))
    actual = subprocess.check_output(["git", "-C", str(sdk), "rev-parse", "HEAD"], text=True).strip()
    if actual != REVISION:
        raise SystemExit("The SDK checkout differs from the pinned revision. Use a new cache directory.")
    manifests = json.loads((ROOT / "HeyNotch/Voice/Runtime/SpeechModels.json").read_text())

    def download(item):
        model, file = item
        target = cache / "models" / model["id"] / file["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.stat().st_size == file["size"] and digest(target) == file["sha256"]:
            return
        temporary = target.with_name(target.name + ".partial")
        with urllib.request.urlopen(file["url"], timeout=120) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output, 1024 * 1024)
        if temporary.stat().st_size != file["size"] or digest(temporary) != file["sha256"]:
            raise ValueError("A downloaded model file failed integrity verification")
        temporary.replace(target)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(download, [(model, file) for model in manifests for file in model["files"]]))
    project = cache / "benchmark"
    source = project / "Sources/Benchmark"
    source.mkdir(parents=True, exist_ok=True)
    for relative in ["Core/VoiceModels.swift", "Runtime/LocalSpeechEngine.swift"]:
        shutil.copy2(ROOT / "HeyNotch/Voice" / relative, source / Path(relative).name)
    package = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "HeyNotchSpeechCheck", platforms: [.macOS(.v14)],
    dependencies: [.package(path: SDK_PATH)],
    targets: [.executableTarget(name: "Benchmark", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")])])
'''.replace("SDK_PATH", json.dumps(str(sdk), ensure_ascii=False))
    (project / "Package.swift").write_text(package)
    shutil.copy2(Path(__file__).with_name("SpeechBenchmark.swift"), source / "Main.swift")
    run("swift", "build", "-c", "release", "--package-path", str(project))
    clips = [
        ("facts", "Samantha", "Do not send the invoice yet. The total is forty two dollars and fifty cents."),
        ("task", "Samantha", "Please schedule the design review for Friday at ten thirty. Bring the updated notes."),
        ("hindi", "Lekha", "कल सुबह दस बजे डॉक्टर को फोन करना है। कृपया नई रिपोर्ट साथ लाना।"),
    ]
    available = subprocess.check_output(["say", "-v", "?"], text=True)
    audio_paths = []
    for name, voice, text in clips:
        if not any(line.startswith(voice + " ") for line in available.splitlines()):
            print(f"Skipping {name}: the {voice} system voice is not installed.")
            continue
        path = cache / f"{name}.aiff"
        run("say", "-v", voice, "-r", "155", "-o", str(path), text)
        audio_paths.append(str(path))
    if not audio_paths:
        raise SystemExit("No benchmark system voices are installed.")
    results = []
    for model in manifests:
        run(str(project / ".build/release/Benchmark"), model["id"], str(cache / "models"), *audio_paths)
        results.append(json.loads((cache / "models" / f"benchmark-{model['id']}.json").read_text()))
    options.output.write_text(json.dumps({"method": "Generated system speech; local processing only", "results": results}, ensure_ascii=False, indent=2) + "\n")
    print(f"Saved results to {options.output.resolve()}")


if __name__ == "__main__":
    main()
