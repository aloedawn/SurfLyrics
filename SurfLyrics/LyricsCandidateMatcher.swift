import Foundation

struct LyricsCandidate: Equatable, Sendable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let durationMs: Int?

    init(
        trackName: String,
        artistName: String,
        albumName: String? = nil,
        durationMs: Int? = nil
    ) {
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.durationMs = durationMs
    }
}

struct LyricsCandidateMatcher: Sendable {
    static let `default` = LyricsCandidateMatcher()

    private static let titleWeight = 0.40
    private static let artistWeight = 0.25
    private static let albumWeight = 0.10
    private static let durationWeight = 0.25
    private static let minimumTitleSimilarity = 0.55
    private static let minimumArtistSimilarity = 0.45
    private static let minimumSingleTokenTitleSimilarity = 0.90
    private static let featureMarkers: Set<String> = ["feat", "ft", "featuring"]

    private let likelyMatchThreshold: Double
    private let ambiguityMargin: Double

    init(
        likelyMatchThreshold: Double = 0.74,
        ambiguityMargin: Double = 0.06
    ) {
        self.likelyMatchThreshold = likelyMatchThreshold
        self.ambiguityMargin = ambiguityMargin
    }

    func isLikelyMatch(_ candidate: LyricsCandidate, for track: MusicTrack) -> Bool {
        guard let score = score(candidate, for: track) else { return false }
        return score >= likelyMatchThreshold
    }

    func bestMatchIndex(
        for track: MusicTrack,
        among candidates: [LyricsCandidate]
    ) -> Int? {
        let ranked = candidates.enumerated()
            .compactMap { index, candidate -> (index: Int, score: Double)? in
                guard let score = score(candidate, for: track) else { return nil }
                return (index, score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.index < rhs.index }
                return lhs.score > rhs.score
            }

        guard let best = ranked.first, best.score >= likelyMatchThreshold else {
            return nil
        }
        if let runnerUp = ranked.dropFirst().first(where: {
            !Self.equivalentMetadata(candidates[$0.index], candidates[best.index])
        }), best.score - runnerUp.score < ambiguityMargin {
            return nil
        }
        return best.index
    }

    func bestMatch(
        for track: MusicTrack,
        among candidates: [LyricsCandidate]
    ) -> LyricsCandidate? {
        guard let index = bestMatchIndex(for: track, among: candidates) else { return nil }
        return candidates[index]
    }

    private func score(_ candidate: LyricsCandidate, for track: MusicTrack) -> Double? {
        guard Self.editionTags(in: track.name) == Self.editionTags(in: candidate.trackName) else {
            return nil
        }

        let titleSimilarity = Self.titleSimilarity(track.name, candidate.trackName)
        let artistSimilarity = Self.textSimilarity(track.artist, candidate.artistName)
        guard titleSimilarity >= Self.minimumTitleSimilarity else { return nil }
        let trackTitleTokens = Self.remasterNormalizedTokens(track.name)
        let candidateTitleTokens = Self.remasterNormalizedTokens(candidate.trackName)
        if min(trackTitleTokens.count, candidateTitleTokens.count) == 1,
            trackTitleTokens != candidateTitleTokens,
            titleSimilarity < Self.minimumSingleTokenTitleSimilarity
        {
            return nil
        }

        let albumSimilarity: Double?
        if let candidateAlbum = candidate.albumName,
            !candidateAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            albumSimilarity = Self.textSimilarity(track.album, candidateAlbum)
        } else {
            albumSimilarity = nil
        }

        guard artistSimilarity >= Self.minimumArtistSimilarity else {
            return nil
        }

        var weightedScore = titleSimilarity * Self.titleWeight
            + artistSimilarity * Self.artistWeight
        var availableWeight = Self.titleWeight + Self.artistWeight

        if let albumSimilarity {
            weightedScore += albumSimilarity * Self.albumWeight
            availableWeight += Self.albumWeight
        }

        if track.durationMs > 0, let candidateDuration = candidate.durationMs,
            candidateDuration > 0
        {
            let difference = abs(Int64(track.durationMs) - Int64(candidateDuration))
            let tolerance = Self.durationTolerance(expectedMs: track.durationMs)
            guard difference <= Int64(tolerance) else { return nil }

            let durationSimilarity = 1.0 - Double(difference) / Double(tolerance)
            weightedScore += durationSimilarity * Self.durationWeight
            availableWeight += Self.durationWeight
        }

