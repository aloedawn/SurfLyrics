# Development

## Build

Open `SurfLyrics.xcodeproj` in Xcode 27. The `SurfLyrics` scheme builds the sandboxed menu-bar app. The deployment target is macOS 27 on Apple Silicon.

The helper is deliberately a separate build, outside the TestFlight archive:

```sh
bash scripts/build-connection-helper.sh
bash scripts/package-helper.sh
```

`SURFLYRICS_SIGNING_IDENTITY` selects a local certificate. The helper's signature must match bundle ID `com.aloedawn.surflyrics.connectionhelper` and team `2RDF6J3XVV`; the build script checks the same requirement as the main app. A fork with another signing team must change `SpotifyConnectionHelperIdentity` and the build script together.

## Icons

Edit `SurfLyrics/AppIcon.icon` and `SpotifyConnectionHelper/HelperIcon.icon` in Icon Composer. Both use editable SVG layers and native Liquid Glass materials. Xcode compiles the main icon; the helper script compiles its icon with `actool`. The PNGs in `docs/assets` are README previews, not runtime assets.

## Lyrics and connection

`LyricsService` applies `LyricsProvider` order and delegates transport to each provider. `LyricsCache` coalesces requests and owns expiration/cancellation; `LyricsPayloadDecoder` and `LyricsCandidateMatcher` validate responses. `StatusTextFormatter` maps timed instrumental markers to the idle music icon.

`SpotifyClientConnection` coalesces setup, handles cooldown and restores playback when the same track survives a restart. The separate helper launches Spotify with a fixed loopback connection, validates the listener, and exits. `SpotifyClientEndpoint` restricts target discovery and WebSocket addresses. The bridge returns only the requested track ID, synchronization type, timestamps and lyric lines. Do not log CDP responses, session objects, credentials or real lyrics.

A freshly launched Spotify page can appear before its authenticated lyrics client is ready. Transient bridge failures have a bounded warmup retry; confirmed missing or unsynced lyrics immediately fall through to the next provider.

## Checks

```sh
xcodebuild test -project SurfLyrics.xcodeproj -scheme SurfLyrics -destination 'platform=macOS'
node --test scripts/spotify-client-bridge.test.mjs
bash -n scripts/build-connection-helper.sh scripts/package-helper.sh
```

The retained tests cover timing, matching, source priority, cancellation, stale results, connection coalescing, startup failures and loopback validation. They use synthetic lyrics. Tests are not shipped inside the app or helper installer.

After Spotify updates, also check the real app: start Spotify normally, launch SurfLyrics, confirm automatic reconnection and source **Spotify 클라이언트**, then seek, pause/resume, switch tracks and check an instrumental gap. Automated fixtures cannot establish catalog-wide coverage.

## Verified baseline — 2026-09-12

The final project passes 105 Swift tests and 4 bridge tests. Both Icon Composer files compile into their app bundles. The helper DMG was mounted read-only and its packaged app signature and system-library dependencies were verified.

Spotify 1.2.99.317 returned 28 ordered `LINE_SYNCED` lines for An da eun's “Faded Words” (Spotify ID `6vgarqZvEEzWUgCK45gCfz`), where LRCLIB had only plain lyrics. The app's source and visible text matched Spotify. Seeking to 2:00 showed the same large music-note icon as the idle state.

A locally signed, sandboxed Release app launched the installed helper from `/Applications`, restarted a normally launched Spotify process, and displayed Spotify lyrics without a manual retry. The listener bound only to `127.0.0.1:43827`; the helper exited after setup. Subsequent track changes selected Spotify client lyrics automatically. This is local Release validation, not a downloaded TestFlight build or a second-Mac acceptance test.

## Xcode Cloud

The shared `SurfLyrics` scheme remains the TestFlight target. App Store Connect settings and Cloud build numbers are separate from `CURRENT_PROJECT_VERSION`; follow `AGENTS.md` before an explicit distribution run. Ordinary source pushes do not package or publish the helper.
