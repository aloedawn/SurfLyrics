#!/bin/bash
set -euo pipefail

repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repository_dir/build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

bash "$repository_dir/scripts/build-connection-helper.sh" "$output_dir"
helper_app="$output_dir/SurfLyrics Connection Helper.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$helper_app/Contents/Info.plist")
image_path="$output_dir/SurfLyrics-Helper-$version-macOS-arm64.dmg"
if [[ -e "$image_path" ]]; then
    printf 'Already exists: %s\nChoose an empty output directory.\n' "$image_path" >&2
    exit 1
fi
staging_dir=$(mktemp -d "$output_dir/package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT

ditto "$helper_app" "$staging_dir/SurfLyrics Connection Helper.app"
ln -s /Applications "$staging_dir/Applications"
cp "$repository_dir/docs/INSTALL.md" "$staging_dir/설치 안내.md"
cp "$repository_dir/LICENSE" "$staging_dir/LICENSE"
hdiutil create -volname 'SurfLyrics Helper' -srcfolder "$staging_dir" \
    -format UDZO -ov "$image_path"
(cd "$output_dir" && shasum -a 256 "$(basename "$image_path")") > "$image_path.sha256"
printf '\nInstaller: %s\n' "$image_path"
printf 'This command packages a signed app; it does not notarize or publish it.\n'
