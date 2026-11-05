# Phases 1–5: implementation and verification

Updated 5 November 2026. Work is local on `codex/phase-0-foundation`; nothing has been pushed or published. This record distinguishes implemented behavior from the acceptance checks still needed for a public release.

The subsequently requested meeting reminders and both-channel transcription are documented in [MEETINGS.md](MEETINGS.md). The combined test suite now has **116 passing Swift tests**; the 83-test count below records the earlier core-phase verification.

## Delivered behavior

| Phase | Implementation |
|---|---|
| 1 · Cross-app insertion | Shared typed XPC contracts; signed-peer validation; target/field/selection capture; Accessibility and secure-input checks; single-use operations; clipboard ownership and format preservation; bounded cancellation/deadlines; explicit Copy recovery; configurable shortcut and nonactivating status panel. |
| 2 · Processing | Independent Claude, OpenAI, and OpenRouter configurations; Keychain keys; searchable live model catalogues and manual IDs; pagination/cache/revision handling; exact provider/model requests; separate metadata verification and paid model tests; structured-capability tests; safe errors; cancellation and request deadlines. |
| 3 · Local dictation | Pinned WhisperKit 1.1.1; pinned model/tokenizer revisions and per-file SHA-256 verification; download progress/cancel/retry; free-space checks and model deletion; input/language selection; two-minute memory-bounded recording; 16 kHz conversion at the engine boundary; hold/toggle/task shortcuts; audio levels; Escape/release/watchdog cancellation; device/sleep/memory-pressure handling; idle unload; persistent feedback and transcript recovery. |
| 4 · Optional cleanup | Off/Light/Formal; transcript-as-data prompts; provider/configuration revision checks; final-output validation; conservative checks for numbers, URLs, negation, names, and language; original/Retry/Copy recovery; no automatic insertion retry; timing/token usage and price-based estimates where metadata exists. Explicit dictation never creates reminders. |
| 5 · Reminders tasks | Separate task/due/alarm models; shared EventKit lifecycle; all-date queries including undated tasks; writable list/account selection; optional HeyNotch list creation/reuse; create/edit/complete/delete; deterministic English scheduling rules; review for ambiguity/recurrence; optional reviewed AI suggestions; Overdue/Today/Upcoming/No date/Completed sections; exact-ID Undo; save-operation journal to prevent uncertain replays; reminder links reopen the corresponding list in HeyNotch. |

Implementation lives in `Shared/`, `HeyNotch/Insertion/`, `HeyNotch/Processing/`, `HeyNotch/Voice/`, `HeyNotch/Tasks/`, and the existing XPC helper. Pure domain logic is also compiled into the hostless `HeyNotchTests` target. Model weights are downloaded separately; the app bundles only the manifest.

## Verification completed locally

- **83 Swift tests passed**, covering provider request/response fixtures, settings persistence and key rotation, clipboard recovery, target changes, duplicate/cancelled insertion, speech gates, cleanup protection, task parsing, draft recovery, CRUD state, and exact-ID Undo.
- **42 repository Python tests passed.** Fork ownership, update gating, and workflow safeguards remain intact.
- **Debug and universal Release builds passed** with Xcode 26.6. The Release executable contains both `arm64` and `x86_64`. New Voice/Tasks/Processing/Insertion code produced no build warnings in the verified Release build; inherited concurrency warnings remain outside this scope.
- The development app and embedded helper were signed with the local Apple Development identity and verified using strict/deep code-signature checking.
- **TextEdit insertion worked through the actual signed helper.** The fixed sentence appeared in an isolated test document. A subsequent insertion replaced selected text with Unicode and multiline content. HeyNotch reported clipboard restoration. Automated named-pasteboard tests independently cover rich/image formats and preserving a newer copy.
- Provider settings were inspected in the running app: all three provider choices, provider-specific account context, model controls, empty-key behavior, and clear API-credit/privacy text were present. No user API key was read or entered during these checks.
- Speech download cancellation returned to a retryable state. Retry reused verified files. Actual local model execution processed generated English and Hindi audio; details are below.
- **Real Apple Reminders checks:** an undated test task saved, remained visible after relaunch, and accepted an edit; exact-ID Undo removed it. A second temporary task was also removed with Undo. A date-only task saved in Today with “Include a time” off and was then removed with Undo. All temporary reminders were cleaned up. The editor now uses an explicit native sheet lifecycle and closes after save/cancel.
- Reminders access was already granted on the test Mac. Tests used clearly labelled temporary reminders; existing reminders were not edited.

The UI automation initially clicked TextEdit in the background while HeyNotch remained frontmost. The focus guard correctly refused insertion. Opening the isolated text document through Finder established the actual foreground target, and the signed insertion path then succeeded. The guard was not relaxed to make the test pass.

## Speech model choice and measurements

Engine: [Argmax OSS / WhisperKit 1.1.1](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.1), revision `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`.

