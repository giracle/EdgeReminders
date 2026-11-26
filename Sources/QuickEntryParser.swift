import Foundation

enum QuickEntryParser {
    struct Result: Equatable {
        let title: String
        let date: Date
        let hasTime: Bool
    }

    private static let day = try! NSRegularExpression(pattern:
        #"^(大后天|今天|今日|明天|明日|后天|(?:下周|本周|周)[一二三四五六日天]|\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}月\d{1,2}[日号])"#)
    private static let clock = try! NSRegularExpression(pattern:
        #"^\s*(凌晨|早上|上午|中午|下午|傍晚|晚上)?\s*([0-9零〇一二两三四五六七八九十]{1,3})(?:\s*[:：]\s*([0-9]{2})(?![0-9])|\s*[点時时](?:\s*(半|[0-9零〇一二两三四五六七八九十]{1,3}分))?)"#)
    private static let timePrefix = try! NSRegularExpression(pattern:
        #"^\s*(?:凌晨|早上|上午|中午|下午|傍晚|晚上|[0-9零〇一二两三四五六七八九十]+\s*[:：点時时])"#)
    private static let boundary = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，:：·-—"))

    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Result? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let day = firstMatch(Self.day, in: input),
              let dayText = substring(input, day.range(at: 1)),
              let end = Range(day.range, in: input)?.upperBound,
              let date = date(for: dayText, now: now, calendar: calendar) else { return nil }

        let rest = String(input[end...])
        if let clock = firstMatch(Self.clock, in: rest) {
            guard let hourText = substring(rest, clock.range(at: 2)), let hour = number(hourText),
                  let endOfTime = Range(clock.range, in: rest)?.upperBound else { return nil }
            let period = substring(rest, clock.range(at: 1))
            let minuteText = substring(rest, clock.range(at: 3)) ?? substring(rest, clock.range(at: 4))
            guard let minute = minuteText.map({ $0 == "半" ? 30 : number($0.hasSuffix("分") ? String($0.dropLast()) : $0) }) ?? 0,
                  minute < 60, let adjustedHour = hourOnClock(hour, period: period),
                  let timed = calendar.date(bySettingHour: adjustedHour, minute: minute, second: 0, of: date,
                                            matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
                  calendar.isDate(timed, inSameDayAs: date) else { return nil }
            let title = rest[endOfTime...].trimmingCharacters(in: boundary)
            // A numeric suffix after a clock may be an incomplete time rather than a title.
            guard !title.isEmpty, title.first != "分" else { return nil }
            return Result(title: title, date: timed, hasTime: true)
        }

        let title = rest.trimmingCharacters(in: boundary)
        guard !title.isEmpty, firstMatch(Self.timePrefix, in: rest) == nil else { return nil }
        return Result(title: title, date: date, hasTime: false)
    }

    private static func date(for text: String, now: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: now)
        let offsets = ["今天": 0, "今日": 0, "明天": 1, "明日": 1, "后天": 2, "大后天": 3]
        if let days = offsets[text] { return calendar.date(byAdding: .day, value: days, to: start) }

        if let last = text.last, text.contains("周"), let index = "一二三四五六日天".firstIndex(of: last) {
            let target = min(6, "一二三四五六日天".distance(from: "一二三四五六日天".startIndex, to: index))
            let today = (calendar.component(.weekday, from: start) + 5) % 7
            var offset = target - today
            if text.hasPrefix("下周") { offset += 7 }
            if text.hasPrefix("周"), offset < 0 { offset += 7 }
            return calendar.date(byAdding: .day, value: offset, to: start)
        }

        let parts = text.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { Int($0) }
        if parts.count == 3 { return strictDate(parts[0], parts[1], parts[2], calendar: calendar) }
        guard parts.count == 2 else { return nil }
        let year = calendar.component(.year, from: now)
        return (year...year + 8).compactMap { strictDate($0, parts[0], parts[1], calendar: calendar) }
            .first { $0 >= start }
    }

    private static func strictDate(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func hourOnClock(_ hour: Int, period: String?) -> Int? {
        guard (0...23).contains(hour) else { return nil }
        switch period {
        case "下午", "傍晚", "晚上": return hour < 12 ? hour + 12 : hour
        case "中午": return (1...3).contains(hour) ? hour + 12 : hour
        case "凌晨": return hour == 12 ? 0 : (hour < 12 ? hour : nil)
        case "早上", "上午": return hour <= 12 ? hour : nil
        default: return hour
        }
    }

    private static func number(_ text: String) -> Int? {
        if let integer = Int(text) { return integer }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3,
                                        "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text.count == 1, let digit = text.first, digit != "十" { return digits[digit] }
        guard let ten = text.firstIndex(of: "十") else { return nil }
        let left = text[..<ten]
        let right = text[text.index(after: ten)...]
        guard left.count <= 1, right.count <= 1,
              let tens = left.isEmpty ? 1 : left.first.flatMap({ digits[$0] }),
              let ones = right.isEmpty ? 0 : right.first.flatMap({ digits[$0] }) else { return nil }
        return tens * 10 + ones
    }

    private static func firstMatch(_ expression: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        Range(range, in: text).map { String(text[$0]) }
    }
}
