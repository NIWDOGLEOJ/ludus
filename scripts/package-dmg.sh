#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:-$project_root/dist}"
app_path="$output_root/Ludus.app"
dmg_path="$output_root/Ludus.dmg"
temp_dmg_dir="$output_root/dmg_temp"

if [[ ! -d "$app_path" ]]; then
    print "Ludus.app not found in $output_root. Running package-app.sh..."
    zsh "$project_root/scripts/package-app.sh" "$output_root"
fi

rm -rf "$temp_dmg_dir" "$dmg_path"
mkdir -p "$temp_dmg_dir"

cp -R "$app_path" "$temp_dmg_dir/"
ln -s /Applications "$temp_dmg_dir/Applications"

# Strip any extended attributes or quarantine from the staging files
xattr -cr "$temp_dmg_dir" 2>/dev/null || true

hdiutil create \
    -volname "Ludus" \
    -srcfolder "$temp_dmg_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

rm -rf "$temp_dmg_dir"

# Ad-hoc sign the disk image container
codesign --force --sign - "$dmg_path" 2>/dev/null || true

print "Created DMG at: $dmg_path"
