#!/usr/bin/env python3
"""Replay constructed NSEvents through actual gesture-handler copies without launching UI."""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True, help='Dedicated output directory for copies, executable, logs and JSON')
parser.add_argument('--pan-source', type=Path, default=ROOT / 'HeyNotch/extensions/PanGesture.swift')
parser.add_argument('--policy-source', type=Path, default=ROOT / 'HeyNotch/Tasks/Core/NotchGesturePolicy.swift')
parser.add_argument('--compare', type=Path, help='Earlier results.json; require identical callback traces and scenario behavior')
args = parser.parse_args()
if platform.system() != 'Darwin':
    parser.error('The actual AppKit/SwiftUI handler requires macOS.')
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
manifest = {'instrumentation': 'Two integer Task counters, handler visibility, appended replay main; gesture logic unchanged', 'sources': []}
harness = (Path(__file__).parent / 'ProbeMain.swift.txt').read_text()
for source_path, filename in [(args.pan_source, 'PanGesture.swift'), (args.policy_source, 'NotchGesturePolicy.swift')]:
    source_path = source_path.resolve()
    original = source_path.read_text()
    original_copy = output / (filename + '.original.txt')
    original_copy.write_text(original)
    manifest['sources'].append({'source': str(source_path), 'sha256': hashlib.sha256(original.encode()).hexdigest()})
    value = original
    if filename == 'PanGesture.swift':
        probes = {
            'private var endTask: Task<Void, Never>?': 'private var endTask: Task<Void, Never>?\n        var probeCreated = 0\n        var probeCancelled = 0',
            'endTask = Task {': 'probeCreated += 1\n            endTask = Task {',
            'private func handleScroll(': 'fileprivate func handleScroll('
        }
        for needle, replacement in probes.items():
            if value.count(needle) != 1:
                raise RuntimeError(f'Source shape changed; review probe insertion: {needle}')
            value = value.replace(needle, replacement)
        if 'endTask?.cancel()' not in value:
            raise RuntimeError('Cancellation probe site missing; review the current handler')
        value = value.replace('endTask?.cancel()', 'if endTask != nil { probeCancelled += 1 }; endTask?.cancel()')
        value += '\n' + harness
    (output / filename).write_text(value)
manifest['harnessSHA256'] = hashlib.sha256(harness.encode()).hexdigest()
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
command = ['xcrun', 'swiftc', '-target', f'{platform.machine()}-apple-macos14.0', '-parse-as-library', '-O',
           str(output / 'PanGesture.swift'), str(output / 'NotchGesturePolicy.swift'), '-o', str(output / 'probe')]
compiled = subprocess.run(command, capture_output=True, text=True)
(output / 'build.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stdout + compiled.stderr, file=sys.stderr)
    sys.exit(compiled.returncode)
replayed = subprocess.run([str(output / 'probe')], capture_output=True, text=True, timeout=30)
(output / 'run.log').write_text(replayed.stderr)
if replayed.returncode:
    print(replayed.stdout + replayed.stderr, file=sys.stderr)
    sys.exit(replayed.returncode)
results = json.loads(replayed.stdout)
(output / 'results.json').write_text(json.dumps(results, indent=2, sort_keys=True) + '\n')
if args.compare:
    baseline = json.loads(args.compare.read_text())['results']
    current = results['results']
    if len(baseline) != len(current):
        raise AssertionError('Scenario counts differ; rerun both snapshots with the same harness')
    ignored = {'timeoutTasksCreated', 'timeoutTasksCancelled'}
    for before, after in zip(baseline, current):
        if {k:v for k,v in before.items() if k not in ignored} != {k:v for k,v in after.items() if k not in ignored}:
            raise AssertionError(f'Behavior differs in {before["case"]}')
    (output / 'comparison.txt').write_text(f'Exact callback trace, event-kind, activation, end/cancel/reset behavior matches for all {len(current)} scenarios.\n')
    print(f'Behavior parity: {len(current)} scenarios matched.')
for row in results['results']:
    print(f'{row["case"]}: events={row["events"]}, timeout tasks={row["timeoutTasksCreated"]}, cancellations={row["timeoutTasksCancelled"]}, activations={row["activations"]}, ends={row["endedCallbacks"]}')
print(f'Results: {output / "results.json"}')