Model repository: [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml), pinned revision `0f63a7800b00dd0226abd051b906c246e1907482`. Tokenizer revisions and SHA-256 hashes for every asset are in [`SpeechModels.json`](../HeyNotch/Voice/Runtime/SpeechModels.json).

| Measurement on an Apple M3 Pro, 18 GiB RAM | Base multilingual | Compressed Turbo |
|---|---:|---:|
| Download including tokenizer | 149,482,602 bytes | 648,432,373 bytes |
| Model load after system compilation caches exist | about 0.90 s | about 2.28 s |
| Repeated English clip transcription (about 4.7–4.8 s audio) | about 0.11 s | about 0.58–0.61 s |
| Repeated Hindi clip transcription (about 4.8 s audio) | about 0.19 s | about 1.16 s |

Turbo's first model preparation took about **176 seconds** on this machine. Preparation is separate from recording so a cold model does not consume the beginning of an utterance. The final Turbo benchmark process peaked at about **281 MB resident memory** and **216 MB physical footprint**, as reported by `/usr/bin/time -l`; those figures exclude some system Core ML/Neural Engine services and are not a whole-system memory claim.

Both models preserved the main facts in the generated English samples, including negation and `$42.50`. Base produced mixed-script errors for Hindi. Turbo kept the Hindi script and most words, with spelling/recognition errors still present. Turbo is therefore the default recommendation; Base remains available for smaller downloads and lower resource use.

These measurements use three short system-generated clips, not a representative microphone/accents/noise corpus. They do not establish production transcription accuracy. An initial cold Base invocation returned invalid/empty text. Empty local decoding now permits one bounded retry before any provider request or paste; repeated hallucination output remains rejected. Cancellation also uses an explicit thread-safe gate because WhisperKit invokes progress callbacks in detached tasks.

The recorded synthetic outputs and timings are in [`speech-benchmark-2026-11-05.json`](testing/speech-benchmark-2026-11-05.json). Reproduce the check with:

```bash
python3 docs/testing/run_speech_benchmark.py --output /tmp/heynotch-speech-results.json
```

The script downloads pinned models, verifies hashes, builds the actual local speech engine, and generates audio using installed macOS voices. It does not record the microphone or send audio/transcripts to a provider. Its cache is reusable; first-time downloads total about 800 MB.

## Provider contracts and boundaries

- Claude uses the current Messages/Models contracts, the configured workspace context where required, and an exact selected model ID. [Claude API overview](https://platform.claude.com/docs/en/api/overview), [models listing](https://platform.claude.com/docs/en/api/models/list).
- OpenAI uses Responses with `store: false`, a non-streaming final result, and typed output parsing. A catalogue entry alone is not treated as proof of Responses support. [Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses).
- OpenRouter checks its key endpoint separately from the account-filtered model catalogue. Generation uses the selected namespaced model; known automatic-router aliases are excluded. Structured requests require compatible parameters. [Key information](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key), [structured output](https://openrouter.ai/docs/guides/features/structured-outputs).

Keys are kept in Keychain, not preferences. Requests reject redirects, bound response size, and honor cancellation/deadlines. Generation is never automatically retried. A user choosing Retry cleanup explicitly starts another request and may incur another charge. That does not retry a paste whose outcome is uncertain.

## Remaining release acceptance checks

These remain open rather than being labelled passed:

- **Live paid requests for each provider:** no provider credentials were configured. Fixtures validate the contracts and error paths; a real selected model must still pass discovery and inference in each account before the integrations are release-certified.
- **Microphone hardware matrix:** actual recording with built-in microphones/AirPods, input removal, sleep/wake while recording, and missing key-up timing under normal user interaction. Model tests used generated audio and did not grant new microphone access.
- **Full insertion application matrix:** TextEdit is verified. Browser editors, Notes, Slack, Xcode, protected fields, and slow-paste applications still need broader runtime coverage. Automated tests cover the state/clipboard refusal and recovery paths.
- **Cross-device iCloud delivery and notification delivery:** the selected writable iCloud list was exercised locally. No second device or notification delivery was verified.
- **macOS 14 runtime and Intel hardware:** universal compilation passed; hardware/runtime checks remain required. The inherited Now Playing adapter still requires macOS 15 or later.
- **Public distribution:** notarization, update signing/feed enablement, release CI execution, and public publishing remain later roadmap work. The locally signed development build is not a notarized release.

Date-only reminders never silently receive a time/alarm. English scheduling expressions are parsed deterministically; unfamiliar expressions can be edited manually or sent to explicitly enabled AI assistance, whose suggestions always require review. Recurrence creation is deliberately reviewed rather than silently reduced to a one-off reminder.

Clipboard restoration waits one second and is a heuristic, not proof that every application consumed the paste. Promised/lazy data and clipboard snapshots over 16 MB are refused when restoration is requested. Users can disable restoration or use explicit Copy. Semantic cleanup checks are conservative and cannot prove that an AI rewrite preserves every nuance; the original transcript remains available.
