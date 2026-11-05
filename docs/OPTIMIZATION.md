# Measured optimization pass — 5 November 2026

This pass pauses feature development. Changes require a reproducible baseline,
preserved behavior, and a repeat of the same measurement after implementation.
The measurements below are local results on an M3 Pro MacBook Pro, macOS 27.0.1,
Xcode 26.6. They are not universal hardware guarantees.

## Changes supported by measurements

### Task board projection

Previously, every column lookup filtered and sorted reminders again, converting
due-date components to dates inside each sort comparison. The store now shares
one sorted selected-list snapshot and one column partition. Reminder changes,
list changes, and calendar/locale changes invalidate sorting; a local Doing move
invalidates the column partition. Notch height uses the same column counts.

Actual optimized production-store timings for one read of all three columns:

| Total synthetic reminders / selected list | Before median | After cold median | After warm median |
| --- | ---: | ---: | ---: |
| 100 / 60 | 1.729 ms | 0.144 ms | 0.0118 ms |
| 1,000 / 600 | 13.952 ms | 1.665 ms | 0.0070 ms |
| 5,000 / 3,000 | 93.898 ms | 11.811 ms | 0.0049 ms |

Five samples per case; cold forces a real cache miss, warm reuses unchanged
data. Full reminder values and exact ordering matched. These timings measure
data queries, not rendered frames. Cache retention adds arrays for the current
list, so this is not a claim of reduced task-data memory. See the
[benchmark report](testing/TASK_BOARD_PERFORMANCE.md), raw samples, and runner.

### Animation lifetime

Native mount/remove/remount/remove probes showed that the face and spectrum
continued firing after removal, and accumulated callbacks after remounting.
The face now uses a view-scoped cancellable task. The spectrum invalidates its
timer on detach, hiding, dismantling, and deinitialization.

Across four four-second phases, the preserved rerun measured face callbacks
`1 / 1 / 3 / 2` before and `1 / 0 / 1 / 0` after. Spectrum callbacks changed from
`13 / 15 / 26 / 28` to `13 / 0 / 14 / 0`. Minor visible-phase count differences
reflect timer scheduling; zero callbacks after removal and no accumulation are
the checks. Hidden, paused and released spectrum checks also pass. This proves
callback cleanup, not a quantified battery saving.

Run the [native lifecycle probe](testing/animation-lifecycle/README.md) without
showing a window, changing settings, or accessing personal data.

### Wheel-event task churn

The previous handler created and cancelled a 300 ms timeout task for each
unphased wheel event, including disabled or rejected gestures. A 200-event
replay created 200 tasks and cancelled 199. The new handler uses no timeout task
for disabled/header-rejected scrolling and one task for an accepted burst. Its
deadline follows the last event; rejection remains locked until actual inactivity.

Exact callback/phase behavior matched across 15 replay scenarios, including
momentum, cancellation, midstream enabling, teardown, and extended bursts.
The [replay runner](testing/gesture-timers/README.md) uses constructed native
events delivered directly to instrumented copies of the actual handler; it does
not post user input. This establishes fewer task allocations, not measured FPS.

### Unchanged meeting activity

A signed-app SwiftUI trace captured eight invalidation transactions originating
in `MeetingCoordinator.activity.setter` during an idle capture. The trace also
recorded 16 ContentView and 16 GeneralSettings body computations. Polling assigned
the same activity and snooze values repeatedly. Equality guards now suppress
unchanged published values, including an already-cleared suggestion. Detection
frequency, policy observation, notification invalidation and recording behavior
are preserved. Compare actual before/after trace counts before claiming an idle
CPU effect.

The completed fresh-process comparison measured mean idle CPU of **2.160% before
and 0.147% after**, using 15 two-second samples after discarding six warm-up
samples. Rounded process memory was **61 MB before and 62 MB after**; no memory
reduction is claimed. The after SwiftUI capture (12.862 seconds) contained zero
view-update rows, versus the idle updates above in the 12.854-second baseline.
A separate after-build sample still contains the meeting poll and activity
monitor stacks, confirming that monitoring remained active.

Both signed builds completed all eight native close/open cycles. However, the
Animation Hitches exports contained **zero frame-lifetime rows**, so their empty
hitch tables are inconclusive. They do not establish a frame-rate or hitch-rate
improvement. The 300-task native fixture separately passed scrolling to the
bottom and back, and reflected To do → Doing → Done moves with the expected
counts and preserved dates.

## Integrated verification

The full macOS test target passes 203 tests, including eight new task-projection
regressions and five new wheel-inactivity tests. The existing tests cover task
mutations, failures, meeting policy, notification cancellation, audio handling,
insertion, processing and other core behavior. Native fixture checks supplement
the test target; they do not replace a real call or a populated Reminders session.

Runtime captures and aggregate results are stored locally under
`build/verification/optimization-2026-11-05/`, with the final comparison in
`build/verification/optimization-2026-11-05/report.json`. Raw Instruments traces
are ignored build artifacts because they can contain process/environment details.
Only aggregate measurements belong in shareable reports.

For a reproducible runtime comparison:

1. Use the same signed Release configuration and preferences. Close the notch;
   do not run compilation or CPU benchmarks during the capture. Record the PID,
   build/source hashes, OS/tool versions, and workload.
2. Record `top -l 21 -s 2 -pid PID -stats pid,command,cpu,mem,threads,ports,time`.
   Discard the first six samples and summarize the remaining 15. Repeat with a
   fresh process on each build; retain the earlier long-running sample separately.
3. Record a 12-second Instruments SwiftUI capture with `xcrun xctrace record
   --template SwiftUI --attach PID --time-limit 12s --output TRACE`.
   Export the `swiftui-updates` and `swiftui-update-groups` tables with xctrace.
   [summarize_swiftui_trace.py](testing/summarize_swiftui_trace.py) resolves XML
   references and reports the relevant view and invalidation counts. Nested
   update durations overlap and must not be summed as CPU or frame time.
4. Record Animation Hitches while performing eight verified close/open cycles
   with the same input sequence. Retain capture and action timestamps and verify
   that frame records exist before interpreting the hitch table. Empty frame and
   hitch tables are inconclusive. Passing the UI actions alone is a smoke check,
   not proof of 120 FPS or of smoother behavior on every display and workload.

## Evidence limits and deferred investigations

No animation curve, transition duration, shadow, or display-refresh rate was
changed on an assumption of improved smoothness. Empty-notch interaction traces
and synthetic board checks are distinguished from a populated, authorized
Reminders board. Multi-display and physical pointer/trackpad validation remain
part of the release matrix.

Camera-discovery work when camera suggestions are off, per-display drag
monitor duplication, window-observer ownership, and broad ObservableObject
subscriptions remain investigation candidates. Source inspection alone does not
establish their performance impact. They require targeted call/lifetime probes
before a further implementation pass. Live transcription, notifications,
provider credentials and notarization remain independent release requirements.
