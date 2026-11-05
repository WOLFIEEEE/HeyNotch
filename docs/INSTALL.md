# Install HeyNotch Preview

This guide applies to **HeyNotch 2.8.2 Preview 3**, app version **2.8.2 (274)**. Use the notarized ZIP attached to its published release in **WOLFIEEEE/HeyNotch**. A local file named `HeyNotch-CANDIDATE.zip` has not passed the distribution gate and is not a public installer.

## Requirements

- macOS 14 or later; Apple Silicon is recommended. The executable is universal, but Intel and macOS 14 runtime acceptance are still incomplete.
- Internet access for the first local speech-model download. Optional provider processing also needs your provider account, API key, and credit.
- Microphone activity attribution requires macOS 14.2+. The bundled Now Playing adapter requires macOS 15; direct Apple Music, Spotify, and YouTube Music integrations are available on macOS 14.

## Install

1. Download the notarized ZIP from the matching HeyNotch preview release. Keep the normal browser download/security attributes intact.
2. Open the ZIP and move **HeyNotch.app** from the HeyNotch folder into **Applications**. Keep the included license notices and `READ-ME.txt`; the latter links to the exact corresponding-source download for this release.
3. Quit any older HeyNotch copy, then open the copy in Applications. macOS may ask you to confirm opening an app downloaded from the internet. The signing developer is **Khushwant Parihar**.
4. If macOS says the app is damaged, has an unidentified developer, or cannot be verified, stop and check that the download came from the matching fork release. Do not disable Gatekeeper or remove quarantine as an installation step.

There is no privileged installer, separate helper installation, or automatic updater. The signed MCP helper is inside the app bundle. Keep the app in Applications so permissions and MCP client paths remain stable.

The corresponding source is a separate release asset, **`HeyNotch-2.8.2-274-source.tar.gz`**, alongside the app ZIP on the same release page. It is not nested inside the app ZIP and is not needed to run the app. Download it to inspect or build the exact source identified by the included `SOURCE_STATE.json`.

## First use

- **Tasks:** open Settings → Tasks, allow Reminders access when prompted, and choose a writable list.
- **Voice:** open Settings → Voice, enable voice input, choose and prepare a local model, then allow microphone access when requested. Text insertion into other apps also needs Accessibility access. Wait for the model to show Ready.
- **Optional AI processing:** open Settings → Processing, choose Claude, OpenAI, or OpenRouter, save your own key, then select the model. Testing or processing with a provider may incur account charges. Local dictation does not require a provider key.
- **Meetings:** configure reminders under Settings → Meetings. A suggestion does not start recording. Choose the microphone and call app in Meeting Transcription and press Start; macOS then requests microphone and system-audio recording access as needed. Browser capture can include other tabs in that browser.
- **Agent access:** enable it only if wanted, select allowed lists and optional writes for each client, then export its connection file. That file is a credential: keep it private and revoke the client if it is exposed. The accompanying source archive contains the full guide at `docs/MCP_CLIENT_SETUP.md`.

Permission names and prompts can vary by macOS version. Review them in System Settings → Privacy & Security. Restart the installed app if macOS requests it after a permission change.

## Preview limitations and updates

Real-call capture across call apps/devices, native notification/Focus delivery, live provider-account requests, and broader insertion/hardware cases remain acceptance work. Do not rely on an untested recording as your only record of an important conversation. The accompanying release notes and `docs/RELEASE_READINESS.md` in the source archive distinguish implemented behavior from verified cases.

Automatic updates are disabled. To update, stop recording, save any needed transcript, quit HeyNotch, replace the app in Applications with a later verified release, and reopen it. To remove the app, first stop recording and quit; revoke unused agent connections, then move HeyNotch.app to Trash. Removing the app does not automatically remove saved preferences, Keychain entries, downloaded models, or optional transcript history.

## Optional file verification

`SHA256SUMS.txt` accompanies the release assets and covers both the app ZIP and the separate source archive. Verify it from the folder containing all listed files with `shasum -a 256 -c SHA256SUMS.txt`. This checks download integrity; macOS Developer ID and notarization checks still apply. The separate source snapshot, matching `SOURCE_STATE.json`, and license notices describe exactly what was built.
