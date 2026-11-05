#!/bin/bash
# Local, fork-only release preparation. Nothing is pushed or published.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/release-candidate.sh build | verify | notarize

build      Build a universal Developer ID Release and package a CANDIDATE ZIP.
verify     Verify the existing staged candidate without building or uploading.
notarize   Explicitly submit the existing candidate to Apple, wait for acceptance,
           resume an existing request, staple a copy, and prepare release assets.

Environment:
  RELEASE_SIGNING_IDENTITY  Developer ID Application certificate SHA-1 or name
                           (required for build; no private key is printed)
  RELEASE_TEAM_ID          Defaults to TVQX6QVQ7N
  RELEASE_DERIVED_DATA     Defaults to build/release-derived-data
  NOTARY_PROFILE          Existing notarytool Keychain profile (notarize only)
  NOTARY_WAIT_TIMEOUT     Wait per attempt; defaults to 20m. Rerun to resume.
  NOTARY_SUBMISSION_ID    Recover an interrupted initial submission by its UUID.
                         Requires an existing request record and matching Apple log.

Outputs: build/release-candidate/; final assets in its notarized/ directory.
This script never changes Sparkle settings, publishes releases, or uses gh/git push.
Only 'notarize' uploads the candidate archive to Apple's notarization service.
USAGE
}

command_name="${1:---help}"
case "$command_name" in build|verify|notarize) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
release_root="$repository_root/build/release-candidate"
payload="$release_root/HeyNotch"
app="$payload/HeyNotch.app"
source_payload="$release_root/source"
team="${RELEASE_TEAM_ID:-TVQX6QVQ7N}"
mkdir -p "$release_root"

fail() { echo "Release gate failed: $*" >&2; exit 1; }

# Repository identity is checked without contacting or changing any remote.
origin="$(git remote get-url origin)"
case "$origin" in
    https://github.com/WOLFIEEEE/HeyNotch|https://github.com/WOLFIEEEE/HeyNotch.git|git@github.com:WOLFIEEEE/HeyNotch.git|ssh://git@github.com/WOLFIEEEE/HeyNotch.git) ;;
    *) fail "origin must identify WOLFIEEEE/HeyNotch; no remote action was taken." ;;
esac

# Serialize the whole local release operation, including submission and promotion.
# A killed process leaves an explicit stale lock; never steal another process's lock.
release_lock="$release_root/.release-operation.lock"
if ! mkdir "$release_lock" 2>/dev/null; then
    fail "Another release operation holds $release_lock. Inspect its pid file; only after that process has exited, remove the stale lock directory and retry."
fi
printf '%s\n' "$$" > "$release_lock/pid"
stapling_root=""
cleanup_release() {
    if [ -n "${stapling_root:-}" ] && [ -d "$stapling_root" ]; then rm -rf -- "$stapling_root"; fi
    local lock_owner=""
    if [ -f "$release_lock/pid" ]; then read -r lock_owner < "$release_lock/pid" || true; fi
    if [ "$lock_owner" = "$$" ]; then
        rm -f -- "$release_lock/pid"
        rmdir "$release_lock" 2>/dev/null || true
    fi
}
trap cleanup_release EXIT

source_state() {
    python3 - "$repository_root" "$1" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
root, destination = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).split(b'\0')
files = {}
for name in sorted(set(p for p in paths if p)):
    relative = os.fsdecode(name)
    entry = pathlib.PurePosixPath(relative)
    # Do not silently omit potential credentials from an otherwise exact snapshot.
    # Refuse and ask the owner to move private material to ignored build/private/.
    # Named environment examples remain source; no legitimate fixture is auto-deleted.
    env_examples = {'.env.example', '.env.sample', '.env.template'}
    private_suffix = entry.suffix.lower() in {'.p8', '.p12', '.pfx', '.key'}
    private_env = (entry.name == '.env' or entry.name.startswith('.env.')) and entry.name not in env_examples
    if private_suffix or private_env:
        raise SystemExit('Potential credential file cannot enter release source: ' + relative
                         + '. Move private material to ignored build/private/; review intentional test fixtures explicitly.')
    path = root / relative
    if not path.exists() and not path.is_symlink():
        continue # Deleted tracked files are absent from the built snapshot.
    if path.is_symlink():
        value = b'symlink\0' + os.fsencode(os.readlink(path))
    elif path.is_file():
        value = path.read_bytes()
    else:
        raise SystemExit('Unsupported source entry: ' + relative)
    files[relative] = {'sha256': hashlib.sha256(value).hexdigest(), 'mode': path.lstat().st_mode & 0o777}
