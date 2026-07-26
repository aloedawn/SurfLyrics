import Foundation

@MainActor
enum LRCParser {
    private static let regexes: [(expression: NSRegularExpression, hasFraction: Bool)] = {
        [
            (#"\[(\d+):(\d+)\.(\d+)\](.+)"#, true),
            (#"\[(\d+):(\d+):(\d+)\](.+)"#, true),
            (#"\[(\d+):(\d+)\](.+)"#, false),
        ].compactMap { pattern, hasFraction in
            (try? NSRegularExpression(pattern: pattern)).map {
                (expression: $0, hasFraction: hasFraction)
            }
        }
    }()

    static func parse(_ lrc: String) -> [(timeMs: Int, text: String)] {
        var lines: [(timeMs: Int, text: String)] = []
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
    ) -> (timeMs: Int, text: String)? {
        let nsLine = line as NSString
        guard let match = expression.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) else {
            return nil
        }

        let minutes = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
        let seconds = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
        let textRangeIndex = hasFraction ? 4 : 3
        let text = nsLine.substring(with: match.range(at: textRangeIndex))
            .trimmingCharacters(in: .whitespaces)
        guard seconds < 60, !text.isEmpty else { return nil }

        var milliseconds = (minutes * 60 + seconds) * 1000
        if hasFraction {
            milliseconds += fractionalMilliseconds(
                nsLine.substring(with: match.range(at: 3))
            )
        }
        return (milliseconds, text)
    }

    private static func fractionalMilliseconds(_ value: String) -> Int {
        let digits = String(value.prefix(3))
        let padded = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
        return Int(padded) ?? 0
    }
}
