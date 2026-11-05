# HeyNotch release readiness

Audit date: 6 November 2026. Scope: the independent `WOLFIEEEE/HeyNotch` fork. This record separates a working development build, a distribution candidate, and product acceptance. It is not a production approval.

## Preview 3 UX candidate — 2.8.2 (274)

The thirteen confirmed UX audit findings are fixed in this candidate: unsaved task draft protection, truthful save cancellation, obsolete Undo cleanup, current list summaries, persistent compact navigation, shared automatic-close protection, exact Shelf copy/share payloads, concurrent Shelf cleanup, processing cancellation and status, voice retry availability, and installed-model disk budgeting. See [fix details and regression mapping](UX_FIXES.md) and [Preview 3 notes](releases/2.8.2-preview.3.md).

The complete integrated app suite passed **323 tests, with zero failures and zero skips**, including the actual stdio MCP/loopback integration test and **48 new regressions**. The repository/release suite passed **48 checks**. The website download update passed **9 existing motion tests** and static checks for **65 links/assets**; no animation or styling changes were made to the website.

The first integrated build identified an incorrect source group for the navigation policy; it was moved out of the XPC-shared group into Tasks Core. The first successful suite skipped the existing MCP connector fixture; building that fixture and rerunning the suite produced the complete result above. Private clipboard tests preserve native NSURL file writers and verify real temporary-file URL/content readback. Their isolated process still logs sandbox-extension consumption diagnostics; passing fixture reads are not a cross-app sandbox acceptance claim.

At the source snapshot stage, Developer ID packaging, Apple notarization and public download verification are still distribution steps. Completed distribution evidence will be recorded in the publication record after the exact final assets are verified. New installed-app cursor/menu/popover/drag sessions, cross-app paste/share, frame-rate measurements, live calls, native notifications, paid provider requests and wider device/macOS acceptance are not claimed. Automatic updates remain disabled; this remains a preview.

## Published Preview 2 — 2.8.1 (273)

