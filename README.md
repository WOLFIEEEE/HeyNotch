# HeyNotch

<p>
  <img src="design/brand/heynotch-app-icon-v1.png" alt="HeyNotch app icon — blue notch-shaped H on a light rounded tile" width="128" height="128">
</p>

HeyNotch is a personal macOS notch app: voice dictation, tasks and your notch in one place.

> [!NOTE]
> HeyNotch is a fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) by **TheBoredTeam**, developed independently.
> It is **not** affiliated with or endorsed by the Boring Notch team. Changes here are **never** sent upstream as pull requests.

## What it does today

The locally implemented voice and task features:

- Push-to-talk and toggle dictation using pinned, local WhisperKit models
- Processing settings for Claude, OpenAI, and OpenRouter, with Keychain credentials and exact model selection
- Optional Light/Formal cleanup with cancellation and original-transcript recovery
- Cross-app insertion through the signed helper, with clipboard restoration and focus checks
- A customizable hover page with Tasks first, an adaptive-height kanban board, and scroll-safe task columns
- A Tasks editor backed by Apple Reminders, including undated tasks, date review, editing, completion, and Undo
- Automatic call-transcription reminders from microphone/camera activity, with local microphone + call-audio transcription, snooze, app selection, and transcript export

The inherited notch features remain available:

- Now Playing controls with a music visualizer
- Calendar and Reminders in the notch
- File shelf with AirDrop
- Battery and charging indicator
- Mirror (camera preview)
- System HUD replacement (volume, brightness, keyboard backlight)

## Getting started

