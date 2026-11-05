#!/bin/bash
# Xcode build phase: package the native stdio connector, without a runtime install.
set -euo pipefail
root="${SRCROOT:?Run from the HeyNotch Xcode build phase}"
destination="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
scratch="${DERIVED_FILE_DIR:?}/MCPBridge"
mkdir -p "$destination" "$scratch"
binaries=()
for architecture in ${ARCHS:-arm64}; do
    arch_scratch="$scratch/$architecture"
    swift build --package-path "$root/MCPBridge" --scratch-path "$arch_scratch" \
        --configuration release --arch "$architecture" --disable-sandbox --product heynotch-mcp
    binary_dir="$(swift build --package-path "$root/MCPBridge" --scratch-path "$arch_scratch" \
        --configuration release --arch "$architecture" --disable-sandbox --show-bin-path)"
    binaries+=("$binary_dir/heynotch-mcp")
done
xcrun lipo -create "${binaries[@]}" -output "$destination/heynotch-mcp"
chmod 755 "$destination/heynotch-mcp"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    flags=(--force --sign "$identity" --options runtime --identifier com.wolfieeee.heynotch.mcp)
    if [ "$identity" != - ]; then flags+=(--timestamp); fi
    codesign "${flags[@]}" "$destination/heynotch-mcp"
fi