state = {'repository': 'WOLFIEEEE/HeyNotch',
         'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
         'files': files}
destination.write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
PY
}

payload_state() {
    python3 - "${2:-$payload}" "$1" <<'PY'
import hashlib, json, os, pathlib, sys
root, destination = map(pathlib.Path, sys.argv[1:])
state = {}
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        data = b'symlink\0' + os.fsencode(os.readlink(path))
    elif path.is_file():
        data = path.read_bytes()
    else:
        continue
    state[str(path.relative_to(root))] = {'sha256': hashlib.sha256(data).hexdigest(), 'mode': path.lstat().st_mode & 0o777}
destination.write_text(json.dumps(state, sort_keys=True) + '\n')
PY
}

verify_source_archive() {
    python3 - "${1:-$source_payload}" "${2:-HeyNotch-source.tar.gz}" <<'PYSOURCE'
import hashlib, json, os, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
state = json.loads((root / 'SOURCE_STATE.json').read_text())
expected = {'HeyNotch-source/' + name: record for name, record in state['files'].items()}
with tarfile.open(root / sys.argv[2], 'r:gz') as archive:
    members = archive.getmembers()
    if len(members) != len(expected) or {member.name for member in members} != set(expected):
        raise SystemExit('Source archive entries do not match SOURCE_STATE.json.')
    for member in members:
        if member.issym():
            data = b'symlink\0' + os.fsencode(member.linkname)
        elif member.isfile() or (member.islnk() and member.linkname in expected):
            data = archive.extractfile(member).read()
        else:
            raise SystemExit('Unsupported source archive entry: ' + member.name)
        record = expected[member.name]
        if hashlib.sha256(data).hexdigest() != record['sha256'] or member.mode & 0o777 != record['mode']:
            raise SystemExit('Source archive changed after the build snapshot: ' + member.name)
print('Passed: exact source archive content and modes match the build snapshot.')
PYSOURCE
}

verify_payload() {
    test -f "$release_root/payload-state.json" || fail "Payload integrity record is missing."
    test ! -e "$payload/HeyNotch-source.tar.gz" || fail "Corresponding source must be a separate release asset, outside the notarization upload."
    cmp -s "$source_payload/SOURCE_STATE.json" "$payload/SOURCE_STATE.json" || fail "Source and app payload manifests differ."
    payload_state "$release_root/payload-current.json"
    cmp -s "$release_root/payload-state.json" "$release_root/payload-current.json" || fail "Staged payload changed after packaging. Rebuild the candidate."
}

verify_app() {
    local checked_app="${1:-$app}"
    test -d "$checked_app" || fail "No staged app. Run build first."
    python3 "$repository_root/scripts/release-signing.py" verify "$checked_app" "$team"
    codesign --verify --deep --strict --verbose=2 "$checked_app"
    python3 - "$checked_app" "$team" <<'PY'
import pathlib, plistlib, subprocess, sys
app, team = pathlib.Path(sys.argv[1]), sys.argv[2]
for bundle, expected in [(app, 'com.wolfieeee.heynotch'),
        (app / 'Contents/XPCServices/HeyNotchXPCHelper.xpc', 'com.wolfieeee.heynotch.HeyNotchXPCHelper')]:
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != expected:
        raise SystemExit('Unexpected bundle identifier: ' + str(bundle))
    identity = subprocess.run(['codesign', '-dv', '--verbose=4', str(bundle)], capture_output=True, text=True, check=True).stderr
    if 'Authority=Developer ID Application:' not in identity or ('TeamIdentifier=' + team) not in identity:
        raise SystemExit('Expected Developer ID Application signing with team ' + team + ': ' + str(bundle))
    # The helper is an embedded service; both executable targets must use runtime.
    if 'runtime)' not in identity or 'Timestamp=' not in identity:
        raise SystemExit('Hardened runtime or secure timestamp is missing: ' + str(bundle))
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)], capture_output=True, check=True).stdout
    if entitlements and plistlib.loads(entitlements).get('com.apple.security.get-task-allow', False):
        raise SystemExit('Debugging entitlement must not be distributed: ' + str(bundle))
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    architectures = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()
    if set(architectures) != {'arm64', 'x86_64'}:
        raise SystemExit('Expected both Apple Silicon and Intel architectures: ' + str(bundle))
