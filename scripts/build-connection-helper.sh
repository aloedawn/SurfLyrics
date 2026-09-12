#!/bin/bash
set -euo pipefail

repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repository_dir/build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
helper_app="$output_dir/SurfLyrics Connection Helper.app"
signing_identity="${SURFLYRICS_SIGNING_IDENTITY:-Apple Development}"

# Full Xcode is required for Swift, the macOS 27 SDK, and Icon Composer asset compilation.
mkdir -p "$helper_app/Contents/MacOS" "$helper_app/Contents/Resources" "$output_dir/swift-module-cache"
cp "$repository_dir/SpotifyConnectionHelper/Info.plist" "$helper_app/Contents/Info.plist"
xcrun swiftc -swift-version 6 -O -D SURFLYRICS_CONNECTION_HELPER \
    -target arm64-apple-macosx27.0 -module-cache-path "$output_dir/swift-module-cache" \
    "$repository_dir/SpotifyConnectionHelper/main.swift" \
    "$repository_dir/SpotifyConnectionHelper/SpotifyConnectionLauncher.swift" \
    "$repository_dir/SurfLyrics/SpotifyClientEndpoint.swift" \
    -o "$helper_app/Contents/MacOS/SurfLyricsConnectionHelper"
xcrun actool "$repository_dir/SpotifyConnectionHelper/HelperIcon.icon" \
    --compile "$helper_app/Contents/Resources" --output-format human-readable-text \
    --app-icon HelperIcon --include-all-app-icons --target-device mac \
    --minimum-deployment-target 27.0 --platform macosx \
    --output-partial-info-plist "$output_dir/helper-icon-info.plist"
/usr/libexec/PlistBuddy -c "Merge '$output_dir/helper-icon-info.plist'" "$helper_app/Contents/Info.plist"
codesign --force --sign "$signing_identity" --options runtime "$helper_app"
codesign --verify --strict -R '=anchor apple generic and identifier "com.aloedawn.surflyrics.connectionhelper" and certificate leaf[subject.OU] = "2RDF6J3XVV"' "$helper_app"
printf '\nBuilt: %s\n' "$helper_app"
