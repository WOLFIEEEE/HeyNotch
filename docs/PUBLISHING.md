# Publish the first HeyNotch preview

This procedure is for **WOLFIEEEE/HeyNotch only**. It does not involve the upstream project. The website's `gh-pages` branch is independent of the app release.

## Prepare the source and identity

1. Review and commit the app source, preserving GPL-3.0 and third-party notices. Use app/XPC version 2.8.0 and build 272. The release tag will be `v2.8.0-preview.1`.
2. Keep signing/notarization credentials in Keychain. If a team API key is downloaded, keep its `.p8` outside source or in ignored `build/private/`; run `scripts/setup-notarization.command` yourself to validate/store it as `HeyNotch-Notary`. API-key setup is the default; the optional Apple ID route is not required.
3. Freeze edits, run the app/repository checks, then create a fresh candidate. Move an older `build/release-candidate` aside first; the script refuses to overwrite one.

```sh
RELEASE_SIGNING_IDENTITY=B240E46B20B49C99C4DD4194248B380C1A59E713 \
  scripts/release-candidate.sh build
scripts/release-candidate.sh verify
NOTARY_PROFILE=HeyNotch-Notary scripts/release-candidate.sh notarize
scripts/release-candidate.sh verify
```

The notarization step uploads to Apple. It does not publish publicly. Keep the request ID, accepted result, full notary log, both payload manifests, and checksum records. Interrupted waits resume with the same command; see [release readiness](RELEASE_READINESS.md) for initial-upload recovery.

The app ZIP contains HeyNotch.app, license notices, `SOURCE_STATE.json`, and `READ-ME.txt` with a direct link to the matching release's source asset. The exact source archive is prepared separately under `build/release-candidate/source/` and is not submitted inside the app ZIP. Source-only vendor binaries retain their original bytes; distribution signing applies to executable code shipped in the app bundle.

## Verify the actual distribution

The final files are under `build/release-candidate/notarized/`. Test the final ZIP through a real browser download with normal quarantine; use a clean account or another Mac where possible. Move the extracted app to Applications, launch normally, and confirm the nested MCP helper, Keychain access, model preparation, and identity-bound permissions. Also check first launch from Downloads/translocation and a later launch. Do not turn off Gatekeeper or strip quarantine to make this check pass.

A locally signed build or an Apple Accepted result alone does not establish this acceptance. Record the tested system and hardware. Keep the outstanding live-call, notification, provider, and hardware limits visible in prerelease notes.

## Prepare the GitHub release

Create the tag from the **reviewed source commit recorded in SOURCE_STATE.json**, after confirming the final candidate was built from that commit without uncommitted source changes. Do not tag old public main merely because it is the default branch. The owner handles branch/tag pushes and publication explicitly.

Attach these files from the final directory:

- `HeyNotch-2.8.0-272-notarized.zip`
- `HeyNotch-2.8.0-272-source.tar.gz`
- `SOURCE_STATE.json`
- `SHA256SUMS.txt`
- `INSTALL.md`
- `RELEASE_NOTES.md`

Publish the app ZIP and **`HeyNotch-2.8.0-272-source.tar.gz` together on this same release**, with the same download access. Before publishing, confirm that the source link in the app ZIP's `READ-ME.txt` names this tag and source asset, both `SOURCE_STATE.json` copies agree, and the source archive matches that manifest. Do not publish the app ZIP alone or substitute GitHub's automatically generated source archive for this verified corresponding-source asset.

Use `RELEASE_NOTES.md` as the release description. The following creates a **draft prerelease** only after the matching tag has been pushed:

```sh
gh release create v2.8.0-preview.1 \
  --repo WOLFIEEEE/HeyNotch --verify-tag --draft --prerelease \
  --title 'HeyNotch 2.8.0 Preview 1' \
  --notes-file build/release-candidate/notarized/RELEASE_NOTES.md \
  build/release-candidate/notarized/HeyNotch-2.8.0-272-notarized.zip \
  build/release-candidate/notarized/HeyNotch-2.8.0-272-source.tar.gz \
  build/release-candidate/notarized/SOURCE_STATE.json \
  build/release-candidate/notarized/SHA256SUMS.txt \
  build/release-candidate/notarized/INSTALL.md \
  build/release-candidate/notarized/RELEASE_NOTES.md
```

Review the draft, artifact hashes, downloaded-install result, and limitations before publishing. After publication, verify the public app and source download bytes and the `READ-ME.txt` source link, then update the website/README availability text to the actual release asset URL. Do not present a planned download URL as an available release. Automatic updates remain disabled; a published ZIP does not enable Sparkle.
