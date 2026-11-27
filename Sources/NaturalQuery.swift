import Foundation

struct NaturalQuery: Equatable {
    var text = ""
    var date: Date?
    var tag: String?
    var priority: ReminderPriority?

    var isEmpty: Bool {
        text.isEmpty && date == nil && tag == nil && priority == nil
    }
}

enum NaturalQueryParser {
    private static let day = try! NSRegularExpression(pattern:
        "(?:大后天|今天|今日|明天|明日|后天|(?:下周|本周|周)[一二三四五六日天]|\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}|\\d{1,2}月\\d{1,2}[日号])")
    private static let tag = try! NSRegularExpression(pattern: "#([^#\\s，,。；;！!？?（）()]+)")

    static func parse(_ input: String, now: Date = .now, calendar: Calendar = .current) -> NaturalQuery {
        var query = NaturalQuery()
        var remainder = input

        if let match = firstMatch(Self.tag, in: input) {
            if let range = Range(match.range(at: 1), in: input) {
                query.tag = String(input[range])
            }
            if let full = Range(match.range, in: input) {
                remainder = remainder.replacingCharacters(in: full, with: " ")
            }
        }

        for keyword in ["紧急", "高优先级"] where remainder.contains(keyword) {
            query.priority = .high
            remainder = remainder.replacingOccurrences(of: keyword, with: " ", options: .literal)
        }
        if query.priority == nil, remainder.contains("低优先级") {
            query.priority = .low
            remainder = remainder.replacingOccurrences(of: "低优先级", with: " ", options: .literal)
        }
        if query.priority == nil, remainder.contains("中优先级") {
            query.priority = .medium
            remainder = remainder.replacingOccurrences(of: "中优先级", with: " ", options: .literal)
        }

        if let match = firstMatch(Self.day, in: remainder),
           let range = Range(match.range, in: remainder),
           let date = QuickEntryParser.date(for: String(remainder[range]), now: now, calendar: calendar) {
            query.date = date
            remainder = remainder.replacingCharacters(in: range, with: " ")
        }

        remainder = remainder
            .replacingOccurrences(of: "  ", with: " ", options: .literal)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        query.text = remainder
        return query
    }

    private static func firstMatch(_ expression: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
