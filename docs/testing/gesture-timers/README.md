# Gesture timeout replay

This small macOS executable measures timeout `Task` creation/cancellation counts in the actual `PanGesture.swift` handler. It constructs `NSEvent` instances and calls the copied handler directly against an unattached `NSView`. It does not post events, install an event monitor, create a window, run `NSApplication`, or launch UI. It does not access the HeyNotch container, Reminders, microphone, camera, or provider keys.

The runner copies the specified production sources, adds two integer counters, widens only the handler's visibility within the copied file, and appends the replay entry point. It preserves the handler's decisions. The output includes source/harness hashes, original and instrumented copies, compiler logs, and raw JSON.

Run the current sources from the repository root:

```sh
python3 docs/testing/gesture-timers/run_probe.py \
  --output build/verification/optimization-2026-11-05/gesture-after
```

The measured pre-optimization source snapshots and raw results are stored under `build/verification/optimization-2026-11-05/gesture-before`. Replay that snapshot with the same harness when comparing a future change:

```sh
python3 docs/testing/gesture-timers/run_probe.py \
  --output build/verification/optimization-2026-11-05/gesture-before-replay \
  --pan-source build/verification/optimization-2026-11-05/gesture-before/PanGesture.swift.original.txt \
  --policy-source build/verification/optimization-2026-11-05/gesture-before/NotchGesturePolicy.swift.original.txt

python3 docs/testing/gesture-timers/run_probe.py \
  --output build/verification/optimization-2026-11-05/gesture-after-replay \
  --compare build/verification/optimization-2026-11-05/gesture-before-replay/results.json
```

`--compare` requires exact parity in observed event kinds, callback distances/phases, activation counts, end counts, and the early-end check. Only timeout task creation and cancellation counts may differ. It exits unsuccessfully if behavior differs.

The scenarios cover disabled scrolling, scrolling outside the header, accepted wheel input, enabling or entering the header mid-burst, a phased stream with no observed start, separate wheel bursts, rejected input followed by inactivity, an extended burst, deactivation, explicit cancellation, teardown/restart, and phased/orphan momentum. Real 380 ms quiet intervals exercise the actual 300 ms timer; the extended burst checks that feedback does not end while more events are arriving.

These are source-level handler replay and task-count measurements. They do **not** measure CPU speedup, memory bytes, displayed FPS, physical trackpad hardware behavior, event delivery/window scoping, SwiftUI hit testing, or notch hover integration. Those require separate native UI validation. The counters are plain variables and do not trigger SwiftUI updates.
