# Development

## Build & Run

Open `SurfLyrics.xcodeproj` in Xcode 27. The `SurfLyrics` scheme builds the menu-bar app for macOS 27 on Apple Silicon with Hardened Runtime enabled (non-sandboxed, direct Apple Events and direct Spotify connection management).

## Icons

Edit `SurfLyrics/AppIcon.icon` in Icon Composer. It uses editable SVG layers and native Liquid Glass materials. Xcode compiles the icon into `SurfLyrics.app`. The PNG in `docs/assets/surflyrics.png` is a README preview, not a runtime asset.

## Architecture

### Playback & Scheduling
- `AppleEventClient` and `AppleEventPlayerProbe` query Spotify and Apple Music directly via `NSAppleEventDescriptor.sendEvent` (no `NSAppleScript` / OSA component loading). Synced playback polls use a 1-property position-only fast path (`pPos`), falling back to the 3-property fast path (`pPlS`, `pPos`, track key) on seek/drift, stall, or near end-of-track, and full metadata on track change or player events.
- `AppState` drives lyric line transitions with an in-memory `PlaybackClock` and `lyricTimer` (piggybacking a `pPos` check when `>= 1.5s` has elapsed since the last sync), while `syncTimer` handles ceiling drift/seek correction (`2.0s` playing with lyrics, `15s` paused/stopped/no-lyrics/podcasts).
- When no supported music player is running (`.noRunningPlayers`), `AppState` stops all periodic timers (zero wakeups) and wakes on `NSWorkspace` launch, termination, wake, and `DistributedNotificationCenter` playback events.

### Lyrics & Connection
- `LyricsService` applies `LyricsProvider` order (`spotifyClient` → `lrclib` → `musixmatch`), using `LyricsCache` across all providers (caching `.found` and confirmed `.notFound`, never `.transientFailure`). Manual reloads invalidate cached entries for the current track.
- `SpotifyClientConnection` prepares the local `127.0.0.1:43827` connection directly through `SpotifyConnectionLauncher` (validating loopback-only listening via `/usr/sbin/lsof`) and restores playback via direct Apple Events (`SpotifyPlaybackRestorer`).
- `SpotifyClientBridge.js` discovers Rspack/Webpack chunk runtimes by unique source signatures, caches the validated client privately via a non-enumerable `Symbol.for` entry on `globalThis`, and falls back to full discovery if the cached client becomes stale.
- `SpotifyClientLyricsClient` reuses `SpotifyClientEndpoint.sharedSession`, caches the validated WebSocket debugger URL, and invalidates/retries once on stale socket failures.
- `SharedRequest` coalesces concurrent Musixmatch token refreshes and Spotify metadata lookups.

## Checks

```sh
node --test scripts/spotify-client-bridge.test.mjs
bash -n scripts/package-app.sh scripts/render-cask.sh scripts/release.sh
xcodebuild test -project SurfLyrics.xcodeproj -scheme SurfLyrics -destination 'platform=macOS'
```

## Packaging & Release (GitHub / Homebrew)

```sh
# Local development-signed build check (no notarization):
SURFLYRICS_SIGNING_MODE=development bash scripts/package-app.sh

# Public Developer ID + Xcode notarized DMG (default):
bash scripts/package-app.sh

# Optional: notarize via notarytool keychain profile instead of Xcode upload:
SURFLYRICS_NOTARY_PROFILE="<keychain-profile>" bash scripts/package-app.sh

# Developer ID export without notarization:
SURFLYRICS_NOTARIZE_MODE=none bash scripts/package-app.sh

# Full release (tests, DMG, GitHub Release, aloedawn/homebrew-tap Cask update):
bash scripts/release.sh
```

`scripts/ExportOptions.plist` and `scripts/ExportOptionsNotarize.plist` use `method = developer-id`, `signingStyle = automatic`, and `teamID = 2RDF6J3XVV`. `SURFLYRICS_NOTARIZE_MODE` supports `xcode` (default for `developer-id`), `notarytool`, or `none`. `scripts/render-cask.sh` generates `Casks/surflyrics.rb` for `aloedawn/homebrew-tap` (`depends_on arch: :arm64`, `depends_on macos: :golden_gate`).
