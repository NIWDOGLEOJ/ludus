#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${BUILD_CONFIGURATION:-release}"
output_root="${1:-$project_root/dist}"
bundle_id="${LUDUS_BUNDLE_ID:-${OVERCROSS_BUNDLE_ID:-com.ludus.app}}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Volumes/sata ssd 1/Applications/Xcode.app" ]]; then
        export DEVELOPER_DIR="/Volumes/sata ssd 1/Applications/Xcode.app"
    elif [[ -d "/Applications/Xcode.app" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app"
    fi
fi

swift build \
    --package-path "$project_root" \
    --configuration "$configuration" \
    --product Ludus

bin_path="$(swift build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"
app_path="$output_root/Ludus.app"
contents_path="$app_path/Contents"

rm -rf "$app_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$bin_path/Ludus" "$contents_path/MacOS/Ludus"
cp "$project_root/Packaging/Ludus-Info.plist" "$contents_path/Info.plist"
chmod 755 "$contents_path/MacOS/Ludus"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$contents_path/Info.plist"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    print "Signing with identity: $CODESIGN_IDENTITY"
    codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$app_path"
else
    print "Ad-hoc signing bundle..."
    codesign --force --deep --sign - "$app_path"
fi

print "Created $app_path"