helper = app / 'Contents/Helpers/heynotch-mcp'
if not helper.is_file():
    raise SystemExit('Missing bundled MCP helper.')
identity = subprocess.run(['codesign', '-dv', '--verbose=4', str(helper)], capture_output=True, text=True, check=True).stderr
if 'Authority=Developer ID Application:' not in identity or ('TeamIdentifier=' + team) not in identity or 'runtime)' not in identity or 'Timestamp=' not in identity:
    raise SystemExit('MCP helper must be Developer ID signed with hardened runtime and secure timestamp.')
entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(helper)], capture_output=True, check=True).stdout
if entitlements and plistlib.loads(entitlements).get('com.apple.security.get-task-allow', False):
    raise SystemExit('MCP helper must not carry the debugging entitlement.')
if set(subprocess.check_output(['lipo', '-archs', str(helper)], text=True).split()) != {'arm64', 'x86_64'}:
    raise SystemExit('MCP helper must support both Apple Silicon and Intel.')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('HeyNotchUpdatesEnabled', False):
    raise SystemExit('This candidate workflow requires automatic updates to remain disabled.')
if not info.get('NSMicrophoneUsageDescription'):
    raise SystemExit('Missing microphone purpose string.')
print('Passed: universal app/helper, Developer ID, hardened runtime, no debug entitlement, updates disabled.')
PY
}

verify_notarized() {
    local final_root="$release_root/notarized"
    test -f "$final_root/payload-state.json" || fail "Final payload integrity record is missing."
    payload_state "$release_root/notarized-current.json" "$final_root/HeyNotch"
    cmp -s "$final_root/payload-state.json" "$release_root/notarized-current.json" || fail "Notarized payload changed."
    verify_app "$final_root/HeyNotch/HeyNotch.app"
    local final_version final_build
    final_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$final_root/HeyNotch/HeyNotch.app/Contents/Info.plist")"
    final_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$final_root/HeyNotch/HeyNotch.app/Contents/Info.plist")"
    verify_source_archive "$final_root" "HeyNotch-$final_version-$final_build-source.tar.gz"
    cmp -s "$final_root/SOURCE_STATE.json" "$final_root/HeyNotch/SOURCE_STATE.json" || fail "Final source and app manifests differ."
    xcrun stapler validate "$final_root/HeyNotch/HeyNotch.app"
    spctl --assess --type execute --verbose=2 "$final_root/HeyNotch/HeyNotch.app"
    (cd "$final_root" && shasum -a 256 -c SHA256SUMS.txt)
}

submission_id_from() {
    python3 - "$1" <<'PYID'
import json, pathlib, sys, uuid
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(str(uuid.UUID(record['id'])))
PYID
}

