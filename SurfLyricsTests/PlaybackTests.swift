import AppKit
import CoreServices
import XCTest
@testable import SurfLyrics

@MainActor
final class PlaybackTests: XCTestCase {
    func testAppleEventClientEncodesFourCharCodesAndDecodesReplyErrors() {
        XCTAssertEqual(AppleEventClient.fourCharCode("getd"), OSType(kAEGetData))
        XCTAssertEqual(AppleEventClient.fourCharCode("setd"), OSType(kAESetData))
        XCTAssertNotNil(AppleEventClient.propertySpecifier(property: AppleEventClient.playerStateProperty))

        let successReply = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer),
            targetDescriptor: .null(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        successReply.setDescriptor(NSAppleEventDescriptor(string: "Track"), forKeyword: AEKeyword(keyDirectObject))
        if case let .success(descriptor) = AppleEventClient.decodeReply(successReply) {
            XCTAssertEqual(descriptor.stringValue, "Track")
        } else {
            XCTFail("Expected success reply")
        }

        let deniedReply = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer),
            targetDescriptor: .null(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        deniedReply.setDescriptor(NSAppleEventDescriptor(int32: -1743), forKeyword: AEKeyword(keyErrorNumber))
        XCTAssertEqual(
            AppleEventClient.decodeReply(deniedReply),
            .failure(.permissionDenied(-1743))
        )

        let missingReply = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer),
            targetDescriptor: .null(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        missingReply.setDescriptor(NSAppleEventDescriptor(int32: -1728), forKeyword: AEKeyword(keyErrorNumber))
        XCTAssertEqual(
            AppleEventClient.decodeReply(missingReply),
            .failure(.targetUnavailable(-1728))
        )
    }

    func testAppleEventProbeWorkerUsesFastPathCacheAndInvalidatesOnChangeOrStop() async {
        let sender = FakeAppleEventSender()
        sender.appReplies[AppleEventClient.playerStateProperty] = .success(
            NSAppleEventDescriptor(enumCode: AppleEventClient.playingEnum)
        )
        sender.appReplies[AppleEventClient.playerPositionProperty] = .success(
            NSAppleEventDescriptor(double: 12.5)
        )
        sender.trackReplies[AppleEventClient.trackIDProperty] = .success(
            NSAppleEventDescriptor(string: "spotify:track:AbC123xYz")
        )
        sender.trackReplies[AppleEventClient.trackNameProperty] = .success(
            NSAppleEventDescriptor(string: "Track One")
        )
        sender.trackReplies[AppleEventClient.trackArtistProperty] = .success(
            NSAppleEventDescriptor(string: "Artist One")
        )
        sender.trackReplies[AppleEventClient.trackAlbumProperty] = .success(
            NSAppleEventDescriptor(string: "Album One")
        )
        sender.trackReplies[AppleEventClient.trackDurationProperty] = .success(
            NSAppleEventDescriptor(int32: 180_000)
        )
        sender.trackReplies[AppleEventClient.spotifyURLProperty] = .success(
            NSAppleEventDescriptor(string: "https://open.spotify.com/track/AbC123xYz")
        )

        let worker = AppleEventProbeWorker(sender: sender)

        let first = await worker.probe(player: .spotify, pid: 100, forceFullMetadata: true)
        guard case let .track(firstTrack) = first else { return XCTFail("Expected track") }
        XCTAssertEqual(firstTrack.name, "Track One")
        XCTAssertEqual(firstTrack.progressMs, 12_500)
        XCTAssertEqual(sender.recordedProperties.count, 8)

        sender.recordedProperties.removeAll()
        sender.appReplies[AppleEventClient.playerPositionProperty] = .success(
            NSAppleEventDescriptor(double: 20.0)
        )
        let fast = await worker.probe(player: .spotify, pid: 100, forceFullMetadata: false)
        guard case let .track(fastTrack) = fast else { return XCTFail("Expected fast-path track") }
        XCTAssertEqual(fastTrack.name, "Track One")
        XCTAssertEqual(fastTrack.progressMs, 20_000)
        XCTAssertEqual(sender.recordedProperties, [
            AppleEventClient.playerStateProperty,
            AppleEventClient.playerPositionProperty,
            AppleEventClient.trackIDProperty,
        ])

        sender.recordedProperties.removeAll()
        sender.trackReplies[AppleEventClient.trackIDProperty] = .success(
            NSAppleEventDescriptor(string: "spotify:track:ZyX987AbC")
        )
        sender.trackReplies[AppleEventClient.spotifyURLProperty] = .success(
            NSAppleEventDescriptor(string: "")
        )
        sender.trackReplies[AppleEventClient.trackNameProperty] = .success(
            NSAppleEventDescriptor(string: "Track Two")
        )
        let changed = await worker.probe(player: .spotify, pid: 100, forceFullMetadata: false)
        guard case let .track(changedTrack) = changed else { return XCTFail("Expected changed track") }
        XCTAssertEqual(changedTrack.name, "Track Two")
        XCTAssertEqual(changedTrack.sourceTrackID, "ZyX987AbC")
        XCTAssertEqual(sender.recordedProperties.count, 8)

        sender.appReplies[AppleEventClient.playerStateProperty] = .success(
            NSAppleEventDescriptor(enumCode: AppleEventClient.stoppedEnum)
        )
        let stopped = await worker.probe(player: .spotify, pid: 100, forceFullMetadata: false)
        guard case .inactive = stopped else { return XCTFail("Expected inactive when stopped") }

        sender.recordedProperties.removeAll()
        sender.appReplies[AppleEventClient.playerStateProperty] = .success(
            NSAppleEventDescriptor(enumCode: AppleEventClient.playingEnum)
        )
        let afterStop = await worker.probe(player: .spotify, pid: 100, forceFullMetadata: false)
        guard case .track = afterStop else { return XCTFail("Expected full probe after stop invalidates cache") }
        XCTAssertEqual(sender.recordedProperties.count, 8)
    }

