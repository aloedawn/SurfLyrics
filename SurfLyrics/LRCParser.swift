import Foundation

enum LRCParser {
    private static let regexes: [(expression: NSRegularExpression, hasFraction: Bool)] = {
        [
            (#"\[(\d+):(\d+)\.(\d+)\](.*)"#, true),
            (#"\[(\d+):(\d+):(\d+)\](.*)"#, true),
            (#"\[(\d+):(\d+)\](.*)"#, false),
        ].compactMap { pattern, hasFraction in
            (try? NSRegularExpression(pattern: pattern)).map {
                (expression: $0, hasFraction: hasFraction)
            }
        }
    }()

    static func parse(_ lrc: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        for line in lrc.components(separatedBy: .newlines) {
            for regex in regexes {
                if let parsed = parseLine(
                    line,
                    expression: regex.expression,
                    hasFraction: regex.hasFraction
                ) {
                    lines.append(parsed)
                    break
                }
            }
        }
        return lines.sorted { $0.timeMs < $1.timeMs }
    }

    private static func parseLine(
        _ line: String,
        expression: NSRegularExpression,
        hasFraction: Bool
    ) -> LyricsLine? {
        let nsLine = line as NSString
        guard let match = expression.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) else {
            return nil
        }

        guard let minutes = Int(nsLine.substring(with: match.range(at: 1))),
            let seconds = Int(nsLine.substring(with: match.range(at: 2))),
            seconds < 60
        else { return nil }
        let textRangeIndex = hasFraction ? 4 : 3
        let text = nsLine.substring(with: match.range(at: textRangeIndex))
            .trimmingCharacters(in: .whitespaces)
        let fraction = hasFraction
            ? fractionalMilliseconds(nsLine.substring(with: match.range(at: 3))) : 0
        let (minuteSeconds, minutesOverflow) = minutes.multipliedReportingOverflow(by: 60)
        let (totalSeconds, secondsOverflow) = minuteSeconds.addingReportingOverflow(seconds)
        let (wholeMilliseconds, millisecondsOverflow) = totalSeconds.multipliedReportingOverflow(by: 1000)
        let (milliseconds, fractionOverflow) = wholeMilliseconds.addingReportingOverflow(fraction)
        guard !minutesOverflow, !secondsOverflow, !millisecondsOverflow, !fractionOverflow
        else { return nil }
        return LyricsLine(timeMs: milliseconds, text: text)
    }

    private static func fractionalMilliseconds(_ value: String) -> Int {
        let digits = String(value.prefix(3))
        let padded = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
        return Int(padded) ?? 0
    }
}
