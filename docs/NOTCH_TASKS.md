# Configurable notch home and task kanban

## Opening page

**Settings → General → Notch behavior → Page shown on hover** offers Tasks, Music & Calendar, Shelf, and Last used page. Tasks is the new default. An explicitly enabled legacy Remember last tab preference migrates to Last used page; the old implicit preference for a populated Shelf no longer overrides the chosen home. Last used page persists across launches. A disabled Shelf resolves to Tasks.

The notch’s context menu also exposes the opening-page choice. Tabs put Tasks first, label the selected page, and remain accessible when Shelf is disabled. The Music tab continues to include the existing calendar view. Closed-notch music/HUD behavior remains separate from the expanded hover page.

## Kanban behavior

The notch Tasks page displays three columns:

| Column | Storage and effect |
| --- | --- |
| To do | An incomplete reminder without local Doing status. |
| Doing | Local progress saved by stable reminder ID on this Mac. Moving here does not rewrite the task’s title, notes, list, due date, alarms, or recurrence. |
| Done | The reminder’s actual completed flag. Moving out of Done uncompletes it in Reminders. |

Each column scrolls vertically and shows its count. Cards show two-line titles, due dates, overdue indication, and recurring status. Clicking a card opens the existing task editor. A visible actions menu and context menu offer movement without dragging. A private typed drag payload is scoped to the current board session/list; unknown, foreign-list, read-only, stale, and pending task operations are rejected.

Moves serialize with edits, completion, deletion, and Undo for the same reminder. Local progress changes only after any required Reminders write succeeds. External completion wins over local Doing. Stale progress is removed only after a successful full fetch. Failed writes keep the prior state and expose an error. Task creation continues to use the existing reviewed editor and exact-ID Undo.

The full Tasks window retains its date-grouped list for broader task management. The notch header provides quick list selection, Add, voice task, and Open Tasks actions.

## Height and interaction

The task notch is normally up to 800 points wide. Height grows from 290 points with the tallest column, bounded by **Maximum task board height** (320–600 points, default 500) and the display’s available height. The actual window resizes and remains anchored to the screen’s top center. Music and Shelf retain the compact 640×190 layout, constrained by small displays. Below the space needed for three 185-point columns, the board can scroll horizontally.

Moving or completing a card does not shrink the current open panel away from the pointer. Closing/reopening or switching pages recomputes the compact height. Changing the height limit applies immediately.

The upward close gesture is attached only to the header. The opening gesture is disabled over an open board and installs no competing drag gesture there. Native scroll events pass through to the column; momentum cannot reopen or dismiss the notch, and one physical swipe activates at most once. A gesture that begins in task content cannot become a close gesture by moving into the header.

Hover closure waits briefly and rechecks actual pointer bounds, including after resizing. Open menus hold the notch open until tracking ends. A header close button provides an explicit alternative to the gesture. Internal task drags are excluded from Shelf detection. File dragging opens Shelf only when Shelf is enabled. The keyboard-open timeout also checks pointer/menu interaction before closing.

## Validation and limits

The combined macOS test target contains 190 tests after this change: 15 new kanban tests, 12 gesture-policy regressions, and 6 landing-page/sizing tests alongside the existing 157. The tests cover completion/local-progress mapping, persistence, external completion, write failures, invalid/list/read-only moves, concurrent mutations, stale fetches, gesture region/momentum/lifecycle handling, opening preferences, and size bounds.

Native interaction evidence is recorded in `build/verification/notch-kanban-2026-11-05.json`. The signed app was checked for Tasks as its opening page, changing the preference to Music and back, native window growth between pages, and changing/restoring the maximum-height slider. The signed candidate currently shows the Reminders setup state; no access permission was changed for this check.

An isolated native window using unchanged production board/store/gesture sources and an in-memory repository verified long-column scrolling in both directions without dismissal, click-to-edit, and menu moves through To do, Doing, and Done while retaining due dates. Native card dragging did not produce a verified move through the available automation; it remains implemented but unverified end to end. Header trackpad swipes, a populated board in the actual notch, multi-display arrangements, all input hardware, and older macOS versions remain part of the broader release matrix. No existing personal reminders were changed. The meeting/provider/notarization gates in [release readiness](RELEASE_READINESS.md) remain separate.