    func testAppleEventProbeWorkerMapsErrorsAndAppleMusicUnits() async {
        let sender = FakeAppleEventSender()
        sender.appReplies[AppleEventClient.playerStateProperty] = .failure(.permissionDenied(-1743))
        let worker = AppleEventProbeWorker(sender: sender)

        let denied = await worker.probe(player: .appleMusic, pid: 200, forceFullMetadata: true)
        guard case .permissionDenied = denied else { return XCTFail("Expected permissionDenied") }

        sender.appReplies[AppleEventClient.playerStateProperty] = .success(
            NSAppleEventDescriptor(enumCode: AppleEventClient.pausedEnum)
        )
        sender.appReplies[AppleEventClient.playerPositionProperty] = .success(
            NSAppleEventDescriptor(double: 12.5)
        )
        sender.trackReplies[AppleEventClient.persistentIDProperty] = .success(
            NSAppleEventDescriptor(string: "HEX1234")
        )
        sender.trackReplies[AppleEventClient.trackNameProperty] = .success(
            NSAppleEventDescriptor(string: "Apple Track")
        )
        sender.trackReplies[AppleEventClient.trackArtistProperty] = .success(
            NSAppleEventDescriptor(string: "Apple Artist")
        )
        sender.trackReplies[AppleEventClient.trackAlbumProperty] = .success(
            NSAppleEventDescriptor(string: "Apple Album")
        )
        sender.trackReplies[AppleEventClient.trackDurationProperty] = .success(
            NSAppleEventDescriptor(double: 180.5)
        )

        let appleResult = await worker.probe(player: .appleMusic, pid: 200, forceFullMetadata: true)
        guard case let .track(appleTrack) = appleResult else { return XCTFail("Expected Apple Music track") }
        XCTAssertNil(appleTrack.sourceTrackID)
        XCTAssertEqual(appleTrack.durationMs, 180_500)
        XCTAssertEqual(appleTrack.progressMs, 12_500)
        XCTAssertFalse(appleTrack.isPlaying)
    }

    func testTrackIdentityPrefersStableSourceIDOverLocalizedMetadata() {
        let localizedTrack = makeTrack(
            source: .spotify,
            isPlaying: true,
            sourceTrackID: "  AbC123xYz  ",
            name: "현지화된 제목",
            artist: "현지화된 가수",
            album: "현지화된 앨범"
        )
        let canonicalTrack = makeTrack(
            source: .spotify,
            isPlaying: true,
            sourceTrackID: "AbC123xYz",
            name: "Canonical Title",
            artist: "Canonical Artist",
            album: "Canonical Album"
        )
        let otherSourceTrack = makeTrack(
            source: .appleMusic,
            isPlaying: true,
            sourceTrackID: "AbC123xYz",
            name: "Canonical Title",
            artist: "Canonical Artist",
            album: "Canonical Album"
        )

        XCTAssertEqual(localizedTrack.identity, canonicalTrack.identity)
        XCTAssertNotEqual(localizedTrack.identity, otherSourceTrack.identity)
    }

