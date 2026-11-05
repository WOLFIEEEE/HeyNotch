# Task query performance, 5 November 2026

The measured problem was repeated filtering, sorting, and due-date conversion in `TaskBoardStore.visibleTasks`. Every `tasks(in:)` request repeated that work. The source contains four reads of each lane's `items` value, and notch height previously requested all three columns again. Those source references identify repeated work; they do **not** establish how many evaluations SwiftUI performs per frame.

The change caches one ordered selected-list snapshot and its three-column partition. Due dates are converted once per selected reminder during sorting. Reminder changes invalidate both snapshots; local Doing changes invalidate the partition. List, calendar, time-zone and locale changes are checked before reuse. Sorting retains the existing `localizedStandardCompare` tie-break, and cached results retain complete reminder values. The cache retains arrays for only the selected list, in addition to the repository's existing reminder array.

## Actual store measurements

The same harness compiled the before and after production store directly with `swiftc -O -whole-module-optimization`. It uses Foundation/Combine, a synthetic repository, and an isolated temporary preferences suite. It does not load EventKit, access real reminders, or perform reminder writes.

Each case has **five samples** after refresh, complete-value equality checks and warm-up. The initial after-store run measured warm reads. A follow-up run measured the actual store's cold rebuild: before each sample, it selected and read a missing list, then selected the active list again, leaving its first measured lookup to rebuild the snapshot. Selection/preference writes and refresh were outside the timer. p95 uses the nearest-rank method; with five samples it equals the observed maximum. These small sample counts show the scale of this query bottleneck, not a reliable production tail-latency distribution.

| Total reminders / selected | Queries | Before median / p95 (ms) | After cold median / p95 (ms) | After warm median / p95 (ms) |
| --- | ---: | ---: | ---: | ---: |
| 100 / 60 | 3 | 1.729 / 1.741 | 0.144 / 0.157 | 0.0118 / 0.0205 |
| 1,000 / 600 | 3 | 13.952 / 13.999 | 1.665 / 1.707 | 0.0070 / 0.0117 |
| 5,000 / 3,000 | 3 | 93.898 / 94.729 | 11.811 / 12.842 | 0.0049 / 0.0051 |
| 100 / 60 | 15 | 7.659 / 8.601 | 0.164 / 0.170 | 0.0518 / 0.0531 |
| 1,000 / 600 | 15 | 68.929 / 71.887 | 1.675 / 1.693 | 0.0355 / 0.0368 |
| 5,000 / 3,000 | 15 | 466.183 / 474.799 | 11.764 / 12.254 | 0.0232 / 0.0239 |

Three queries request every column once. Fifteen queries model the four source-level lane references plus one height-count request per column. The height caller now uses `tallestColumnCount`, so the 15-query case preserves the original workload for comparison rather than describing the new caller. Neither workload measures SwiftUI rendering, animation frame rate, pointer latency, or scrolling smoothness.

Before editing production code, a local prototype matched the full reminder values and ordering at all three sizes. Its cold-rebuild medians for three column queries were 0.137 / 1.490 / 11.001 ms at 100 / 1,000 / 5,000 total reminders. Those prototype timings justified implementation. The table above uses actual production-store cold and warm measurements, kept separate from the prototype. The final store matched full values/order again, and the task test suite passed all 29 tests, including eight new projection tests.

Fixtures are deterministic and shuffled. Sixty percent of reminders are in the selected list; the remainder occupy three other lists. They include open/completed/local Doing tasks, Unicode/numeric titles, undated/day-only/timed due dates, two explicit time zones, notes, alarms and recurrence flags. The checks retain exact task identity, all fields and ordering. Regression tests cover list switching, local moves, external refreshes, failed refresh/write, successful completion/deletion followed by failed fetch, edit reordering, and a calendar time-zone change that reverses day-only/fixed-time ordering. Live changes to the macOS locale and UI frame timing have not been measured by this harness.

## Reproduction and source identity

Run from the repository with no other build or benchmark active:

```sh
python3 docs/testing/run_task_board_benchmark.py --smoke
python3 docs/testing/run_task_board_benchmark.py --output /tmp/heynotch-task-results.csv
```

To compare an extracted historical source, pass `--store-source /absolute/path/TaskBoardStore.swift`. The runner records SHA-256 hashes of all compiled sources and deletes its temporary build directory. The harness removes its isolated preferences suite on normal completion.

The measured working tree was based on commit `8278c60dacb5b0c6f9f2783b8c305c692104ff60`; changes had not been committed. Exact store SHA-256 hashes:

- Before: `eeffaeea3e5c7e7f69a4d7b7f333448027931483916023ba7c4ad7a529474b26`
- After: `b4f1e3da82f3bd25ab295b4f55025fedd64e83a026f4cf5b7938358d3c8149b0`

Environment: arm64 macOS 27.0.1 build 26A434; 11 active CPUs; Gregorian calendar; `en_US@rg=inzzzz` locale; `Asia/Kolkata` current time zone. The harness's before/after checksum was `399942` in both runs. Raw results and complete metadata are preserved in:

- `task-board-before-2026-11-05.csv`
- `task-board-after-2026-11-05.csv`
- `task-board-cold-2026-11-05.csv`
- `task-board-benchmark-2026-11-05.json`

The CSV's `prototype-*` rows describe the local hypothesis implementation in the harness; use `production` for actual steady-state store queries and `production-cold` for actual rebuild-plus-query costs. The cold follow-up run also records warm rows; the table retains the original warm run to preserve the initial comparison. Microsecond-scale warm results vary with scheduling and CPU frequency; the evidence establishes removal of repeated sorting, not a guaranteed whole-app frame rate.
