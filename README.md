# HeyNotch

HeyNotch is a personal macOS notch app: voice dictation, tasks and your notch in one place.

> [!NOTE]
> HeyNotch is a fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) by **TheBoredTeam**, developed independently.
> It is **not** affiliated with or endorsed by the Boring Notch team. Changes here are **never** sent upstream as pull requests.

## What it does today

Everything inherited from Boring Notch:

- Now Playing controls with a music visualizer
- Calendar and Reminders in the notch
- File shelf with AirDrop
- Battery and charging indicator
- Mirror (camera preview)
- System HUD replacement (volume, brightness, keyboard backlight)

## Planned

- [ ] Push-to-talk voice dictation with local Whisper, shown in the notch
- [ ] Spoken items sorted into tasks, notes or plain typing
- [ ] Task list in the notch, synced with Apple Reminders

## Requirements

- macOS 14 Sonoma or later (building needs macOS 15.6+ and Xcode 26+)
- Apple Silicon recommended

## Build from source

```bash
git clone https://github.com/WOLFIEEEE/boring.notch---Personalizaton.git
cd boring.notch---Personalizaton
open HeyNotch.xcodeproj
```

Select the **HeyNotch** scheme and press `Cmd + R`.

Command-line build without signing:

```bash
xcodebuild -project HeyNotch.xcodeproj -scheme HeyNotch -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Updates

Automatic update checks are off. The update feed points at this fork, not the original project, so HeyNotch never installs Boring Notch releases over itself.

## Contributing

This is a personal project. **Do not open pull requests to `TheBoredTeam/boring.notch` from this repo.** See [CLAUDE.md](CLAUDE.md) for the rules and guardrails.

## License and credits

HeyNotch is licensed under **GPL-3.0**, the same license as Boring Notch. See [LICENSE](LICENSE). Any distributed version must stay GPL-3.0 and include its source.

- Original project: [Boring Notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam and contributors
- [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter): Now Playing support on macOS 15.4+
- [NotchDrop](https://github.com/Lakr233/NotchDrop): basis of the original Shelf feature
- Third-party licenses: [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)
