# SurfLyrics

Personal macOS menu-bar app for displaying time-synced lyrics from the user's Spotify desktop client. Spotify client lyrics take priority; LRCLIB and Musixmatch remain optional fallback sources. This project is no longer intended as an App Store distribution workflow.

## Spotify desktop connection

The personal-use adapter runs a narrowly scoped request inside the signed-in Spotify client through a local Chrome DevTools Protocol connection. The Spotify session makes its normal lyrics request. Only the requested track ID, synchronization type, lyric lines and timestamps are returned to SurfLyrics. Spotify cookies and access tokens are not copied, stored or logged by the adapter.

The adapter is verified with **Spotify 1.2.99.317**. The module layout is version-dependent, so repeat the real client acceptance check below after updates. After incompatible Spotify updates, the adapter fails without displaying unverified lyrics.

The connection uses `127.0.0.1:43827`. SurfLyrics does not open this port, patch Spotify, change its preferences, or restart playback automatically. Enabling the debug connection allows other processes on the same Mac to access the Spotify session, so it must be an explicit local setup step. Do not expose the port to a network or use a wildcard remote origin.

After approval, completely quit Spotify and start it for this session with:

```sh
open -a Spotify --args --remote-debugging-address=127.0.0.1 --remote-debugging-port=43827
```

Verify with `lsof` that the listener is bound only to loopback; if it is not, quit Spotify immediately and do not use the connection. No persistent launch configuration is installed. To remove the connection, quit Spotify and reopen it normally, then verify that port 43827 is closed.

In SurfLyrics, enable **Spotify 클라이언트 우선 (개인용)** under **설정 → 가사 소스**, then select **현재 곡 가사 다시 조회**. **현재 표시** shows the same text and source used by the menu bar. Opening the running app again also opens Settings. The app keeps Spotify's timestamps, including timed blank lines, and does not invent synchronization for plain lyrics. The Spotify source can be disabled independently of the fallback providers.

## Verification

```sh
node --test scripts/spotify-client-bridge.test.mjs
xcodebuild test -project SurfLyrics.xcodeproj -scheme SurfLyrics -destination 'platform=macOS'
```

With the local client connection enabled, the diagnostic below evaluates the same bridge resource shipped in the app. It prints only status, track ID, synchronization type and timestamp counts. An optional second argument writes lyrics to a new file outside this repository, with owner-only permissions.

```sh
node scripts/spotify-client-probe.mjs 6vgarqZvEEzWUgCK45gCfz
```

Acceptance requires `found`, the requested Spotify ID, `LINE_SYNCED`, valid timestamps, and a visible comparison between Spotify and the running SurfLyrics app while the song plays. Also check seeking, pause/resume and changing tracks. Automated fixtures do not establish catalog-wide or 100% Spotify coverage.

## Current evidence (2026-09-12)

- Spotify visibly displayed Musixmatch lyrics for An da eun's “Faded Words” (`6vgarqZvEEzWUgCK45gCfz`).
- LRCLIB returned plain lyrics without timestamps. The existing Musixmatch desktop macro endpoint returned an unrelated track for the tested metadata and Spotify-ID requests.
- The installed Spotify track-page code uses its authenticated request builder and returns `lyrics.syncType` and `lyrics.lines`. The personal adapter follows that builder call. Live validation found that an empty `/image/` suffix returned 404; using `/track/{trackId}` successfully retrieved lyrics.
- The real client returned `LINE_SYNCED`, 28 ordered lines, first timestamp 16,520 ms and last timestamp 227,210 ms, including the final timed blank line.
- A signed Debug build displayed source **Spotify 클라이언트** through the app's real Swift transport. Its current-display preview matched Spotify at approximately 0:26 and 2:33. Seeking while paused to 2:00 changed both displays to the instrumental marker; the position remained fixed while paused, and lyrics advanced after resume.
- Switching from Saebit's “Melody of the Stars” (LRCLIB fallback) back to “Faded Words” selected the Spotify client source and replaced the previous track's lyrics. This is sampled evidence, not a claim of complete catalog coverage.
- No Spotify session credentials or real lyric payloads are committed. The temporary connection is session-only; the installed Spotify app and its persistent launch configuration are unchanged.

External App Store Connect and Xcode Cloud settings have not been changed. Any retirement of an existing cloud distribution workflow is a separate operational action.
