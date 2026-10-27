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

hdiutil create \
    -volname "Ludus" \
    -srcfolder "$temp_dmg_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

rm -rf "$temp_dmg_dir"
print "Created DMG at: $dmg_path"