if [ "$command_name" = build ]; then
    test -n "${RELEASE_SIGNING_IDENTITY:-}" || fail "Set RELEASE_SIGNING_IDENTITY to the Developer ID Application certificate."
    test ! -e "$payload" || fail "A candidate already exists. Move build/release-candidate aside before building another; it will not be overwritten."
    source_state "$release_root/source-before.json"
    config="$release_root/signing.xcconfig"
    # Reject line breaks before writing user-provided values into an xcconfig.
    case "$RELEASE_SIGNING_IDENTITY$team" in *$'\n'*|*$'\r'*) fail "Signing configuration cannot contain line breaks." ;; esac
    cat > "$config" <<EOF
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = $team
CODE_SIGN_IDENTITY = $RELEASE_SIGNING_IDENTITY
CODE_SIGN_IDENTITY[sdk=macosx*] = $RELEASE_SIGNING_IDENTITY
CODE_SIGNING_ALLOWED = YES
CODE_SIGNING_REQUIRED = YES
CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO
ENABLE_HARDENED_RUNTIME = YES
OTHER_CODE_SIGN_FLAGS = --timestamp
EOF
    derived="${RELEASE_DERIVED_DATA:-$repository_root/build/release-derived-data}"
    xcodebuild build -project HeyNotch.xcodeproj -scheme HeyNotch -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
        -disableAutomaticPackageResolution -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
        -xcconfig "$config" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
        > "$release_root/build.log" 2>&1 || { tail -60 "$release_root/build.log"; fail "Build failed; see build.log."; }
    source_state "$release_root/source-after.json"
    cmp -s "$release_root/source-before.json" "$release_root/source-after.json" || fail "Source changed during the build. Rebuild from a stable checkout."
    mkdir "$payload"
    ditto "$derived/Build/Products/Release/HeyNotch.app" "$app"
    python3 "$repository_root/scripts/release-signing.py" sign "$app" "$RELEASE_SIGNING_IDENTITY" "$team"
    verify_app
    cp LICENSE THIRD_PARTY_LICENSES "$payload/"
    cp "$release_root/source-after.json" "$payload/SOURCE_STATE.json"
    # Preserve the exact vendor/source bytes in a separate, equally accessible
    # release asset. Apple recursively scans archives, including vendor test
    # binaries that are source inputs rather than installed app components.
    mkdir "$source_payload"
    cp "$release_root/source-after.json" "$source_payload/SOURCE_STATE.json"
    python3 - "$repository_root" "$source_payload" "$payload" <<'PY'
import json, pathlib, sys, tarfile
root, source_payload, payload = map(pathlib.Path, sys.argv[1:])
state = json.loads((source_payload / 'SOURCE_STATE.json').read_text())
with tarfile.open(source_payload / 'HeyNotch-source.tar.gz', 'w:gz') as archive:
    for relative in state['files']:
        archive.add(root / relative, arcname='HeyNotch-source/' + relative, recursive=False)
(payload / 'READ-ME.txt').write_text('HeyNotch — independent personal fork at WOLFIEEEE/HeyNotch.\n'
    'GPL-3.0; license notices and exact source manifest are included.\n'
    'Download the exact corresponding source alongside this app, at no charge:\n'
    'https://github.com/WOLFIEEEE/HeyNotch/releases/download/v2.8.2-preview.3/HeyNotch-2.8.2-274-source.tar.gz\n'
    'Move HeyNotch.app to Applications before configuring recording permissions.\n'
    'Automatic updates are disabled in this candidate.\n'
    'See docs/RELEASE_READINESS.md in the source for verification evidence and remaining release gates.\n')
PY
    verify_source_archive
    payload_state "$release_root/payload-state.json"
    ditto -c -k --sequesterRsrc --keepParent "$payload" "$release_root/HeyNotch-CANDIDATE.zip"
    (cd "$release_root" && shasum -a 256 HeyNotch-CANDIDATE.zip > candidate.sha256)
    echo "Created candidate only: $release_root/HeyNotch-CANDIDATE.zip"
    echo "It is not yet notarized or approved for production. No upload or publication occurred."
elif [ "$command_name" = verify ]; then
    verify_app
    verify_payload
    verify_source_archive
    test -f "$release_root/HeyNotch-CANDIDATE.zip" && test -f "$release_root/candidate.sha256" || fail "Candidate archive/checksum is missing."
    (cd "$release_root" && shasum -a 256 -c candidate.sha256)
    test -f "$source_payload/HeyNotch-source.tar.gz" || fail "Corresponding source archive is missing."
    test -f "$payload/LICENSE" && test -f "$payload/THIRD_PARTY_LICENSES" || fail "License notices are missing."
    if [ -d "$release_root/notarized" ]; then verify_notarized; fi
    echo "Package integrity verification passed. Live-call and clean-install acceptance are separate."
