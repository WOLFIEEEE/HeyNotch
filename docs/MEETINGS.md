# Meeting reminders and local transcription

Implemented locally on 5 November 2026, as an extension to Phases 1–5. The user chose **both sides of the call**. No commits, pushes, public releases, or upstream actions were performed.

## User flow

1. HeyNotch checks microphone and camera activity every two seconds while suggestions are enabled. It does not open either device to make this check.
2. Six seconds of sustained activity can produce **Transcribe this call?**. A known microphone app is named; camera-only activity is described without claiming to know its owner. Device activity is a possible call, not proof of a meeting.
3. **Transcribe…** opens a dedicated meeting window. Nothing records merely because a call was detected or the reminder was opened. **Not now** dismisses the current activity session; **Snooze 1 hour** pauses suggestions.
4. The window defaults to **My microphone and call audio**. The user can select their microphone and the call app, prepare the local model, then choose **Start transcription**. A microphone-only option is also available.
5. The window displays elapsed time, recording state, queued audio sections, and timestamped text. **Stop transcription**, closing the window, sleep, locking the Mac, the selected call app exiting, capture failure, or the two-hour limit stop recording. Already queued audio finishes where possible.
6. **Copy all** and **Save all…** export the full transcript, independent of search and source filters. Save supports plain text and Markdown. Passage menus copy text with or without source/timestamp and open a reviewed task draft. **New session…** requires confirmation before clearing current text. By default transcripts remain in memory until cleared or quit; optional local history saves text as sections finish, with 30-day/50-session limits. See [Meeting Library](MEETING_LIBRARY.md). Meeting text never goes through automatic cross-app insertion or cloud cleanup.

Settings → Meetings contains automatic reminders, camera suggestions, preview, snooze/resume, microphone app exclusions, optional macOS notifications, and opt-in transcript history. The menu exposes Meeting Transcription, Meeting Library, Stop, and a recording icon. Command–Shift–M opens the recording window; Command–Shift–L opens the library; Command–Period stops capture from the recording window; Command–S saves plain text; Command–F focuses transcript search.

## Detection and reminder policy

- Microphone attribution uses CoreAudio process objects and `kAudioProcessPropertyIsRunningInput`, not output activity on a duplex device. This avoids treating music playback alone as microphone use. The process API is guarded to macOS 14.2+. On 14.0–14.1, camera suggestions and manual transcription remain available. [Apple CoreAudio input-activity API](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunninginput).
- Camera detection uses `AVCaptureDevice.isInUseByAnotherApplication`; it creates no camera capture session and requests no camera permission. HeyNotch’s Mirror activity is excluded. The API does not identify the other app, so camera-only suggestions cannot honor an app-specific exclusion. [Apple camera activity property](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isinusebyanotherapplication).
- HeyNotch’s process, known system speech services, Voice Memos, and user-excluded microphone apps are ignored. Chromium/helper bundle identifiers are matched back to their running parent app when possible.
- Input/camera/app switches share one activity session. Two minutes of no activity reset the session; a 15-minute cooldown limits repeated reminders. This is a heuristic, not reliable call-start/call-end detection. A brief quiet gap before the initial six-second delay resets that delay.
- Dictation defers suggestions. Meeting capture consumes the current suggestion. Lock/sleep suppress monitoring until the corresponding unlock/wake events. Snooze expires after an hour even if activity continues.
- Reminders expire after 35 seconds; stale notification actions cannot start or navigate a later session. The nonactivating in-app panel works without notification permission. Opting into macOS notifications uses alert-only authorization and follows the system’s Focus behavior; the in-app panel itself does not integrate with Focus.

No calendar events, window titles, browser pages, call contents, or camera images are inspected for detection. Activity state is transient. Only explicit preferences and excluded app identifiers are persisted.

## Both audio channels

Microphone capture uses the selected input through AVAudioEngine. Call audio uses ScreenCaptureKit with **only an audio output registered**. No screen frames are delivered or stored. The stream requests mono Float32 at 16 kHz, a rate supported by ScreenCaptureKit. [Apple audio-capture configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio), [supported sample rates](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate).

An identified call app is preselected from the reminder. The user can change it. The app filter captures that app’s audio; if the app is unavailable, starting fails visibly instead of silently switching to all audio. **All system audio** is explicitly labeled as including other apps and notification sounds. Capturing a browser includes that browser’s other tabs. The current HeyNotch process is excluded from system capture.

Microphone and Screen & System Audio Recording permissions are requested only from the explicit Start flow. A missing grant prevents the session from starting; error text points to System Settings. Microphone access approved for the earlier dictation feature does not itself grant system-audio capture access.

Audio is drained about every 20 seconds with a one-second overlap and transcribed through the existing pinned local WhisperKit model. The two streams are labeled **Microphone** and **Call audio**; these are source labels, not speaker diarization. Timestamps represent approximate section starts, not word-level timing. Headphones reduce playback leaking into the microphone; this implementation does not promise echo cancellation.

