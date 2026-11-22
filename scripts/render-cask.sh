#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: %s <version> <sha256> [output_path]\n' "$0" >&2
    exit 1
fi

version="$1"
sha256="$2"
output_path="${3:-}"

rendered=$(cat <<EOF
cask "surflyrics" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/aloedawn/SurfLyrics/releases/download/v#{version}/SurfLyrics-#{version}-macOS-arm64.dmg"
  name "SurfLyrics"
  desc "Menu bar synchronized lyrics for Spotify and Apple Music"
  homepage "https://github.com/aloedawn/SurfLyrics"

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "SurfLyrics.app"

  zap trash: "~/Library/Preferences/com.aloedawn.surflyrics.plist"
end
EOF
)

if [[ -n "$output_path" ]]; then
    mkdir -p "$(dirname "$output_path")"
    printf '%s\n' "$rendered" > "$output_path"
else
    printf '%s\n' "$rendered"
fi