elif [ "$command_name" = notarize ]; then
    test -n "${NOTARY_PROFILE:-}" || fail "Run scripts/setup-notarization.command, then set NOTARY_PROFILE=HeyNotch-Notary."
    verify_app
    release_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    release_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
    test "$release_version:$release_build" = "2.8.2:274" || fail "This preview requires app version 2.8.2 (274). Build a fresh candidate before notarization."
    verify_payload
    verify_source_archive
    test -f "$release_root/HeyNotch-CANDIDATE.zip" || fail "Candidate ZIP is missing."
    (cd "$release_root" && shasum -a 256 -c candidate.sha256)
    if [ -d "$release_root/notarized" ]; then
        verify_notarized
        echo "Existing notarized release assets verified; no upload occurred."
        exit 0
    fi
    candidate_hash="$(shasum -a 256 "$release_root/HeyNotch-CANDIDATE.zip" | awk '{print $1}')"
    request_record="$release_root/notary-request.json"
    submission_record="$release_root/notary-submission.json"
    submission_temporary="$release_root/notary-submission.pending.json"
    if [ -f "$request_record" ]; then
        python3 - "$request_record" "$candidate_hash" <<'PYREQUEST'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
if record.get('candidateSHA256') != sys.argv[2]:
    raise SystemExit('The stored notarization request belongs to a different candidate. Rebuild separately.')
PYREQUEST
    else
        test -z "${NOTARY_SUBMISSION_ID:-}" || fail "Recovery requires this candidate's existing notary-request.json."
        python3 - "$request_record" "$candidate_hash" <<'PYREQUEST'
import datetime, json, pathlib, sys
record = {'candidateSHA256': sys.argv[2], 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
pathlib.Path(sys.argv[1]).write_text(json.dumps(record, indent=2) + '\n')
PYREQUEST
        echo "Submitting the candidate to Apple. This does not create a public release."
        # Persist the request before uploading. An interrupted upload must not silently resubmit.
        xcrun notarytool submit "$release_root/HeyNotch-CANDIDATE.zip" --keychain-profile "$NOTARY_PROFILE" \
            --output-format json > "$submission_temporary" || fail "Submission interrupted. Preserve these records and recover its ID from Apple's history before retrying."
    fi
    if [ ! -f "$submission_record" ]; then
        if [ -n "${NOTARY_SUBMISSION_ID:-}" ]; then
            python3 - "$submission_record" "$NOTARY_SUBMISSION_ID" <<'PYRECOVER'
import json, pathlib, sys, uuid
record = {'id': str(uuid.UUID(sys.argv[2])), 'recovered': True}
pathlib.Path(sys.argv[1]).write_text(json.dumps(record, indent=2) + '\n')
PYRECOVER
        elif [ -f "$submission_temporary" ] && submission_id_from "$submission_temporary" >/dev/null 2>&1; then
            mv "$submission_temporary" "$submission_record"
        else
            fail "Submission outcome is unknown. Use notarytool history with the same profile, then rerun with NOTARY_SUBMISSION_ID=<matching UUID>. Do not delete the request record."
        fi
    fi
    submission_id="$(submission_id_from "$submission_record")" || fail "Invalid submission record."
    echo "Waiting for existing Apple submission $submission_id; rerunning this command resumes it."
    # Timeout or an interrupted wait does not lose the saved submission ID.
    xcrun notarytool wait "$submission_id" --keychain-profile "$NOTARY_PROFILE" \
        --timeout "${NOTARY_WAIT_TIMEOUT:-20m}" --output-format json > "$release_root/notary-wait.json" || true
    xcrun notarytool info "$submission_id" --keychain-profile "$NOTARY_PROFILE" \
        --output-format json > "$release_root/notary-result.pending.json" || fail "Cannot retrieve submission status. Rerun notarize to resume; no new upload is needed."
    mv "$release_root/notary-result.pending.json" "$release_root/notary-result.json"
    notary_status="$(python3 - "$release_root/notary-result.json" "$submission_id" <<'PYSTATUS'
import json, pathlib, sys, uuid
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if str(uuid.UUID(result['id'])) != sys.argv[2]:
    raise SystemExit('Unexpected submission status ID.')
print(result['status'])
PYSTATUS
)"
    case "$notary_status" in
        Accepted|Invalid|Rejected) ;;
        *) fail "Apple status: $notary_status. Rerun notarize to resume the saved request." ;;
    esac
    # Apple recommends reviewing the log even after acceptance, since it may contain warnings.
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$release_root/notary-log.json"
    python3 - "$release_root/notary-log.json" "$candidate_hash" "$submission_record" <<'PYLOG'
