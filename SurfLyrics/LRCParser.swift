import Foundation

enum LRCParser {
    static func parse(_ lrc: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            if let parsed = parseLine(rawLine) {
                lines.append(parsed)
            }
        }
        return lines.sorted { $0.timeMs < $1.timeMs }
    }

    private static func parseLine(_ line: Substring) -> LyricsLine? {
        guard let openBracket = line.firstIndex(of: "[") else { return nil }
        let afterOpen = line[line.index(after: openBracket)...]
        guard let closeBracket = afterOpen.firstIndex(of: "]") else { return nil }
        let timestamp = afterOpen[..<closeBracket]

        guard let firstColon = timestamp.firstIndex(of: ":") else { return nil }
        let minutesSlice = timestamp[..<firstColon]
        guard let minutes = parseNonNegativeInt(minutesSlice) else { return nil }

        let afterMinutes = timestamp[timestamp.index(after: firstColon)...]
        let seconds: Int
        let fraction: Int
        if let separator = afterMinutes.firstIndex(where: { $0 == "." || $0 == ":" }) {
            let secondsSlice = afterMinutes[..<separator]
            let fractionSlice = afterMinutes[afterMinutes.index(after: separator)...]
            guard let parsedSeconds = parseNonNegativeInt(secondsSlice),
                parsedSeconds < 60,
                let parsedFraction = parseFractionMilliseconds(fractionSlice)
            else {
                return nil
            }
            seconds = parsedSeconds
            fraction = parsedFraction
        } else {
            guard let parsedSeconds = parseNonNegativeInt(afterMinutes),
                parsedSeconds < 60
            else {
                return nil
            }
            seconds = parsedSeconds
            fraction = 0
        }

        let (minuteSeconds, minutesOverflow) = minutes.multipliedReportingOverflow(by: 60)
        let (totalSeconds, secondsOverflow) = minuteSeconds.addingReportingOverflow(seconds)
        let (wholeMilliseconds, millisecondsOverflow) = totalSeconds.multipliedReportingOverflow(by: 1000)
        let (milliseconds, fractionOverflow) = wholeMilliseconds.addingReportingOverflow(fraction)
        guard !minutesOverflow, !secondsOverflow, !millisecondsOverflow, !fractionOverflow else {
            return nil
        }

        let text = line[line.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)
        return LyricsLine(timeMs: milliseconds, text: text)
    }

    private static func parseNonNegativeInt(_ slice: Substring) -> Int? {
        guard !slice.isEmpty else { return nil }
        var value = 0
        for byte in slice.utf8 {
            guard byte >= 48 && byte <= 57 else { return nil }
            let digit = Int(byte - 48)
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            guard !multiplyOverflow else { return nil }
            let (added, addOverflow) = multiplied.addingReportingOverflow(digit)
            guard !addOverflow else { return nil }
            value = added
        }
        return value
    }

    private static func parseFractionMilliseconds(_ slice: Substring) -> Int? {
        guard !slice.isEmpty else { return nil }
        var fraction = 0
        var multiplier = 100
        for byte in slice.utf8 {
            guard byte >= 48 && byte <= 57 else { return nil }
            if multiplier > 0 {
                fraction += Int(byte - 48) * multiplier
                multiplier /= 10
            }
        }
        return fraction
    }
}
