# Phase 0: fork foundation

Updated: 5 November 2026
Branch: `codex/phase-0-foundation`
Status: implementation and local checks complete; GitHub execution and older-system runtime checks pending.

This milestone establishes the baseline for the [development roadmap](ROADMAP.md). It does not implement voice dictation, Processing settings, or task creation.

## Changes

- The active **Build and test** workflow runs repository checks, Swift logic tests, and an unsigned Release build. It supports push, pull request, and manual runs. Both it and CodeQL are restricted to `WOLFIEEEE/HeyNotch` and use Xcode 26.6 for Swift builds. Package versions remain unchanged.
- Eight inherited release, nightly, Pages, Crowdin, branch-policy, and reusable/manual build workflows are archived outside `.github/workflows`. They cannot execute there. The archive contains the old Homebrew destination and must not be restored directly. Funding and Crowdin configuration for the original project has been removed.
- Sparkle does not start unless the bundle explicitly enables HeyNotch updates, uses the approved fork feed, and contains a correctly formed signing public key. Manual checks also enforce that policy. Saved Sparkle preferences cannot enable a disabled build. Settings displays an explanation while updates are unavailable.
- The inherited update public key and all historical appcast releases have been removed. The remaining empty feed identifies HeyNotch. Future release work must establish key ownership, signed assets, and feed validation before enabling updates; format checks alone cannot establish ownership.
- Calendar and Reminders now have the full-access usage descriptions required by the EventKit methods already in use, in both build configurations.
- The onboarding footer uses HeyNotch wording. Original attribution in About, copyright notices, `LICENSE`, `THIRD_PARTY_LICENSES`, and the upstream guardrails are preserved. `TipStore` was inspected and retained because it provides in-app TipKit guidance.
- A shared Xcode scheme includes a hostless `HeyNotchTests` target. The initial tests exercise update configuration and feed restrictions without launching the app or requesting system permissions. The same policy source is compiled into the app and tests.
- The existing contradictory app-name assertion is corrected. The archived release-script tests remain, alongside checks that enabled workflows cannot inherit publication settings and development builds cannot enable updates.

## Local verification

Environment: Xcode 26.6 (`17F113`), macOS 27.0.1, Apple Silicon. Builds used the existing package cache and locked versions with automatic resolution and package updates disabled.

| Check | Result |
|---|---|
| Debug build and Swift tests | Passed; 6 tests, 0 failures. |
| Unsigned Release build | Passed. |
| Python repository suite | Passed; 42 tests, 0 failures, including the previously failing rename assertion. |
| Generated Debug and Release plists | Both contain full-access Calendar/Reminders descriptions; updates remain disabled and the inherited public key is absent. |
| App linkage | Debug executable/debug library and Release executable do not link MediaRemoteAdapter; the framework remains embedded for supported systems. |
| Enabled workflow configuration | Only Build and test and CodeQL remain. YAML parses successfully; repository checks find no upstream destination or publication write permission. |
| GitHub-hosted execution | Pending the first run of the revised workflows. Local success is not recorded as a CI run. |
| macOS 14 and cross-app behaviour | Not verified on a macOS 14 machine. Insertion is a separate Phase 1 milestone. |

Reproduction commands are in the [README](../README.md). The first package download is required on a fresh machine; later local runs may add `-disableAutomaticPackageResolution -skipPackageUpdates` when the locked packages are already cached.

## Compatibility audit

The project retains a macOS 14 deployment target. Inspection of the bundled Mach-O load commands found that both MediaRemoteAdapter and its test client require macOS 15. Previously, the app linked the adapter directly, creating a launch-time dependency despite advertising macOS 14 support.

The app now embeds the adapter without linking it, and both the compatibility probe and Now Playing controller are guarded for macOS 15. The existing media-controller selection falls back to Apple Music when universal Now Playing is unavailable; users can also select the direct Spotify or YouTube Music integrations. The bundled Sparkle and Lottie binaries advertise deployment targets compatible with macOS 14.

This addresses the identified binary dependency; it does not establish complete macOS 14 support. The inherited Spaces integration uses private CGS symbols. Now Playing uses private MediaRemote symbols, while the helper dynamically checks CoreBrightness and DisplayServices before using available brightness functions. Their actual behaviour still needs testing on supported OS versions, including display, Spaces, music, and brightness flows. Private API stability is not guaranteed by a successful build.

## Existing compiler warnings

The original Debug baseline contained 13 distinct concurrency warning messages, with repeated occurrences. They include:

- `XPCHelperClient` and `AsyncXPCConnection` values captured across concurrency boundaries without `Sendable` conformance.
- Spotify and YouTube Music controller captures in asynchronous callbacks.
- Shelf selection, column/cache updates, directory state, and `NSItemProvider` work crossing actor boundaries.

These predate this milestone. The project remains in Swift 5 language mode with targeted concurrency checking; some warnings become errors in Swift 6 mode. Address the affected boundaries as their code changes, starting with the helper/client work in Phase 1. Do not hide the warnings with broad unchecked conformance or an unrelated concurrency rewrite.

## Remaining acceptance work

1. Run the revised Build and test and CodeQL workflows in the personal fork and inspect their results.
2. Verify app launch, settings, EventKit permission requests, music fallbacks, Spaces, and brightness on macOS 14 and a supported newer system. Both permission prompts and signed helper behaviour require runtime checks.
3. Continue with the fixed-text insertion proof in Phase 1, then the three-provider Processing pane in Phase 2. Keep all new features disabled until their readiness checks pass.

No release has been signed, published, or enabled by this milestone.
