import Foundation

struct LyricsCacheKey: Hashable, Sendable {
    let provider: LyricsProvider
    let source: MusicPlayer
    let sourceTrackID: String?
    let itemKind: PlaybackItemKind
    let name: String
    let artist: String
    let album: String
    let durationMs: Int

    init(provider: LyricsProvider, track: MusicTrack) {
        self.provider = provider
        source = track.source
        itemKind = track.itemKind
        let trimmedSourceTrackID = track.sourceTrackID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sourceTrackID = trimmedSourceTrackID?.isEmpty == false ? trimmedSourceTrackID : nil
        name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        durationMs = track.durationMs
    }

    fileprivate var positiveKey: LyricsPositiveCacheKey {
        let identity: LyricsPositiveCacheKey.Identity
        if let sourceTrackID {
            identity = .sourceID(source: source, id: sourceTrackID)
        } else {
            identity = .metadata(
                source: source,
                itemKind: itemKind,
                name: name,
                artist: artist,
                album: album,
                durationMs: durationMs
            )
        }
        return LyricsPositiveCacheKey(provider: provider, identity: identity)
    }
}

private struct LyricsPositiveCacheKey: Hashable, Sendable {
    enum Identity: Hashable, Sendable {
        case sourceID(source: MusicPlayer, id: String)
        case metadata(
            source: MusicPlayer,
            itemKind: PlaybackItemKind,
            name: String,
            artist: String,
            album: String,
            durationMs: Int
        )
    }

    let provider: LyricsProvider
    let identity: Identity
}

@MainActor
final class LyricsCache {
    private struct Entry {
        let result: LyricsFetchResult
        var lastAccess: UInt64
        let expiresAt: Date?
    }

    private struct InFlightRequest {
        let task: Task<LyricsFetchResult, Never>
        let generation: UInt64
        var waiters: Set<UUID>
    }

    private let capacity: Int
    private let negativeTTL: TimeInterval
    private let now: () -> Date
    private var positiveEntries: [LyricsPositiveCacheKey: Entry] = [:]
    private var negativeEntries: [LyricsCacheKey: Entry] = [:]
    private var inFlight: [LyricsCacheKey: InFlightRequest] = [:]
    private var positiveGenerations: [LyricsPositiveCacheKey: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    private var generationCounter: UInt64 = 0

    init(
        capacity: Int = 64,
        negativeTTL: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        self.capacity = max(1, capacity)
        self.negativeTTL = negativeTTL
        self.now = now
    }

    func value(
        for key: LyricsCacheKey,
        loader: @escaping @MainActor () async -> LyricsFetchResult
    ) async -> LyricsFetchResult {
        if let result = positiveValue(for: key.positiveKey) {
            return result
        }
        if let result = negativeValue(for: key) {
            return result
        }
        let waiterID = UUID()
        if var request = inFlight[key] {
            request.waiters.insert(waiterID)
            inFlight[key] = request
            let result = await value(
                from: request.task,
                for: key,
                waiterID: waiterID
            )
            finishWaiting(for: key, waiterID: waiterID)
            return result
        }

        generationCounter &+= 1
        let generation = generationCounter
        positiveGenerations[key.positiveKey] = generation
        let task = Task { await loader() }
        inFlight[key] = InFlightRequest(
            task: task,
            generation: generation,
            waiters: [waiterID]
        )
        let result = await value(from: task, for: key, waiterID: waiterID)
        if inFlight[key]?.generation == generation {
            inFlight[key] = nil
            store(result, for: key, generation: generation)
        }
        cleanGenerationIfUnused(for: key.positiveKey)
        return result
    }

    private func value(
        from task: Task<LyricsFetchResult, Never>,
        for key: LyricsCacheKey,
        waiterID: UUID
    ) async -> LyricsFetchResult {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiting(for: key, waiterID: waiterID)
            }
        }
    }

    private func cancelWaiting(for key: LyricsCacheKey, waiterID: UUID) {
        guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else {
            return
        }
        if request.waiters.isEmpty {
            inFlight[key] = nil
            request.task.cancel()
            cleanGenerationIfUnused(for: key.positiveKey)
        } else {
            inFlight[key] = request
        }
    }

    private func finishWaiting(for key: LyricsCacheKey, waiterID: UUID) {
        guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else {
            return
        }
        inFlight[key] = request
    }

    private func positiveValue(for key: LyricsPositiveCacheKey) -> LyricsFetchResult? {
        guard var entry = positiveEntries[key] else { return nil }

        accessCounter &+= 1
        entry.lastAccess = accessCounter
        positiveEntries[key] = entry
        return entry.result
    }

    private func negativeValue(for key: LyricsCacheKey) -> LyricsFetchResult? {
        guard var entry = negativeEntries[key] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= now() {
            negativeEntries[key] = nil
            return nil
        }

        accessCounter &+= 1
        entry.lastAccess = accessCounter
        negativeEntries[key] = entry
        return entry.result
    }

    private func store(
        _ result: LyricsFetchResult,
        for key: LyricsCacheKey,
        generation: UInt64
    ) {
        accessCounter &+= 1
        switch result {
        case .found:
            if positiveGenerations[key.positiveKey] == generation
                || positiveEntries[key.positiveKey] == nil
            {
                positiveEntries[key.positiveKey] = Entry(
                    result: result,
                    lastAccess: accessCounter,
                    expiresAt: nil
                )
            }
            negativeEntries[key] = nil
        case .notFound:
            negativeEntries[key] = Entry(
                result: result,
                lastAccess: accessCounter,
                expiresAt: now().addingTimeInterval(negativeTTL)
            )
        case .transientFailure:
            return
        }
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        if positiveEntries.count > capacity,
            let oldestKey = positiveEntries.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            })?.key
        {
            positiveEntries[oldestKey] = nil
            cleanGenerationIfUnused(for: oldestKey)
        }
        if negativeEntries.count > capacity,
            let oldestKey = negativeEntries.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            })?.key
        {
            negativeEntries[oldestKey] = nil
        }
    }

    private func cleanGenerationIfUnused(for positiveKey: LyricsPositiveCacheKey) {
        let hasInFlightRequest = inFlight.keys.contains { $0.positiveKey == positiveKey }
        if !hasInFlightRequest {
            positiveGenerations[positiveKey] = nil
        }
    }
}
