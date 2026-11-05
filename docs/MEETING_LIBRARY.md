# Meeting library and transcript tools

Implemented as a focused extension to meeting transcription. These features do not change the explicit Start requirement, microphone/system-audio permissions, or the outstanding live-call release gates.

## Optional local history

In **Settings → Meetings**, enable **Keep meeting transcripts on this Mac**. It is off by default. Enabling it saves the current transcript if there is one, then saves new text after each decoded section or gap and again when processing finishes. The library stores text and meeting metadata only: no raw recordings, provider keys, or model output from a cloud service.

- **Retention:** 30 days from the original meeting start, with at most 50 sessions and 2 MiB per session. Renaming does not extend the retention date. Expiry runs at startup, when opening the library, periodically while HeyNotch runs, and before new saves. It also applies while history is switched off. If the app is not running, expiry happens the next time it runs.
- **Storage:** the app’s Application Support directory, under `HeyNotch/MeetingHistory/`. In the signed sandboxed build this is inside `~/Library/Containers/com.wolfieeee.heynotch/Data/Library/Application Support/`. The private directory uses owner-only permissions; each versioned JSON snapshot is atomically replaced with owner read/write permissions. This is ordinary local storage, not a separate encrypted vault. User-managed backups and separately exported copies are outside the library’s deletion controls.
- **Recovery:** each successful snapshot preserves section IDs, source labels, timestamps, text, and gap markers. A session that did not finish is displayed as a partial transcript. Opening it never resumes capture. Speech still in memory or awaiting decoding at the moment of a crash cannot be recovered.
- **Off:** stops new snapshots but leaves prior text readable until deleted or expired.
- **Delete / Clear history:** confirmation is required in the UI. Deleting the current session or clearing the library prevents that session’s next decoded section from recreating it. The current transcript stays in its window; future sessions follow the history setting. Exported files and existing Reminders tasks remain untouched.
- **Errors:** invalid, oversized, or unreadable snapshots are not silently overwritten. Failures are shown in the library and recording window; a failed current-session save keeps its own warning and offers **Retry history save**. The current transcript remains available to copy or export. Clearing is limited to owned history files.

**Meeting Library…** is available in the menu and with **Command–Shift–L**. Search matches titles, call sources, and transcript passages. Saved sessions can be renamed, copied, exported, or deleted. Reading history uses a separate window and never replaces the active recording.

## Reading and exporting

Current and archived transcripts use the same reader. **Command–F** focuses passage search. Search is case/diacritic insensitive and normalizes whitespace without changing the stored words. Source filtering offers All sources, Microphone, and Call audio. Equal timestamps keep their original order. Source labels identify channels, not people.

Each passage has a visible actions menu as well as a context menu: **Copy passage**, **Copy with timestamp and source**, and **Create task…**. Gap markers cannot be converted into tasks.

**Copy all / Save all…** always includes every passage, even while filtering. Plain-text and Markdown exports preserve timestamps and gap labels. Markdown escapes transcript markup so spoken links, image syntax, HTML, or headings remain literal text. Unsafe control characters are represented visibly in Markdown; the original stored text is unchanged. Exporting an unfinished archive includes a partial-transcript notice.

## Reviewed tasks

**Create task…** opens a new task draft, never a saved reminder. The entire original passage and its meeting title, position, and source remain in the notes. A long passage gets a bounded title without truncating the source notes.

No date or notification is inferred: “tomorrow” in a past meeting must not become tomorrow relative to today. The user reviews the task, chooses its intended date/list, and explicitly saves it. Meeting-derived drafts remain local and do not offer AI task assistance.

If another draft is already open, **Keep current** is the default. **Replace draft** is explicit and only replaces the exact draft that was reviewed; a save or edit completing while the alert is open invalidates the replacement. Creating a draft makes no Reminders write.

## Verification

The combined macOS test suite passed **157 tests** on 5 November 2026, including 20 history tests, 10 transcript-tool tests, and 11 meeting-task tests. The 42 repository checks also passed. Coverage includes opt-in/off behavior, round-trip recovery, stable identifiers, both channels and gaps, retention and size/count limits, rename, deletion suppression, corrupt/failed writes, search/filter ordering, Unicode, literal Markdown, task provenance, undated review, and stale-draft protection. Native-window results are recorded separately in `build/verification/meeting-library-2026-11-05.json` after validation.

The signed Release app was launched and its history-off default, library menu/shortcut, empty library, and Settings controls inspected. Preparing the installed model worked. Starting with microphone authorization still pending and then cancelling immediately returned to idle, with “Recording has not started.” This does not test a later permission response or actual capture.

Populated library UI was exercised in a separate native fixture app, using unchanged copies of the actual library views/controller and transcript tools; only the copied store’s directory was redirected to synthetic test data. Search/diacritic matching, channel filters, no-result state, rename, recovered-session labels, gap action disabling, and Cancel in the deletion confirmation passed. A Markdown file saved through the native save panel contained all five passages even when the current filter showed zero, preserving Unicode/negation and escaping markup. Capture and task dependencies in this fixture were inert; this verifies populated UI behavior, not sandboxed Release integration or live task creation. The fixture was closed afterward and no real transcript data was added.

These tests verify transcript management. They do not establish live call capture, notification delivery under Focus, provider credential interoperability, notarization, or the hardware/application matrix. Those remain separate gates in [release readiness](RELEASE_READINESS.md).