    func testTrackIdentityFallsBackToMetadataForMissingOrBlankSourceID() {
        let missingID = makeTrack(source: .spotify, isPlaying: true)
        let blankID = makeTrack(
            source: .spotify,
            isPlaying: true,
            sourceTrackID: " \n "
        )

        XCTAssertEqual(missingID.identity, blankID.identity)
        XCTAssertEqual(
            missingID.identity,
            .metadata(
                source: .spotify,
                itemKind: .track,
                name: "Track",
                artist: "Artist",
                album: "Album",
                durationMs: 180_000
            )
        )
    }

    func testSpotifyTrackIdentityNormalizesTrackURIWithoutChangingIDCase() {
        let identity = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:track:AbC123xYz",
            rawURL: ""
        )

        XCTAssertEqual(identity.trackID, "AbC123xYz")
        XCTAssertEqual(identity.itemKind, .track)
    }

    func testSpotifyTrackIdentityFallsBackToTrackURLAndRejectsNonTrackIdentifiers() {
        let track = SpotifyTrackIdentityParser.parse(
            rawID: "ZyX987AbC",
            rawURL: "https://open.spotify.com/intl-ko/track/ZyX987AbC?si=share"
        )
        let episode = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:episode:Episode123",
            rawURL: "https://open.spotify.com/episode/Episode123"
        )

        XCTAssertEqual(track.trackID, "ZyX987AbC")
        XCTAssertEqual(track.itemKind, .track)
        XCTAssertNil(episode.trackID)
        XCTAssertEqual(episode.itemKind, .episode)
    }

    func testSpotifyTrackIdentityClassifiesLocalTracksAndAdvertisements() {
        let localTrack = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:local:Artist:Album:Track:180",
            rawURL: "spotify:local:Artist:Album:Track:180"
        )
        let advertisement = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:ad:Advertisement123",
            rawURL: ""
        )

        XCTAssertEqual(localTrack.itemKind, .localTrack)
        XCTAssertTrue(localTrack.itemKind.supportsLyricsLookup)
        XCTAssertEqual(advertisement.itemKind, .advertisement)
        XCTAssertFalse(advertisement.itemKind.supportsLyricsLookup)
    }

    func testSpotifyTrackIdentityRejectsMalformedOrConflictingLocalTracks() {
        let malformedTrack = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:local:Artist:Album",
            rawURL: ""
        )
        let conflictingTrack = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:local:Artist:Album:Track:180",
            rawURL: "spotify:local:Artist:Album:Other:180"
        )

        XCTAssertFalse(malformedTrack.itemKind.supportsLyricsLookup)
        XCTAssertFalse(conflictingTrack.itemKind.supportsLyricsLookup)
    }

    func testSpotifyTrackIdentityRejectsBareIDAndConflictingTypedIdentities() {
        let bareID = SpotifyTrackIdentityParser.parse(rawID: "UnTypedBareID123", rawURL: "")
        let conflictingType = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:track:Track123",
            rawURL: "spotify:episode:Episode123"
        )
        let conflictingTrack = SpotifyTrackIdentityParser.parse(
            rawID: "spotify:track:Track123",
            rawURL: "https://open.spotify.com/track/OtherTrack456"
        )
        let conflictingBare = SpotifyTrackIdentityParser.parse(
            rawID: "Track123",
            rawURL: "https://open.spotify.com/track/OtherTrack456"
        )
        let bareEpisode = SpotifyTrackIdentityParser.parse(
            rawID: "0zLhl3WsOCQHbe1BPTiHgr",
            rawURL: "spotify:episode:0zLhl3WsOCQHbe1BPTiHgr"
        )
        let nestedTrackPath = SpotifyTrackIdentityParser.parse(
            rawID: "",
            rawURL: "https://open.spotify.com/embed/track/Track123"
        )

        XCTAssertNil(bareID.trackID)
        XCTAssertFalse(bareID.itemKind.supportsLyricsLookup)
        XCTAssertNil(conflictingType.trackID)
        XCTAssertNil(conflictingTrack.trackID)
        XCTAssertNil(conflictingBare.trackID)
        XCTAssertNil(bareEpisode.trackID)
        XCTAssertNil(nestedTrackPath.trackID)
    }

    func testPreferredPlayingPlayerShortCircuitsOtherProbe() async {
        let probe = StubPlayerProbe(
            running: [.spotify, .appleMusic],
            results: [
                .appleMusic: .track(makeTrack(source: .appleMusic, isPlaying: true)),
                .spotify: .track(makeTrack(source: .spotify, isPlaying: true)),
            ]
        )
        let client = MusicPlaybackClient(playerProbe: probe)

        let result = await client.getCurrentTrack(preferredPlayer: .appleMusic)

        XCTAssertEqual(result.track?.source, .appleMusic)
        XCTAssertEqual(probe.calls, [.appleMusic])
    }

    func testPausedPreferredPlayerFallsBackToPlayingPlayer() async {
        let probe = StubPlayerProbe(
            running: [.spotify, .appleMusic],
            results: [
                .appleMusic: .track(makeTrack(source: .appleMusic, isPlaying: false)),
                .spotify: .track(makeTrack(source: .spotify, isPlaying: true)),
            ]
        )
        let client = MusicPlaybackClient(playerProbe: probe)

        let result = await client.getCurrentTrack(preferredPlayer: .appleMusic)

        XCTAssertEqual(result.track?.source, .spotify)
        XCTAssertEqual(probe.calls, [.appleMusic, .spotify])
    }

    func testUnavailablePreferredPlayerFallsBackToPlayingPlayer() async {
        let probe = StubPlayerProbe(
            running: [.spotify, .appleMusic],
            results: [
                .appleMusic: .inactive,
                .spotify: .track(makeTrack(source: .spotify, isPlaying: true)),
            ]
        )
        let client = MusicPlaybackClient(playerProbe: probe)

        let result = await client.getCurrentTrack(preferredPlayer: .appleMusic)

        XCTAssertEqual(result.track?.source, .spotify)
        XCTAssertEqual(probe.calls, [.appleMusic, .spotify])
    }

    func testRefreshRequestsCoalesceIntoOneTrailingRefresh() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        let initialRefreshStarted = await eventually { manager.playbackCallCount == 1 }
        XCTAssertTrue(initialRefreshStarted)

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        state.requestPlaybackRefresh(preferredPlayer: .appleMusic)
        state.requestPlaybackRefresh(preferredPlayer: .appleMusic)
        XCTAssertEqual(manager.playbackCallCount, 1)

        manager.resolveNextPlayback(with: .init(track: nil, issue: .noRunningPlayers))
        let trailingRefreshStarted = await eventually { manager.playbackCallCount == 2 }
        XCTAssertTrue(trailingRefreshStarted)
        XCTAssertEqual(manager.preferredPlayers, [nil, .appleMusic])

        manager.resolveNextPlayback(with: .init(track: nil, issue: .noRunningPlayers))
        let trailingRefreshFinished = await eventually { manager.pendingPlaybackCount == 0 }
        XCTAssertTrue(trailingRefreshFinished)
        XCTAssertEqual(manager.playbackCallCount, 2)
    }

    func testShutdownCancelsRefreshAndRejectsLaterRequests() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        let refreshStarted = await eventually { manager.playbackCallCount == 1 }
        XCTAssertTrue(refreshStarted)

        state.shutdown()
        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        manager.resolveNextPlayback(with: .init(track: nil, issue: .noRunningPlayers))
        let refreshFinished = await eventually { manager.pendingPlaybackCount == 0 }

        XCTAssertTrue(refreshFinished)
        XCTAssertEqual(manager.playbackCallCount, 1)
        XCTAssertEqual(state.statusText, "")
    }

    func testPlayingRefreshCannotOverwriteNewerPlayerNotification() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }
        _ = await eventually { manager.playbackCallCount == 1 }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        state.requestPlaybackRefresh(preferredPlayer: .appleMusic)
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true), issue: nil
        ))
        let trailingStarted = await eventually { manager.playbackCallCount == 2 }
        XCTAssertTrue(trailingStarted)
        XCTAssertEqual(manager.preferredPlayers, [nil, .appleMusic])
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .appleMusic, isPlaying: true), issue: nil
        ))
        _ = await eventually { state.sourceText == "재생 앱: Apple Music" }
        XCTAssertEqual(state.sourceText, "재생 앱: Apple Music")
    }

    func testPausedTrackChangeAndSourceReloadInvalidateCacheAndKeepInactiveCadence() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }
        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true, name: "First"), issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(forTrackNamed: "First", with: (
            Lyrics(lines: [LyricsLine(timeMs: 0, text: "First line")]), "First source"
        ))
        _ = await eventually { state.statusText == "First line" }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: false, name: "Second"), issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        XCTAssertEqual(state.statusText, "♫ Second — Artist")
        XCTAssertEqual(state.sourceText, "재생 앱: Spotify")
        manager.resolveLyrics(forTrackNamed: "Second", with: (
            Lyrics(lines: [LyricsLine(timeMs: 0, text: "Second line")]), "Second source"
        ))
        _ = await eventually { state.statusText == "Second line" }

        NotificationCenter.default.post(name: .settingsLyricsSourcesChanged, object: nil)
        _ = await eventually { manager.lyricsCallCount == 1 }
        XCTAssertEqual(manager.invalidatedTracks.count, 1)
        XCTAssertEqual(state.statusText, "♫ Second — Artist")
        XCTAssertEqual(state.sourceText, "재생 앱: Spotify")
        manager.resolveLyrics(forTrackNamed: "Second", with: (
            Lyrics(lines: [LyricsLine(timeMs: 0, text: "Reloaded line")]), "Reloaded source"
        ))
        _ = await eventually { state.statusText == "Reloaded line" }
        XCTAssertEqual(state.statusText, "Reloaded line")
        XCTAssertEqual(state.scheduledSyncInterval, 15.0)
        XCTAssertNil(state.scheduledLyricDate)
        XCTAssertEqual(manager.playbackCallCount, 2)
    }

    func testStaleLyricsCompletionCannotOverwriteNewTrack() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true, name: "Old Track"),
            issue: nil
        ))
        let oldLookupStarted = await eventually { manager.lyricsCallCount == 1 }
        XCTAssertTrue(oldLookupStarted)

        state.requestPlaybackRefresh(preferredPlayer: .appleMusic)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .appleMusic, isPlaying: true, name: "New Track"),
            issue: nil
        ))
        let newLookupStarted = await eventually { manager.lyricsCallCount == 1 }
        XCTAssertTrue(newLookupStarted)

        for _ in 0..<10 { await Task.yield() }
        XCTAssertNotEqual(state.statusText, "Stale lyric")

        manager.resolveLyrics(
            forTrackNamed: "New Track",
            with: (Lyrics(lines: [LyricsLine(timeMs: 0, text: "Fresh lyric")]), "Test")
        )
        let freshLyricsDisplayed = await eventually { state.statusText == "Fresh lyric" }
        XCTAssertTrue(freshLyricsDisplayed)
    }

    func testLyricsCompletionDoesNotPostponeExistingSyncRefresh() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        guard let originalSyncDate = state.scheduledSyncDate else {
            return XCTFail("Expected the initial sync timer to be scheduled")
        }

        manager.resolveLyrics(
            forTrackNamed: "Track",
            with: (Lyrics(lines: [
                LyricsLine(timeMs: 1_000, text: "Now"),
                LyricsLine(timeMs: 2_000, text: "Next"),
            ]), "Test")
        )

        let lyricsDisplayed = await eventually { state.statusText == "Now" }
        XCTAssertTrue(lyricsDisplayed)
        XCTAssertEqual(state.scheduledSyncDate, originalSyncDate)
    }

    func testScheduledLyricTimerAdvancesDisplayWithoutPlaybackIPC() async {
        let manager = ControlledMusicManager()
        var now: TimeInterval = 100.0
        let state = AppState(musicManager: manager, monotonicTime: { now })
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(
            forTrackNamed: "Track",
            with: (Lyrics(lines: [
                LyricsLine(timeMs: 1_000, text: "Now"),
                LyricsLine(timeMs: 2_000, text: "Next"),
            ]), "Test")
        )
        _ = await eventually { state.statusText == "Now" }
        XCTAssertEqual(state.scheduledLyricInterval ?? -1, 1.0, accuracy: 0.001)

        now = 101.0
        state.fireScheduledLyricUpdateForTesting()

        XCTAssertEqual(state.statusText, "Next")
        XCTAssertEqual(manager.playbackCallCount, 1)
        XCTAssertNil(state.scheduledLyricDate)

        state.fireScheduledSyncForTesting()
        let syncStarted = await eventually { manager.playbackCallCount == 2 }
        XCTAssertTrue(syncStarted)
        XCTAssertEqual(manager.forceFullMetadataFlags, [true, false])
    }

    func testIntroSchedulesLyricTimerAndAccountsForFetchElapsedTime() async {
        let manager = ControlledMusicManager()
        var now: TimeInterval = 50.0
        let state = AppState(musicManager: manager, monotonicTime: { now })
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true, progressMs: 500),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }

        now = 50.5
        manager.resolveLyrics(
            forTrackNamed: "Track",
            with: (Lyrics(lines: [
                LyricsLine(timeMs: 2_500, text: "First line"),
            ]), "Test")
        )

        let scheduled = await eventually { state.scheduledLyricDate != nil }
        XCTAssertTrue(scheduled)
        XCTAssertEqual(state.statusText, "♫ Track — Artist")
        XCTAssertEqual(state.scheduledLyricInterval ?? -1, 1.5, accuracy: 0.001)

        now = 52.0
        state.fireScheduledLyricUpdateForTesting()
        XCTAssertEqual(state.statusText, "First line")
        XCTAssertEqual(manager.playbackCallCount, 1)
    }

    func testLocalizedMissRetriesChangedMetadataForSameSourceID() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "현지화된 제목",
                artist: "현지화된 가수"
            ),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(forTrackNamed: "현지화된 제목", with: (nil, nil))
        _ = await eventually { state.scheduledSyncInterval == 15.0 }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "Canonical Title",
                artist: "Canonical Artist"
            ),
            issue: nil
        ))
        let metadataUpdated = await eventually { state.statusText.contains("Canonical Title") }
        let canonicalLookupStarted = await eventually { manager.lyricsCallCount == 1 }

        XCTAssertTrue(metadataUpdated)
        XCTAssertTrue(canonicalLookupStarted)

        manager.resolveLyrics(
            forTrackNamed: "Canonical Title",
            with: (Lyrics(lines: [LyricsLine(timeMs: 0, text: "Recovered")]), "Test")
        )
        let recoveredLyricsDisplayed = await eventually { state.statusText == "Recovered" }
        XCTAssertTrue(recoveredLyricsDisplayed)
    }

    func testSuccessfulLyricsStayLoadedAcrossMetadataChangeForSameSourceID() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "Localized Title"
            ),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(
            forTrackNamed: "Localized Title",
            with: (Lyrics(lines: [LyricsLine(timeMs: 0, text: "Found")]), "Test")
        )
        _ = await eventually { state.statusText == "Found" }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "Canonical Title"
            ),
            issue: nil
        ))
        let playbackFinished = await eventually { manager.pendingPlaybackCount == 0 }

        XCTAssertTrue(playbackFinished)
        XCTAssertEqual(state.statusText, "Found")
        XCTAssertEqual(manager.lyricsCallCount, 0)
    }

    func testEpisodePlaybackDoesNotStartLyricsLookupAndUsesSlowSyncCadence() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                itemKind: .episode,
                name: "Podcast Episode",
                durationMs: 1_800_000
            ),
            issue: nil
        ))
        let playbackFinished = await eventually { manager.pendingPlaybackCount == 0 }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(playbackFinished)
        XCTAssertEqual(manager.lyricsCallCount, 0)
        XCTAssertEqual(state.scheduledSyncInterval, 15.0)
        XCTAssertEqual(state.scheduledSyncTolerance ?? -1, 2.0, accuracy: 0.001)
        XCTAssertNil(state.scheduledLyricDate)
    }

    func testEpisodeTransitionCancelsPreviousTrackLyricsLookup() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true, name: "Track A"),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                itemKind: .episode,
                name: "Podcast"
            ),
            issue: nil
        ))
        let pendingLyricsCancelled = await eventually { manager.lyricsCallCount == 0 }

        XCTAssertTrue(pendingLyricsCancelled)
    }

    func testStartingWhilePausedFetchesLyricsWithoutResumingPlayback() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }
        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(track: makeTrack(source: .spotify, isPlaying: false), issue: nil))
        let lookupStarted = await eventually { manager.lyricsCallCount == 1 }
        XCTAssertTrue(lookupStarted)
        manager.resolveLyrics(forTrackNamed: "Track", with: (
            Lyrics(lines: [LyricsLine(timeMs: 0, text: "Paused line")]), "Spotify 클라이언트"
        ))
        let displayed = await eventually { state.statusText == "Paused line" }
        XCTAssertTrue(displayed)
        XCTAssertEqual(state.scheduledSyncInterval, 15.0)
        XCTAssertNil(state.scheduledLyricDate)
    }

    func testInstrumentalGapUsesIdleIconAndSeekingRestoresLyrics() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }
        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(track: makeTrack(source: .spotify, isPlaying: true), issue: nil))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(forTrackNamed: "Track", with: (Lyrics(lines: [
            LyricsLine(timeMs: 1_000, text: "♪"),
            LyricsLine(timeMs: 2_000, text: "Voice resumes"),
        ]), "Spotify 클라이언트"))
        let gapDisplayed = await eventually { state.statusText == "" && state.sourceText?.contains("Spotify 클라이언트") == true }
        XCTAssertTrue(gapDisplayed)
        XCTAssertEqual(state.scheduledLyricInterval ?? -1, 1.0, accuracy: 0.05)
        XCTAssertEqual(state.scheduledSyncInterval, 5.0)

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        let soughtTrack = MusicTrack(source: .spotify, name: "Track", artist: "Artist", album: "Album",
            durationMs: 180_000, progressMs: 3_000, isPlaying: false)
        manager.resolveNextPlayback(with: .init(track: soughtTrack, issue: nil))
        let voiceDisplayed = await eventually { state.statusText == "Voice resumes" }
        XCTAssertTrue(voiceDisplayed)
        XCTAssertEqual(state.sourceText, "재생 앱: Spotify\n가사 소스: Spotify 클라이언트")
    }

    func testZeroWakeupIdleMissingLyricsSyncedLyricsAndEndOfTrackCadence() async {
        let workspaceCenter = NotificationCenter()
        let idleManager = ControlledMusicManager()
        let idleState = AppState(
            musicManager: idleManager,
            workspaceNotificationCenter: workspaceCenter
        )
        _ = await eventually { idleManager.playbackCallCount == 1 }
        idleManager.resolveNextPlayback(with: .init(track: nil, issue: .noRunningPlayers))
        let settled = await eventually { idleManager.pendingPlaybackCount == 0 }
        XCTAssertTrue(settled)
        XCTAssertEqual(idleState.statusText, "")
        XCTAssertNil(idleState.scheduledSyncDate)
        XCTAssertNil(idleState.scheduledLyricDate)

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        let wakeRefreshed = await eventually { idleManager.playbackCallCount == 2 }
        XCTAssertTrue(wakeRefreshed)
        idleManager.resolveNextPlayback(with: .init(track: nil, issue: .unavailable("stopped")))
        let stoppedScheduled = await eventually { idleState.scheduledSyncInterval == 15.0 }
        XCTAssertTrue(stoppedScheduled)
        XCTAssertEqual(idleState.scheduledSyncTolerance ?? -1, 5.0, accuracy: 0.001)
        idleState.shutdown()

        let missingManager = ControlledMusicManager()
        let missingState = AppState(musicManager: missingManager)
        _ = await eventually { missingManager.playbackCallCount == 1 }
        missingManager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { missingManager.lyricsCallCount == 1 }
        missingManager.resolveLyrics(forTrackNamed: "Track", with: (nil, nil))
        let missingScheduled = await eventually { missingState.scheduledSyncInterval == 15.0 }
        XCTAssertTrue(missingScheduled)
        XCTAssertEqual(missingState.scheduledSyncTolerance ?? -1, 2.0, accuracy: 0.001)
        XCTAssertNil(missingState.scheduledLyricDate)
        missingState.shutdown()

        let syncedManager = ControlledMusicManager()
        let syncedState = AppState(musicManager: syncedManager)
        _ = await eventually { syncedManager.playbackCallCount == 1 }
        syncedManager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { syncedManager.lyricsCallCount == 1 }
        syncedManager.resolveLyrics(
            forTrackNamed: "Track",
            with: (Lyrics(lines: [
                LyricsLine(timeMs: 1_000, text: "Now"),
                LyricsLine(timeMs: 1_500, text: "Next"),
            ]), "Test")
        )
        let lyricScheduled = await eventually { syncedState.scheduledLyricInterval == 0.5 }
        XCTAssertTrue(lyricScheduled)
        XCTAssertEqual(syncedState.scheduledLyricTolerance ?? -1, 0.03, accuracy: 0.001)
        XCTAssertEqual(syncedState.scheduledSyncInterval ?? -1, 5.0, accuracy: 0.001)
        syncedState.shutdown()
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func makeTrack(
        source: MusicPlayer,
        isPlaying: Bool,
        sourceTrackID: String? = nil,
        itemKind: PlaybackItemKind = .track,
        name: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        durationMs: Int = 180_000,
        progressMs: Int = 1_000
    ) -> MusicTrack {
        MusicTrack(
            source: source,
            sourceTrackID: sourceTrackID,
            itemKind: itemKind,
            name: name,
            artist: artist,
            album: album,
            durationMs: durationMs,
            progressMs: progressMs,
            isPlaying: isPlaying
        )
    }
}

