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

`SharedRequest` coalesces concurrent Musixmatch token refreshes and Spotify metadata lookups. Cancelling one caller leaves shared work running; cancelling the last caller cancels transport. Metadata results retain each caller's playback position and playing state, and late token rejections cannot invalidate a newer token.

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

## Spotify 1.3 compatibility — 2026-09-28

Spotify 1.3.0.277 renamed the chunk runtime to `rspackChunk` and changed the request-builder and lyrics-host module IDs to `48331` and `62192`. The old bridge returned `unsupported` while the local connection remained ready. The bridge now supports that adapter alongside the existing 1.2.99.317 adapter, validates the lyrics host, and continues to fail closed for unknown modules.

All 105 Swift tests and 7 bridge tests passed, and the signed Release build succeeded. Evaluating the updated bridge in the running Spotify 1.3.0.277 client returned 28 ordered `LINE_SYNCED` lines for the same “Faded Words” track used above. This verifies live retrieval; display validation of the distributed TestFlight build remains pending.

## Internal refactoring — 2026-10-01

Lyrics-loading transitions now use one explicit state and a shared reset path. Pending player notifications survive an older playback refresh, paused lyric reloads keep the three-second refresh interval, and invalid or overflowing LRC timestamps are rejected. Matching retains its scores and ambiguity rules while skipping redundant comparisons, checking rejection gates earlier, and reusing edit-distance buffers. Settings, menu layout, provider priority and instrumental-gap rendering are unchanged.

All 118 Swift tests and 7 bridge tests passed; shell syntax checks and a locally signed Release build also passed. A deterministic comparison against commit `9a776b8` produced identical results for 20,000 individual matches and 1,000 candidate batches. Three optimized-build runs of a synthetic 200-candidate workload took about 0.124 seconds each, compared with 0.264–0.274 seconds for the baseline. These timings measure matching work, not whole-app CPU or energy usage.

The local Release app reused the running Spotify connection. Its settings showed the Spotify client source and the instrumental icon, including after a lyric reload while Spotify was paused. This verifies the local build's display and reload path; the distributed TestFlight build and a fresh helper reconnection were not exercised in this run.

## Spotify 1.3.3 compatibility — 2026-10-02

Spotify 1.3.3.264 keeps `rspackChunk` but changes the request-builder and lyrics-host module IDs to `95096` and `62037`. The installed bridge returned `unsupported` despite an open local connection. A new adapter restores retrieval while retaining the two older adapters and the lyrics-host validation.

All 8 bridge tests and a signed Release build passed. The updated bridge returned 28 ordered `LINE_SYNCED` lines for the same “Faded Words” baseline. The rebuilt local app showed **Spotify 클라이언트** as its source, including after a lyrics reload. The root-owned TestFlight installation in `/Applications` could not be replaced without administrator authentication and remains unchanged; the rebuilt app is running from the ignored build directory. No App Store Connect settings were changed or Cloud build manually started.

These IDs identify private modules in Spotify's bundled JavaScript, rather than a stable public interface. Rebuilding Spotify can renumber them even when the lyrics endpoint remains unchanged. Unknown modules deliberately return `unsupported`; the app then tries the other enabled providers. Passing fixture tests does not establish compatibility with a future Spotify build, so each new adapter also needs live-client verification.

## Automatic client discovery — 2026-10-02

The bridge now discovers Rspack/Webpack chunk runtimes and inspects their registered factory source without executing unrelated modules. It requires unique source matches for the client singleton and lyrics-host module, validates their exported capabilities and the exact Spotify lyrics host, and checks the full request-builder interface before sending. Module IDs and export names may change without requiring a new adapter. Inspection and payload sizes are bounded; ambiguous candidates, incompatible interfaces and malformed timed lines fail closed to the existing provider fallback. Authentication stays inside Spotify.

All 18 bridge tests and 118 Swift tests passed. Tests cover arbitrary module renumbering, renamed exports and runtimes, unrelated modules, ambiguous matches, incomplete builders, throwing getters, inspection limits and malformed payloads. A signed Release build of **1.1.4 (26100201)** passed. Automatic discovery in Spotify 1.3.3.264 returned 28 synchronized lines for the baseline track; the rebuilt app selected **Spotify 클라이언트** as its source. Changes to runtime structure, singleton methods, the lyrics endpoint or response schema can still require a bridge update. Future-client compatibility is not guaranteed by synthetic renumbering tests.