import json, pathlib, sys
log = json.loads(pathlib.Path(sys.argv[1]).read_text())
recovered = json.loads(pathlib.Path(sys.argv[3]).read_text()).get('recovered', False)
actual_hash = log.get('sha256')
if (actual_hash is not None and str(actual_hash).lower() != sys.argv[2]) or (recovered and actual_hash is None):
    raise SystemExit('Apple log does not bind this recovered submission to the exact candidate SHA-256.')
issues = log.get('issues') or []
print('Notary log saved; warning count:', sum(item.get('severity') == 'warning' for item in issues))
if log.get('status') != 'Accepted' or any(item.get('severity') == 'error' for item in issues):
    raise SystemExit('Notarization was not accepted. Inspect notary-log.json; no release assets created.')
PYLOG
    test "$notary_status" = Accepted || fail "Notarization was not accepted. See notary-log.json."

    # Never mutate the candidate payload or its manifest. Staple an isolated copy;
    # a failed/interrupted attempt can be retried from the unchanged candidate.
    stapling_root="$(mktemp -d "$release_root/.stapling-XXXXXX")"
    ditto "$payload" "$stapling_root/HeyNotch"
    stapled_app="$stapling_root/HeyNotch/HeyNotch.app"
    xcrun stapler staple "$stapled_app"
    xcrun stapler validate "$stapled_app"
    verify_app "$stapled_app"
    spctl --assess --type execute --verbose=2 "$stapled_app"
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stapled_app/Contents/Info.plist")"
    build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stapled_app/Contents/Info.plist")"
    case "$version-$build_number" in *[!0-9A-Za-z._-]*) fail "Unsafe artifact version." ;; esac
    artifact_name="HeyNotch-$version-$build_number-notarized.zip"
    source_name="HeyNotch-$version-$build_number-source.tar.gz"
    payload_state "$stapling_root/payload-state.json" "$stapling_root/HeyNotch"
    ditto -c -k --sequesterRsrc --keepParent "$stapling_root/HeyNotch" "$stapling_root/$artifact_name"
    cp "$source_payload/HeyNotch-source.tar.gz" "$stapling_root/$source_name"
    cp "$payload/SOURCE_STATE.json" "$stapling_root/SOURCE_STATE.json"
    # Release instructions come from the exact source packaged with this binary,
    # not whatever happens to be in the working tree on notarization day.
    python3 - "$source_payload/HeyNotch-source.tar.gz" "$stapling_root" <<'PYNOTES'
import pathlib, sys, tarfile
out = pathlib.Path(sys.argv[2])
with tarfile.open(sys.argv[1], 'r:gz') as source:
    for relative, destination in [('docs/releases/2.8.2-preview.3.md', 'RELEASE_NOTES.md'), ('docs/INSTALL.md', 'INSTALL.md')]:
        entry = source.getmember('HeyNotch-source/' + relative)
        if not entry.isfile():
            raise SystemExit('Release instructions must be regular source files.')
        (out / destination).write_bytes(source.extractfile(entry).read())
PYNOTES
    (cd "$stapling_root" && shasum -a 256 "$artifact_name" "$source_name" SOURCE_STATE.json RELEASE_NOTES.md INSTALL.md > SHA256SUMS.txt)
    test ! -e "$release_root/notarized" || fail "A final release directory appeared during preparation."
    mv "$stapling_root" "$release_root/notarized"
    stapling_root=""
    verify_notarized
    echo "Prepared verified assets in $release_root/notarized/"
    echo "No GitHub release was published. Perform the downloaded/quarantined install checks before publication."
fi