private final class FakeAppleEventSender: AppleEventQuerySending, @unchecked Sendable {
    var appReplies: [OSType: Result<NSAppleEventDescriptor, AppleEventError>] = [:]
    var trackReplies: [OSType: Result<NSAppleEventDescriptor, AppleEventError>] = [:]
    var currentTrackExistsResult: Result<Void, AppleEventError> = .success(())
    var recordedProperties: [OSType] = []

    func getApplicationProperty(
        _ property: OSType,
        pid: pid_t
    ) -> Result<NSAppleEventDescriptor, AppleEventError> {
        recordedProperties.append(property)
        return appReplies[property] ?? .failure(.targetUnavailable(-1728))
    }

    func getTrackProperty(
        _ property: OSType,
        pid: pid_t
    ) -> Result<NSAppleEventDescriptor, AppleEventError> {
        recordedProperties.append(property)
        return trackReplies[property] ?? .failure(.targetUnavailable(-1728))
    }

    func checkCurrentTrackExists(pid: pid_t) -> Result<Void, AppleEventError> {
        currentTrackExistsResult
    }
}

@MainActor
private final class StubPlayerProbe: MusicPlayerProbing {
    let running: Set<MusicPlayer>
    let results: [MusicPlayer: TrackProbeResult]
    private(set) var calls: [MusicPlayer] = []