        return weightedScore / availableWeight
    }

    private static func durationTolerance(expectedMs: Int) -> Int {
        let proportionalTolerance = Int(Double(expectedMs) * 0.03)
        return min(8_000, max(4_000, proportionalTolerance))
    }

    private static func equivalentMetadata(
        _ lhs: LyricsCandidate,
        _ rhs: LyricsCandidate
    ) -> Bool {
        titleSimilarity(lhs.trackName, rhs.trackName) == 1
            && textSimilarity(lhs.artistName, rhs.artistName) == 1
            && compatibleOptionalText(lhs.albumName, rhs.albumName)
            && compatibleDuration(lhs.durationMs, rhs.durationMs)
            && editionTags(in: lhs.trackName) == editionTags(in: rhs.trackName)
    }

    private static func compatibleOptionalText(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return left.isEmpty || right.isEmpty || textSimilarity(left, right) == 1
    }

    private static func compatibleDuration(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, lhs > 0, let rhs, rhs > 0 else { return true }
        let expected = min(lhs, rhs)
        return abs(Int64(lhs) - Int64(rhs)) <= Int64(durationTolerance(expectedMs: expected))
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        similarity(normalizedTokens(lhs), normalizedTokens(rhs))
    }

    private static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        max(
            textSimilarity(lhs, rhs),
            similarity(remasterNormalizedTokens(lhs), remasterNormalizedTokens(rhs))
        )
    }

    private static func similarity(_ leftTokens: [String], _ rightTokens: [String]) -> Double {
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        if leftTokens == rightTokens { return 1 }

        let tokenScore = diceCoefficient(leftTokens, rightTokens)
        let leftText = leftTokens.joined(separator: " ")
        let rightText = rightTokens.joined(separator: " ")
        let spacedEditScore = levenshteinSimilarity(leftText, rightText)
        let compactEditScore = levenshteinSimilarity(
            leftTokens.joined(),
            rightTokens.joined()
        )
        let editScore = max(spacedEditScore, compactEditScore)

        // Edit distance is discounted so token agreement wins when words merely share a prefix.
        return max(tokenScore, editScore * 0.85)
    }

    private static func remasterNormalizedTokens(_ text: String) -> [String] {
        let tokens = normalizedTokens(text)
        guard tokens.contains(where: { ["remaster", "remastered"].contains($0) }) else {
            return tokens
        }
        return tokens.filter { token in
            !["remaster", "remastered"].contains(token)
                && !(token.count == 4 && token.allSatisfy(\.isNumber))
        }
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        let tokens = folded(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let markerIndex = tokens.firstIndex(where: featureMarkers.contains),
            markerIndex > 0
        else {
            return tokens
        }
        return Array(tokens[..<markerIndex])
    }

    private static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func diceCoefficient(_ lhs: [String], _ rhs: [String]) -> Double {
        var remaining = rhs.reduce(into: [String: Int]()) { counts, token in
            counts[token, default: 0] += 1
        }
        var intersection = 0
        for token in lhs where remaining[token, default: 0] > 0 {
            intersection += 1
            remaining[token, default: 0] -= 1
        }
        return Double(2 * intersection) / Double(lhs.count + rhs.count)
    }

    private static func levenshteinSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty, !right.isEmpty else { return left == right ? 1 : 0 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitutionCost = leftCharacter == rightCharacter ? 0 : 1
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + substitutionCost
                )
            }
            previous = current
        }

        let longestLength = max(left.count, right.count)
        return 1.0 - Double(previous[right.count]) / Double(longestLength)
    }

    private enum EditionTag: Hashable {
        case live
        case remix
        case acoustic
        case instrumental
        case karaoke
        case spedUp
        case slowed
    }

    private static func editionTags(in text: String) -> Set<EditionTag> {
        let text = folded(text)
        var qualifierSegments = bracketedSegments(in: text).filter { segment in
            !normalizedTokens(segment).contains(where: featureMarkers.contains)
        }

        for separator in [" - ", " – ", " — "] {
            if let separatorRange = text.range(of: separator) {
                qualifierSegments.append(String(text[separatorRange.upperBound...]))
                break
            }
        }

        var fullTokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if let featureIndex = fullTokens.firstIndex(where: featureMarkers.contains) {
            fullTokens = Array(fullTokens[..<featureIndex])
        }
        if let suffix = trailingEditionSegment(in: fullTokens) {
            qualifierSegments.append(suffix.joined(separator: " "))
        }

        return qualifierSegments.reduce(into: Set<EditionTag>()) { tags, segment in
            let tokens = segment
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let tokenSet = Set(tokens)

            if tokenSet.contains("live") { tags.insert(.live) }
            if !tokenSet.isDisjoint(with: ["remix", "remixed"]) { tags.insert(.remix) }
            if tokenSet.contains("acoustic") { tags.insert(.acoustic) }
            if tokenSet.contains("instrumental") { tags.insert(.instrumental) }
            if tokenSet.contains("karaoke") { tags.insert(.karaoke) }
            if adjacentTokens("sped", "up", in: tokens) { tags.insert(.spedUp) }
            if tokenSet.contains("slowed") { tags.insert(.slowed) }
        }
    }

    private static func trailingEditionSegment(in tokens: [String]) -> [String]? {
        guard let last = tokens.last else { return nil }
        if ["live", "remix", "remixed", "acoustic", "instrumental", "karaoke", "slowed"]
            .contains(last)
        {
            return [last]
        }
        if tokens.count >= 2,
            tokens[tokens.count - 2] == "sped",
            tokens[tokens.count - 1] == "up"
        {
            return ["sped", "up"]
        }
        return nil
    }

    private static func bracketedSegments(in text: String) -> [String] {
        let openingBrackets: Set<Character> = ["(", "[", "{"]
        let closingBrackets: Set<Character> = [")", "]", "}"]
        var segments: [String] = []
        var segment = ""
        var depth = 0

        for character in text {
            if openingBrackets.contains(character) {
                if depth == 0 { segment = "" }
                depth += 1
            } else if closingBrackets.contains(character), depth > 0 {
                depth -= 1
                if depth == 0 { segments.append(segment) }
            } else if depth > 0 {
                segment.append(character)
            }
        }
        return segments
    }

    private static func adjacentTokens(_ first: String, _ second: String, in tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        return tokens.indices.dropLast().contains { index in
            tokens[index] == first && tokens[index + 1] == second
        }
    }
}
