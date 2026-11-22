#!/bin/bash
set -euo pipefail

repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repository_dir/build}"
signing_mode="${SURFLYRICS_SIGNING_MODE:-developer-id}"
notary_profile="${SURFLYRICS_NOTARY_PROFILE:-}"
notarize="${SURFLYRICS_NOTARIZE:-0}"

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

archive_path="$output_dir/SurfLyrics.xcarchive"
export_dir="$output_dir/export"
app_path="$export_dir/SurfLyrics.app"

rm -rf "$archive_path" "$export_dir"
mkdir -p "$export_dir"

xcodebuild archive \
    -project "$repository_dir/SurfLyrics.xcodeproj" \
    -scheme SurfLyrics \
    -configuration Release \
    -archivePath "$archive_path" \
    -destination "generic/platform=macOS"

case "$signing_mode" in
    developer-id)
        xcodebuild -exportArchive \
            -archivePath "$archive_path" \
            -exportPath "$export_dir" \
            -exportOptionsPlist "$repository_dir/scripts/ExportOptions.plist" \
            -allowProvisioningUpdates
        ;;
    development)
        ditto "$archive_path/Products/Applications/SurfLyrics.app" "$app_path"
        ;;
    adhoc)
        ditto "$archive_path/Products/Applications/SurfLyrics.app" "$app_path"
        codesign --force --deep --sign - --options runtime "$app_path"
        ;;
    *)
        printf 'Unsupported SURFLYRICS_SIGNING_MODE: %s\n' "$signing_mode" >&2
        exit 1
        ;;
esac

codesign --verify --deep --strict --verbose=2 "$app_path"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
dmg_path="$output_dir/SurfLyrics-$version-macOS-arm64.dmg"
if [[ -e "$dmg_path" ]]; then
    printf 'Already exists: %s\nChoose an empty output directory or remove the existing DMG.\n' "$dmg_path" >&2
    exit 1
fi

staging_dir=$(mktemp -d "$output_dir/package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT

ditto "$app_path" "$staging_dir/SurfLyrics.app"
ln -s /Applications "$staging_dir/Applications"
cp "$repository_dir/LICENSE" "$staging_dir/LICENSE"

hdiutil create \
    -volname "SurfLyrics $version" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    -ov "$dmg_path"

notarized="no"
if [[ "$signing_mode" == "developer-id" ]] && [[ -n "$notary_profile" || "$notarize" == "1" ]]; then
    if [[ -z "$notary_profile" ]]; then
        printf 'Set SURFLYRICS_NOTARY_PROFILE (configured via xcrun notarytool store-credentials).\n' >&2
        exit 1
    fi
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
    notarized="yes"
fi

(cd "$output_dir" && shasum -a 256 "$(basename "$dmg_path")") > "$dmg_path.sha256"
sha256="$(awk '{print $1}' "$dmg_path.sha256")"

printf '\nApp: %s\nDMG: %s\nSHA256: %s\nSigning: %s\nNotarized: %s\n' \
    "$app_path" "$dmg_path" "$sha256" "$signing_mode" "$notarized"
