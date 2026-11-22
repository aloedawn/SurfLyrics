#!/bin/bash
set -euo pipefail

repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
tap_repo="${SURFLYRICS_TAP_REPO:-aloedawn/homebrew-tap}"
output_dir="${1:-$repository_dir/build/release}"

if [[ -n "$(git -C "$repository_dir" status --porcelain)" ]]; then
    printf 'Working tree is not clean. Commit or stash changes before releasing.\n' >&2
    exit 1
fi

branch="$(git -C "$repository_dir" rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
    printf 'Releases must run from main (current: %s).\n' "$branch" >&2
    exit 1
fi

node --test "$repository_dir/scripts/spotify-client-bridge.test.mjs"
xcodebuild test \
    -project "$repository_dir/SurfLyrics.xcodeproj" \
    -scheme SurfLyrics \
    -destination 'platform=macOS' \
    -quiet

rm -rf "$output_dir"
SURFLYRICS_SIGNING_MODE="${SURFLYRICS_SIGNING_MODE:-developer-id}" \
    bash "$repository_dir/scripts/package-app.sh" "$output_dir"

app_path="$output_dir/export/SurfLyrics.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
dmg_path="$output_dir/SurfLyrics-$version-macOS-arm64.dmg"
sha256="$(awk '{print $1}' "$dmg_path.sha256")"
tag="v$version"

if git -C "$repository_dir" rev-parse "$tag" >/dev/null 2>&1; then
    printf 'Tag %s already exists.\n' "$tag" >&2
    exit 1
fi

git -C "$repository_dir" push origin main
git -C "$repository_dir" tag -a "$tag" -m "SurfLyrics $version"
git -C "$repository_dir" push origin "$tag"

gh release create "$tag" \
    --repo aloedawn/SurfLyrics \
    --title "SurfLyrics $version" \
    --generate-notes \
    "$dmg_path" \
    "$dmg_path.sha256"

tap_dir=$(mktemp -d "$output_dir/tap.XXXXXX")
trap 'rm -rf "$tap_dir"' EXIT

gh repo clone "$tap_repo" "$tap_dir"
bash "$repository_dir/scripts/render-cask.sh" "$version" "$sha256" "$tap_dir/Casks/surflyrics.rb"
git -C "$tap_dir" add Casks/surflyrics.rb
git -C "$tap_dir" commit -m "Update surflyrics to $version"
git -C "$tap_dir" push origin HEAD

printf '\nReleased %s and updated %s\n' "$tag" "$tap_repo"
