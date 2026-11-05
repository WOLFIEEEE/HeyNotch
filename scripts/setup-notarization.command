#!/bin/bash
# Owner-run setup. Secret contents are handled only by Apple's notarytool/Keychain.
set -euo pipefail
set +x
notary_profile="HeyNotch-Notary"
notary_team="TVQX6QVQ7N"
method="${1:---api-key}"
case "$method" in
    --help|-h)
        echo "Run in Terminal to create the local HeyNotch-Notary Keychain profile."
        echo "Default/--api-key: App Store Connect team API key path, Key ID, and Issuer ID."
        echo "Optional --apple-id: Apple ID and Apple's hidden app-specific-password prompt."
        echo "notarytool validates with Apple and stores credentials in Keychain; no app is uploaded."
        exit 0 ;;
    --api-key|--apple-id) ;;
    *) echo "Use --api-key (default), --apple-id, or --help." >&2; exit 2 ;;
esac
[ -t 0 ] || { echo "Open this .command file in Terminal; interactive input is required." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Install Xcode command-line tools first." >&2; exit 1; }
echo "Set up HeyNotch notarization on this Mac"
echo "Developer team: $notary_team / Local Keychain profile: $notary_profile"
echo "Apple validates the supplied credentials. This step does not upload or publish the app."
echo
if [ "$method" = --api-key ]; then
    echo "Use an App Store Connect team API key with the required developer access."
    echo "Keep its .p8 file in a private location; never commit or paste its contents into chat."
    echo "For this checkout, build/private/ is an ignored local location."
    read -r -p "Path to the downloaded .p8 file: " notary_key_path
    read -r -p "Key ID: " notary_key_id
    read -r -p "Issuer ID: " notary_issuer
    [ -f "$notary_key_path" ] && [ ! -L "$notary_key_path" ] || { echo "Choose a regular .p8 file, not a symbolic link." >&2; exit 1; }
    case "$notary_key_path" in *.p8) ;; *) echo "Expected a .p8 API key file." >&2; exit 1 ;; esac
    case "$notary_key_id" in ""|*[!A-Za-z0-9]*) echo "Invalid Key ID." >&2; exit 1 ;; esac
    [[ "$notary_issuer" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { echo "Expected a UUID Issuer ID for a team key." >&2; exit 1; }
    chmod 600 "$notary_key_path"
    xcrun notarytool store-credentials "$notary_profile" --key "$notary_key_path" --key-id "$notary_key_id" --issuer "$notary_issuer"
    unset notary_key_path notary_key_id notary_issuer
else
    echo "Optional Apple ID method: use an app-specific password, never your regular Apple ID password."
    echo "Enter that password only when notarytool displays its secure prompt."
    read -r -p "Apple ID email: " notary_apple_id
    case "$notary_apple_id" in
        *[[:space:]]*|"") echo "Enter an Apple ID email without spaces." >&2; exit 1 ;;
        *@*.*) ;;
        *) echo "Enter the Apple ID email for this developer team." >&2; exit 1 ;;
    esac
    xcrun notarytool store-credentials "$notary_profile" --team-id "$notary_team" --apple-id "$notary_apple_id"
    unset notary_apple_id
fi
echo
echo "Setup complete. Use NOTARY_PROFILE=HeyNotch-Notary with scripts/release-candidate.sh notarize."
echo "That separate command uploads the prepared candidate to Apple; it does not publish to GitHub."
