# Native animation lifecycle probe

This probe copies the current `AnimatedFace.swift` and `MusicVisualizer.swift` into a temporary directory, adds counter hooks to those copies, and compiles them with a small AppKit/SwiftUI harness. Production files are never rewritten. If an expected hook changes, instrumentation fails rather than silently measuring a different path.

Run from the repository root on macOS with Xcode installed:

```sh
python3 docs/testing/animation-lifecycle/run.py \
  --output build/verification/animation-lifecycle.json
```

The native portion takes about 24 seconds. It never launches HeyNotch, shows or activates a window, requests permissions, plays or captures audio, or reads or changes app settings, Reminders, meetings, or other user data. An unshown, nonactivating `NSPanel` provides the native view lifecycle; explicit layout triggers SwiftUI appearance/disappearance. Only temporary compiler files and the requested JSON artifact are written. The runner refuses to overwrite an existing artifact.

The first four phases mount both views, remove them, mount them again, then remove them again, each for four seconds. The following six 1.2-second phases exercise the spectrum while attached and playing, hidden, shown again, paused, resumed, and finally detached/released. Counters observe real callbacks from the production implementation; they do not invoke or replace the animation update logic. Counts aggregate all instrumented instances in that probe process, so an unfixed orphan timer can contribute callbacks during later phases even when the current instance is paused.

JSON includes source hashes, platform details, phase counts, lifecycle counts, diagnostics and validation results. Exit `0` means all lifecycle checks passed, `1` means callbacks continued when they should have stopped or failed to run when expected, and `2` means the probe could not run. Exact active callback counts may vary slightly with scheduling; the checks require positive active counts and zero inactive counts. This is a lifecycle regression probe, not a measurement of whole-app CPU, battery, rendering performance, or whether an occluded window should animate.

For a captured source snapshot with the same relative file paths, use `--source-root /path/to/snapshot`. This is useful for reproducing the before/after result without reverting the working tree. The original observations and source snapshots from the 2026-11-05 audit are kept locally under `build/verification/optimization-2026-11-05/`; the before version is expected to exit `1`.

The face uses a SwiftUI task whose cancellation follows disappearance. The spectrum explicitly stops its repeating timer when hidden, detached, dismantled or released. Reappearing and resuming must still start animation. Apple documents that a run loop retains repeating timers until they are invalidated: [Timer documentation](https://developer.apple.com/documentation/foundation/timer).
