# UX audit fixes — 6 November 2026

This change addresses the thirteen issues audited at `b4fd229274157ac1e1f8c293a870ebe3ba8ba17d`. It changes existing interactions, not the app's feature scope. Preview 3 uses app/XPC version 2.8.2 (274).

| Before | After | Regression coverage |
|---|---|---|
| Add/Edit/voice could replace unsaved task text. | Every proposal uses a shared Keep current / Replace confirmation; an exact-snapshot check rejects stale approvals or replacement during saving. | TaskBoardTests and MeetingTaskDraftTests: normal proposals, changed draft, approved replacement, in-flight save. |
| Cancel could close the editor after a save committed but while refresh continued. | Cancel is disabled during saving; the store also rejects draft cancellation until saving finishes. | TaskBoardTests: controlled post-commit refresh, rejected cancellation, save failure preserves draft. |
| External deletion left a broken Undo action after refresh/restart. | A successful current all-task fetch clears missing Undo targets and their persisted token. | TaskBoardTests: external deletion, failed/stale fetch, list moves, restart, automation refresh. |
| Switching lists left the previous list/count in the footer. | List summary derives from current selection/tasks; operation messages are separate. | TaskBoardTests: two lists with distinct counts, invalid list, operation message preservation. |
| Hidden tabs disappeared completely on switching to Music. | A compact native page menu remains available with the same enabled pages. | NotchInteractionRecoveryTests: Tasks to Music, last-used reopening, Shelf disabled, full-tab preferences. |
| The shortcut timer ignored an active battery popover. | All delayed close paths use the same eligibility rule for pointer, menu, popover, sharing and drop interactions. Explicit closing remains separate. | NotchInteractionRecoveryTests: each active interaction prevents automatic closing; dismissal permits closing. |
| Shelf Copy used shortened display text and omitted mixed content. | Exact strings/full links are collected with file URLs; plain-text consumers receive all selected non-file content. | ShelfTransferPayloadTests: whitespace/Unicode, URL scheme/query/fragment, mixed and multiple selections, file-only copying, unavailable file. |
| Sharing a selected text item ignored other selected items. | Copy and Share use the same selection resolution; Share preserves typed values and selection order. | ShelfTransferPayloadTests: clicked text in mixed selection, unselected clicked item fallback. |
| Cleanup overwrote newer Shelf changes after asynchronous validation. | Invalid results reconcile against current IDs and exact bookmark bytes, including pending bookmark refreshes; only matching entries are removed. | ShelfCleanupPolicyTests: suspended validation with addition, removal, refresh, cancellation, unchanged invalid entry. |
| Leaving Processing could restart cancelled verification after a key read. | Pane and snapshot reads recheck task cancellation and operation identity before starting work. | ProcessingControllerCancellationTests: controlled delayed key reads, pane disappearance, provider changes and late replies. |
| Cancel left active-work text after the spinner disappeared. | Active work receives a clear cancellation message without replacing completed or unrelated results. | ProcessingControllerCancellationTests: verification and model-test cancellation, completed result preservation. |
| Retry cleanup was visible after insertion when its handler could not run. | The UI and action share one eligibility rule and retain the duplicate-paste safeguard. | VoiceReviewPolicyTests: transcript/review/paste-attempt combinations. |
| Preparing valid installed models required space for another whole download. | Existing files are verified first; space is checked only for missing/invalid files plus the existing headroom. | SpeechModelStoreTests: complete cache, partial cache, insufficient space, corrupt/downloaded hash checks, local-only mode. |

## Verification boundaries

The integrated app tests exercise production core and storage code with fake repositories, keys and HTTP/download dependencies. Clipboard tests use private named pasteboards and isolated fixtures. Full application compilation checks the SwiftUI/AppKit integration; source review checks UI action wiring.

The initial app build exposed that the new navigation policy belonged in Tasks Core rather than Shared, because the XPC helper also compiles Shared without the page model. Its target membership was corrected before the successful builds. The existing MCP integration test requires a separately built debug connector; that fixture is built before the final complete suite.

No production Reminders, provider account, microphone, camera or global clipboard is used for these regressions. Automated checks do not establish live native menu/popover behavior, a fresh browser-to-Applications launch, cross-app paste/share acceptance, frame pacing or live call capture. Those limits remain explicit in the preview notes; no production-readiness certification is implied.

Integrated results and distribution verification are recorded in [release readiness](RELEASE_READINESS.md). The release includes the exact corresponding source and its source manifest.