The published bugfix prerelease is **[v2.8.1-preview.2](https://github.com/WOLFIEEEE/HeyNotch/releases/tag/v2.8.1-preview.2)**, with app/XPC version **2.8.1 (273)**. It addresses the reported notch opening far from its visible area and unstable open/close motion. The closed interaction area is bounded to the visible notch; delayed hover/drag opens recheck the current pointer; the hosting window keeps stable bounds while the visible notch changes size; motion uses one animation owner, direct gesture tracking, and Reduce Motion behavior. Only the selected tab supplies the moving highlight’s matched-geometry source. See [Preview 2 notes](releases/2.8.1-preview.2.md).

The integrated app suite passed **275 tests with no failures or skips**, the repository/release suite passed **48 checks**, and native visualizer checks covered **44 assertions** plus existing lifecycle checks. Apple accepted the exact source commit `de09e40ef7de2a52b21c747b3e6fc49569fa7d21` as submission `22d3f427-2e2d-4b30-bcb1-9ebfd8507e38`. The final app is stapled and Gatekeeper accepts it as Notarized Developer ID. All six public release assets were downloaded anonymously and matched the verified originals. The downloaded app passed all 11 Mach-O / 22 architecture signature checks, and its bundled MCP helper passed initialization, nine-tool discovery and ping. App ZIP SHA-256: `ffef31e62a723221f5c0163027e7734ce25994e73039faab229ada78b38a013b`.

A new interactive browser-to-Applications install, live cursor/file-drag behavior, WindowServer click-through, and measured frame rate were not validated in this session. Preview 1’s interactive acceptance does not carry over as a new pass. [Remote CI for the release source](https://github.com/WOLFIEEEE/HeyNotch/actions/runs/42076992959) is a separate result; at publication its repository checks passed and its macOS job was queued for a runner. Automatic updates remain disabled, and the existing live-call, notification/Focus, provider, device, and macOS/Intel preview limits remain open. See the [motion-fix verification report](NOTCH_MOTION_FIX.md).

## Published preview — 5 November 2026

**[HeyNotch 2.8.0 Preview 1](https://github.com/WOLFIEEEE/HeyNotch/releases/tag/v2.8.0-preview.1) is publicly available**, with app/XPC version **2.8.0 (272)**. The release includes the [notarized app ZIP](https://github.com/WOLFIEEEE/HeyNotch/releases/download/v2.8.0-preview.1/HeyNotch-2.8.0-272-notarized.zip), exact corresponding-source archive, installation instructions, release notes, source manifest, and checksums. The release tag identifies source commit `e5b5607b2b163b92c632ae02fa6316696e5c96da`.

Apple accepted the final submission `9f33d460-80d4-419d-92bb-43b155a79bbc`. The [release commit's CI run](https://github.com/WOLFIEEEE/HeyNotch/actions/runs/42032126783) passed **254 tests with zero failures and no skipped tests**, including the real MCP loopback/stdio integration test, and built the Release configuration successfully. Automatic updates remain disabled; Settings links to releases for manual downloads.

This remains a preview. Real-call capture, native notification/Focus delivery, live provider requests, macOS 14/Intel runtime coverage, and the broader permission/device matrix still need acceptance work. The historical preparation and initial audit records below describe earlier builds, not current public download availability; publication does not close those remaining product gates.

## Historical 2.8.0 Preview 1 distribution preparation

The intended first HeyNotch prerelease is **v2.8.0-preview.1**, with numeric app/XPC version **2.8.0 (272)**. This advances the inherited 2.7.3 (271) identity while keeping preview status explicit on GitHub. Automatic updates remain disabled. See [release notes](releases/2.8.0-preview.1.md), [installation](INSTALL.md), and [publishing procedure](PUBLISHING.md).

On 5 November, the last examined candidate before this version change was a 19,879,529-byte universal Developer ID ZIP with the new logo and MCP helper. All 371 source-snapshot entries matched that checkout, the source/license files were included, and the app/XPC/MCP executable signatures had secure timestamps and no debugging entitlement. It had **no stapled ticket** and no saved Apple notarization result. The version change and release-workflow changes require a fresh candidate. Read the latest `build/verification/` evidence before asserting that a later build, notarization, or downloaded installation passed.

At the start of this audit, a metadata-only lookup found no notarization profile. Later on 5 November, the owner approved a dedicated App Store Connect Developer key, and Apple's `notarytool` validated and saved it as the local Keychain profile `HeyNotch-Notary`. No personal-account password was used. The first 2.8.0 submission was rejected because nested third-party helpers retained their original signatures and the nested source archive contained unsigned vendor inputs. The corrected workflow explicitly signs all app code and publishes the exact source as a separate same-release asset. Apple acceptance and a normal quarantined installation still need evidence for each resulting build. The source commit before this packaging correction passed both GitHub CI jobs: app tests/release compilation and repository checks.

## Historical initial audit snapshot

| Area | Evidence | Result |
|---|---|---|
| Currently running development app | `build/phase5/HeyNotch.app`, bundle `com.wolfieeee.heynotch`, version 2.7.3 (271) | Apple Development signed, arm64 Debug build. Not the distribution artifact. |
| Development signature | Apple Development identity; team `TVQX6QVQ7N`; hardened runtime present | Signature is valid for development. `com.apple.security.get-task-allow` is enabled in this Debug build. |
| Gatekeeper | `spctl --assess --type execute` rejected that development app | Do not distribute this Debug app as a production download. |
| Notarization | `xcrun stapler validate` reported no stapled ticket on that app | Not notarized/stapled as a release. |
| Available release signing identity | Developer ID Application certificate `B240E46B20B49C99C4DD4194248B380C1A59E713`, team `TVQX6QVQ7N` | A Developer ID candidate can be signed locally. The audit did not inspect or export private key material. |
| Release build | Previous universal Release compilation passed | Compilation is separate from release signing, installation, Gatekeeper, and live permission testing. |
| Minimum system | App/helper target macOS 14.0; process-level microphone attribution is guarded to 14.2+ | Full macOS 14/Intel runtime acceptance remains unverified. The Now Playing adapter requires macOS 15 and is guarded. |
| Updates | `HeyNotchUpdatesEnabled=false`; no fork-owned Sparkle public signing key configured | Updates intentionally stay disabled. A signed download can be shipped without automatic updates; do not enable the inherited machinery speculatively. |
| CI | Active workflow builds/tests and packages an **unsigned development ZIP** | No current Developer ID/notarization release pipeline. No successful remote CI run was established by this local audit. |
| Corresponding source and licenses | Source checkout contains the GPL license and third-party notices; they were absent from the app Resources directory | Release packaging includes the license files with the app and an exact corresponding-source archive as a separate asset on the same release. No distribution occurred during this audit. |

## Repeatable candidate preparation

[`scripts/release-candidate.sh`](../scripts/release-candidate.sh) is a local workflow. It never pushes, opens a pull request, publishes a release, changes an updater feed, or interacts with an upstream repository. It refuses a checkout whose `origin` does not identify `WOLFIEEEE/HeyNotch`.

Prepare locked dependencies with the normal documented build first if the machine has no package cache. Stop source edits during the candidate build. The script compares the complete versioned/unignored source snapshot before and after compilation and fails if it changes. It verifies every source-archive member and mode against that snapshot after packaging and during later verification. A process lock serializes release operations. If a process is killed, inspect the PID in `build/release-candidate/.release-operation.lock/pid` and remove that stale lock only after confirming the process has ended.

```sh
RELEASE_SIGNING_IDENTITY=B240E46B20B49C99C4DD4194248B380C1A59E713 \
  scripts/release-candidate.sh build
```

An optional `RELEASE_DERIVED_DATA` points to an existing dependency/build cache. The default is `build/release-derived-data`. The script uses a temporary explicit signing configuration rather than changing the Xcode project. It builds app and helper with hardened runtime, Developer ID signing, timestamps, and both architectures. It then signs all embedded code explicitly from the inside out, including Sparkle helpers and the MediaRemoteAdapter test client used at runtime. The preflight inspects each Mach-O architecture for Developer ID, the expected team, hardened runtime, a secure timestamp, and no debugging entitlement, and verifies nested bundle seals. It also checks bundle IDs and universal architecture coverage.

Outputs live in `build/release-candidate/`. The candidate ZIP contains the app, GPL license, third-party notices, `SOURCE_STATE.json`, and `READ-ME.txt` with a direct matching-release source link. The exact source archive and its matching source record are prepared separately under `build/release-candidate/source/`; the source archive is not nested in the app ZIP. Output is deliberately named **HeyNotch-CANDIDATE.zip**. The workflow refuses to overwrite an existing candidate; move that directory aside before starting another build. It refuses source entries named `.env`/private environment variants or ending in `.p8`, `.p12`, `.pfx`, or `.key`, so a downloaded credential cannot silently enter the source archive. Named `.env.example`, `.env.sample`, and `.env.template` files remain source. Potential fixtures are not silently removed; review the refusal explicitly. Keep real credential files in ignored `build/private/` or outside the checkout.

```sh
scripts/release-candidate.sh verify
```

Verification checks the staged app and the payload integrity record without uploading anything. It does not certify live-call behavior or notarization.

## Notarization authentication and explicit upload

The signing certificate alone does not authenticate to Apple's notarization service. The owner must have a validated `notarytool` Keychain profile on the signing Mac. The preferred setup for this release is an **App Store Connect team API key**, stored locally under the profile **HeyNotch-Notary**. The owner chooses the key's role and approves its creation: team keys are not limited to one app. Keep the downloaded `.p8` file private, for example in ignored `build/private/`, and never paste its contents into chat. [Apple's API-key guidance](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api).

Run `scripts/setup-notarization.command` in Terminal. Its default mode asks for the downloaded key path, Key ID, and Issuer ID, restricts the key file to owner read/write, and delegates credential validation/storage to Apple's `notarytool`. The helper does not upload an app. The optional `--apple-id` mode uses an app-specific password at Apple's hidden prompt; it is not required for API-key setup and never uses a regular account password. No credential material belongs in source, signing configurations, archives, or logs.

`xcrun notarytool store-credentials --help` describes the supported secure setup options for the installed Xcode toolchain. The script accepts only the **profile name**, through `NOTARY_PROFILE`; it does not retrieve or print the credentials.

Only the following explicit command uploads the candidate archive to Apple:

```sh
NOTARY_PROFILE=HeyNotch-Notary scripts/release-candidate.sh notarize
```

The Apple submission contains the distributable app and its notices/source-link record. The separate corresponding-source archive is not part of that submission: it preserves original source and vendor files, including binaries that are not distribution-signed. It must be published as **`HeyNotch-2.8.1-273-source.tar.gz`** alongside the notarized app ZIP on the same GitHub release with the same download access. The app's `READ-ME.txt` links directly to that exact source asset. The script saves a candidate-SHA-bound request record and the submission UUID **before waiting**. Rerunning the same command resumes that request; it does not silently upload a second copy. `NOTARY_WAIT_TIMEOUT` defaults to `20m`. A timeout leaves Apple processing the request and preserves the local records.

If the initial upload was interrupted before its UUID was saved, inspect `notarytool history --keychain-profile HeyNotch-Notary`. Supply a confirmed matching UUID with `NOTARY_SUBMISSION_ID=<UUID>` when rerunning. Recovery requires Apple's completed log to match the exact candidate SHA-256. An unknown outcome is a stop condition; do not delete records and blindly resubmit. If Apple confirms there was no submission, the owner can deliberately clear only the failed request records before retrying.

After acceptance, the script always retrieves `notary-log.json` and reports warnings. It staples a separate temporary copy, validates the ticket/signature/Gatekeeper result, and atomically promotes the finished assets to **`build/release-candidate/notarized/`**. The original candidate and its manifest remain unchanged, so failed stapling can be retried safely. The final directory has its own post-staple app-payload manifest, separate app ZIP and versioned source archive, release notes, installation instructions, source state, and portable `SHA256SUMS.txt` covering the release assets. `verify` checks both the original candidate and any completed notarized directory, validates the source archive against its manifest, and requires the app and source records to agree. The script never publishes to GitHub.

Apple's workflow requires stapling the app and then recreating the ZIP; a ZIP cannot itself carry a stapled ticket. Review the notary log even after acceptance. [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

A clean, downloaded, normally quarantined installation remains a separate acceptance gate. Prefer a different Mac/account and test both an app launched from the extracted download and a copy moved to Applications, including nested helper execution and a later launch. [Apple distribution testing](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Remaining product acceptance gates

1. **The actual release identity must be exercised.** Install the Developer ID candidate at its final app location and test startup, app/helper trust, model persistence, Keychain access, Accessibility insertion, and recording permissions. A test of the Apple Development build is not equivalent to a test of the Developer ID app, especially where macOS stores identity-bound permissions or Keychain access rules.
2. **Both sides must be independently proven.** Use known, different phrases on the microphone and call-audio channels. Confirm the source labels and exported text, verify that app-scoped capture excludes unrelated playback, and stop playback on each side separately. An echo of speaker playback into the microphone does not establish that the two capture paths both work. Use headphones or an isolated source when assessing separation.
3. **Real permission and notification flows must pass.** Check microphone/system-audio denial and recovery, permission revocation, stop/cancel during startup, native notification presentation and actions, app-active/background behavior, and Focus. A screenshot of the in-app reminder is not evidence of native notification delivery.
4. **Representative call and device cases must pass.** Exercise actual call apps/browser helpers, mute/unmute, device change/disconnect, app exit/restart, sleep/lock, overlapping voices, a long call, and transcription backlog. Record the tested macOS version and hardware. The existing synthetic throughput benchmark is useful but does not replace this evidence.
5. **Installation/distribution must pass.** On a clean account or separate Mac, download the final archive, preserve normal quarantine, move the app into Applications, and launch through Gatekeeper. Confirm nested helper execution and model download without development credentials. A local nonquarantined launch is insufficient.
6. **Release identity and source must agree.** The prepared preview uses 2.8.1/build 273 and GitHub tag v2.8.1-preview.2. Commit and review the exact app source before the final build; the release tag must target that commit, not the older public main commit. Include release notes and matching source, and check the final candidate's current verification record before publishing. Nothing in this audit authorizes upstream actions or removes the fork's push protections.

Meeting-specific evidence is maintained in [MEETINGS.md](MEETINGS.md). Other core-feature checks, including live Claude/OpenAI/OpenRouter requests and the wider insertion/Reminders matrix, remain in [PHASES_1_5.md](PHASES_1_5.md). Do not collapse those separate gates into a blanket “fully production ready” claim merely because one local call succeeds.

The subsequent [Meeting Library and transcript tools](MEETING_LIBRARY.md) extension passed 157 combined Swift tests and 42 repository checks. It adds optional text history/recovery, search/filter/export, and reviewed meeting task drafts. Those results do not close the recording-permission, real-call, native-notification/Focus, live-provider, notarization, or clean-install gates above.