High-rate microphone audio is downsampled before entering the bounded queue. A growing queue stops recording rather than growing without limit; remaining queued audio finishes. Buffer overflow, a changed PCM layout, nonfinite samples, device changes, and failed decoding are surfaced. Failed decoding adds a visible gap instead of fabricated text. Low-memory handling can discard unfinished audio with a visible gap. Context removal is limited to a short exact textual overlap when the audio at the shared boundary actually contains speech; it never deletes an entire new section.

Dictation and meetings share an explicit model-use reservation. Model unloading, deletion, preparation, and a second recording are blocked during use. Cancellation reaches WhisperKit’s detached decode callbacks through the existing cancellation gate. Starting a meeting does not enable dictation or cloud processing.

## Verification and remaining acceptance checks

Verified locally:

- **104 Swift tests** pass, including 21 added checks for reminder debounce, cooldown, snooze, busy/disabled behavior, preview dismissal, PCM capture decoding, format changes, nonfinite samples, buffer limits, overlap, Unicode export, and explicit gaps.
- The signed development app displays Meetings settings, the reminder preview, both audio-source choices, and the transcript window. Clicking Transcribe opens the window without recording. Preparing the already installed model enables Start. Snooze displays its expiry; Resume restores suggestions.
- The synthetic two-channel check uses the app’s actual bounded audio buffer, local speech engine, overlap handling, and export. Both generated 50-second tracks transcribed across three chunks each. Six decode calls took **3.61 seconds total** on the M3 Pro in the recorded run; repeated sentences, the negation “do not send,” the amount, and the scheduled time were retained. This is a synthetic throughput check, not a real-meeting accuracy claim.
- **42 repository Python tests pass.** Signed Debug and universal Release builds pass; the Release binary contains both `arm64` and `x86_64`. New feature code produces no compiler warnings; inherited concurrency warnings remain elsewhere. The preceding Phase 1–5 checks remain recorded in [PHASES_1_5.md](PHASES_1_5.md).

Reproduce the synthetic check after preparing the pinned cache with `run_speech_benchmark.py`:

```sh
python3 docs/testing/run_meeting_benchmark.py --cache /tmp/heynotch-speech-check --output /tmp/meeting-check.json
```

The result is recorded in [meeting-benchmark-2026-11-05.json](testing/meeting-benchmark-2026-11-05.json). It contains generated speech only and a deliberately fixed synthetic export date.

Still required before claiming live-call or release certification:

- Grant microphone/system-audio access in the installed signed app and exercise both streams in real Zoom, Teams, Meet/browser, and FaceTime calls. No live call was recorded during this build session; new recording permissions were not granted by the agent.
- Verify real CoreAudio attribution and camera activity across supported hardware, browser helpers, external cameras, AirPods, Bluetooth mode changes, and macOS 14.2/15/27. No claim that every possible meeting app is detected.
- Exercise native notification delivery/actions with Focus enabled and disabled, permission denial/revocation, and fresh installation. The in-app reminder was visually checked; system-notification permission was left unchanged.
- Run a long conversation with overlapping speakers, accented/multilingual speech, mute/unmute, call-app restart, device removal, lock/sleep/wake, and sustained decoder backlog. Verify chronology, boundaries, visible gaps, stop/cancellation, and memory behavior.
- Evaluate echo, silence hallucinations, and repeated phrases on real audio; source labels must never be presented as identified people. Sessions stop at two hours. Optional local history saves completed text sections only; unfinished audio cannot be recovered after a crash.


## Production-hardening pass — 5 November 2026

The next verification pass adds seven audio reliability tests and five notification
transport tests, bringing the integrated suite to **116 passing Swift tests**.
The capture implementation now uses the monotonic host clock, preserves missing
packet gaps, retains valid microphone audio after device failure, and drains
channels independently. The pending queue has explicit chunk and audio-duration
budgets. Startup failures distinguish permission denial from capture/signing errors.
The recording window exposes separate audio-received indicators and level meters.

Notification Preview now uses the selected native/in-app delivery path. Tests
cover disabled/denied notifications, failed submissions, dismissal during delivery,
and an old delayed request without removing a newer notification. These fixtures
verify application behavior, not system banner presentation under Focus.

Quitting with active capture or an unsaved transcript now offers Review Transcript,
Quit and Discard, or Cancel. Saving only marks the exact exported session/segment
snapshot as saved. New text arriving during export stays unsaved. A launch guard
prevents duplicate copies from both monitoring/recording; Restart targets the exact
running app bundle instead of an older installed copy.

A real attempt to start capture reached the recording-access step. Access to the
macOS permission dialog was blocked by the computer-control tool, and the owner
was asked to approve microphone/system-audio access directly. Capture was not
certified. Two development copies (Phase 1 and Phase 5) were found running and
stopped to avoid ambiguous permission/notification ownership.

The localhost [WebRTC fixture](testing/live-call/README.md) sends generated speech
between browser peers without browser microphone/camera access or external servers.
It provides independent RTP counters and receiver audio energy. This is useful for
checking system-audio capture, but speaker leakage into a physical microphone must
not be reported as proof of independent two-sided recording.

For distribution gates, see [RELEASE_READINESS.md](RELEASE_READINESS.md) and
`scripts/release-candidate.sh`. Developer ID signing and Apple notarization are
separate from passing capture tests. A candidate archive is not a production sign-off.