    init(running: Set<MusicPlayer>, results: [MusicPlayer: TrackProbeResult]) {
        self.running = running
        self.results = results
    }

    func runningPlayers() -> Set<MusicPlayer> {
        running
    }

    func probe(_ player: MusicPlayer, forceFullMetadata: Bool) async -> TrackProbeResult {
        calls.append(player)
        return results[player] ?? .inactive
    }
}

@MainActor
private final class ControlledMusicManager: MusicManaging {
    private(set) var preferredPlayers: [MusicPlayer?] = []
    private(set) var forceFullMetadataFlags: [Bool] = []
    private(set) var invalidatedTracks: [MusicTrack] = []
    private(set) var endpointInvalidationCount = 0
    private var playbackContinuations: [CheckedContinuation<MusicPlaybackResult, Never>] = []
    private var lyricsContinuations: [(
        track: MusicTrack,
        continuation: CheckedContinuation<(Lyrics?, String?), Never>
    )] = []

    var playbackCallCount: Int { preferredPlayers.count }
    var pendingPlaybackCount: Int { playbackContinuations.count }
    var lyricsCallCount: Int { lyricsContinuations.count }

    func getCurrentTrack(
        preferredPlayer: MusicPlayer?,
        forceFullMetadata: Bool
    ) async -> MusicPlaybackResult {
        preferredPlayers.append(preferredPlayer)
        forceFullMetadataFlags.append(forceFullMetadata)
        return await withCheckedContinuation { continuation in
            playbackContinuations.append(continuation)
        }
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lyricsContinuations.append((track, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                    let index = lyricsContinuations.firstIndex(where: { $0.track == track })
                else {
                    return
                }
                lyricsContinuations.remove(at: index).continuation.resume(returning: (nil, nil))
            }
        }
    }

    func invalidateLyricsCache(for track: MusicTrack) {
        invalidatedTracks.append(track)
    }

    func invalidateSpotifyEndpoint() {
        endpointInvalidationCount += 1
    }

    func resolveNextPlayback(with result: MusicPlaybackResult) {
        playbackContinuations.removeFirst().resume(returning: result)
    }

    func resolveLyrics(forTrackNamed name: String, with result: (Lyrics?, String?)) {
        guard let index = lyricsContinuations.firstIndex(where: { $0.track.name == name }) else {
            XCTFail("No pending lyrics request for \(name)")
            return
        }
        lyricsContinuations.remove(at: index).continuation.resume(returning: result)
    }
}