**HeyNotch 2.8.0 Preview 1 is available.** [Download the notarized app ZIP](https://github.com/WOLFIEEEE/HeyNotch/releases/download/v2.8.0-preview.1/HeyNotch-2.8.0-272-notarized.zip), or view the [release and corresponding source](https://github.com/WOLFIEEEE/HeyNotch/releases/tag/v2.8.0-preview.1). Read the [installation and first-run guide](docs/INSTALL.md) for requirements, normal macOS security checks, setup, and preview limitations. Developer builds and a local `CANDIDATE.zip` are not a notarized public download.

The release provides the notarized app ZIP and **`HeyNotch-2.8.0-272-source.tar.gz`** as separate downloads on the same release page. The app ZIP includes license notices, `SOURCE_STATE.json`, and a direct link to its matching source archive; the source is not nested inside the app ZIP.

Open **Settings → Voice**, enable voice input, allow microphone access, and download/prepare a speech model. Compressed Turbo is the recommended multilingual option (about 648 MB); Base is a smaller option (about 149 MB). First preparation can take several minutes. Wait for **Ready**, then focus a text field in another app. Text insertion also needs Accessibility access.

| Action | Default shortcut |
|---|---|
| Hold to dictate | Control–Option–Command–D |
| Start/finish dictation | Control–Option–Space |
| Start/finish a voice task | Control–Option–Command–T |
| Cancel recording/processing | Escape, or the visible Cancel button |

Shortcuts are configurable in Voice settings. Dictation recordings are limited to two minutes. The last dictation transcript stays in memory for recovery until another recording or app quit.

AI processing starts off. To enable it, open **Settings → Processing**, choose a provider, save that provider’s API key, verify it, and choose an exact model from the searchable catalogue or enter its ID. **Test model** makes a small paid API request. Provider/model settings are remembered separately for each provider. Audio stays local; optional processing sends the transcript directly to the selected provider.

For tasks, choose a writable list in **Settings → Tasks**. The notch opens to Tasks by default. Its **To do / Doing / Done** board supports drag/drop and per-card movement menus, separate scrolling in each column, due-date badges, and quick add/voice/edit actions. Doing is remembered on this Mac; Done uses Reminders completion. The full Tasks window retains its date-grouped list. Voice tasks always require review before saving. Choose an iCloud list if you want Reminders to sync through your Apple Account.

In **Settings → General → Notch behavior**, choose the **Page shown on hover**: Tasks, Music & Calendar, Shelf, or Last used page. Set the maximum task-board height; the notch grows with its contents up to that limit and the available screen space. Scroll inside task columns normally. Swipe-to-close is confined to the header, which also has an explicit close button. See [notch customization and kanban behavior](docs/NOTCH_TASKS.md).

The [measured optimization report](docs/OPTIMIZATION.md) documents task-board caching, animation timer cleanup, reduced wheel-event task creation, and idle UI update checks, with reproducible benchmarks and their limits.

For calls, **Settings → Meetings** controls automatic reminders. HeyNotch notices microphone/camera activity and offers **Transcribe…**; it never starts recording automatically. The meeting window defaults to both your microphone and the call audio. Select the call app, prepare the model, and choose **Start transcription**. It requests microphone and system-audio access when needed. Text stays local in its own window; sessions stop after two hours or when the window closes. Search the transcript, filter by audio channel, copy individual passages, or export the full transcript as plain text or Markdown. **Create task…** opens a passage for review before anything is saved to Reminders.

Optional **Keep meeting transcripts on this Mac** is off by default. It saves text as sections finish, with a 30-day retention limit and a maximum of 50 sessions. **Meeting Library…** (Command–Shift–L) lets you search, rename, export, and delete saved sessions, including partial transcripts recovered after an interruption. No raw audio is stored. See [library behavior](docs/MEETING_LIBRARY.md) and [meeting verification](docs/MEETINGS.md), including the live-call checks still open.

Implementation and actual validation are recorded in [Phases 1–5](docs/PHASES_1_5.md). Live provider checks still need configured credentials, and the broader microphone/application/device matrix is not yet release-certified. The [detailed roadmap](docs/ROADMAP.md) retains those acceptance gates. Optional Smart mode remains later work. Distribution preparation and its remaining acceptance gates are recorded in [release readiness](docs/RELEASE_READINESS.md).

## Requirements

- The project targets macOS 14 Sonoma or later. Full runtime validation on macOS 14 is still pending.
- The bundled universal Now Playing adapter requires macOS 15 or later. On macOS 14, use the direct Apple Music, Spotify, or YouTube Music options.
- Xcode 26.6 is the tested build toolchain; CI uses it on `macos-26`. The locked Swift packages require a modern Swift toolchain, so the former Xcode 16 build configuration is unsupported.
- Apple Silicon recommended

## Build from source

```bash
git clone https://github.com/WOLFIEEEE/HeyNotch.git
cd HeyNotch
open HeyNotch.xcodeproj
```

Select the **HeyNotch** scheme and press `Cmd + R`.

Command-line build without signing, using the checked-in package versions:

```bash
xcodebuild build -project HeyNotch.xcodeproj -scheme HeyNotch \
  -configuration Debug -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

To run the focused app logic tests and repository checks:

```bash
xcodebuild test -project HeyNotch.xcodeproj -scheme HeyNotch \
  -configuration Debug -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
python3 -B -m unittest discover -s .github/scripts/tests -v
```

The tests run without launching the menu-bar app or requesting device permissions. An unsigned build verifies compilation and logic; it does not verify Accessibility permissions, cross-app insertion, or a distributable signed release.

The **Build and test** GitHub Actions workflow runs these checks, builds the Release configuration, and saves an unsigned development app. It also supports manual runs from the Actions page. Inherited publishing and sync workflows are [archived and disabled](.github/disabled-workflows/README.md).

## Updates

Automatic updates and Sparkle update checks remain disabled, independently of saved Sparkle preferences. **Settings → About → Download updates** opens [HeyNotch releases](https://github.com/WOLFIEEEE/HeyNotch/releases). Install published previews manually using the [installation guide](docs/INSTALL.md). The inherited signing key and release entries have been removed.

Enabling automatic updates later requires an explicit build setting, this fork's validated signing key, the approved HeyNotch feed, and a tested signed update flow. The update-policy tests enforce the destination and configuration requirements.

## Contributing

This is a personal project. **Do not open pull requests to `TheBoredTeam/boring.notch` from this repo.** See [CLAUDE.md](CLAUDE.md) for the rules and guardrails.

## License and credits

HeyNotch is licensed under **GPL-3.0**, the same license as Boring Notch. See [LICENSE](LICENSE). Any distributed version must stay GPL-3.0 with its corresponding source available. HeyNotch releases provide the exact corresponding-source archive alongside the app ZIP on the same release page, with a direct source link and license notices in the app download.

- Original project: [Boring Notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam and contributors
- [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter): universal Now Playing support; the bundled binary requires macOS 15+
- [NotchDrop](https://github.com/Lakr233/NotchDrop): basis of the original Shelf feature
- Third-party licenses: [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)
- HeyNotch logo artwork: [brand assets and generation record](design/brand/README.md)

### Control tasks from Codex and Claude

HeyNotch includes a native local MCP connector for scoped task lookup, creation,
edits, kanban moves, and completion. Set up individual connections under
**Settings → Agent access** and choose which Reminders lists each client can use.
Access is off by default and can be revoked at any time.

See [task automation](docs/MCP_AUTOMATION.md) and
[client setup](docs/MCP_CLIENT_SETUP.md) for setup, retry recovery, and verification limits.
