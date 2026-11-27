import Foundation

/// 模糊搜索：多关键词（空格分隔、与顺序无关）+ 拼音全拼 / 首字母。
enum FuzzySearch {
    struct Text {
        let combined: String
        let pinyin: String
        let initials: String

        var isEmpty: Bool { combined.isEmpty }
    }

    /// 把查询串拆成关键词（NaturalQuery 解析后的文本部分传入）。
    static func tokens(from text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// 汇总条目所有可搜索字段（标题/备注/清单名/标签/资料名）。
    static func text(for item: ReminderItem, listTitle: String, resources: [ReminderResource]) -> Text {
        var parts = [item.title, item.notes, listTitle]
        parts.append(contentsOf: item.tags)
        parts.append(contentsOf: resources.map(\.title))
        let combined = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        return Text(combined: combined,
                    pinyin: pinyin(combined),
                    initials: initials(combined))
    }

    /// 每个关键词都要命中（子串 / 拼音全拼 / 拼音首字母）。
    static func matches(_ text: Text, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        guard !text.isEmpty else { return false }
        for token in tokens {
            if text.combined.contains(token) { continue }
            if !text.pinyin.isEmpty, text.pinyin.contains(token) { continue }
            if !text.initials.isEmpty, text.initials.contains(token) { continue }
            return false
        }
        return true
    }

    // MARK: - 拼音

    private static func pinyin(_ text: String) -> String {
        guard let latin = text.applyingTransform(.toLatin, reverse: false) else { return "" }
        let stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(stripped.filter { $0.isLetter || $0.isNumber })
    }

    private static func initials(_ text: String) -> String {
        guard let latin = text.applyingTransform(.toLatin, reverse: false) else { return "" }
        let stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        var result = ""
        var previousWasLatin = false
        for character in stripped {
            if character.isLetter {
                if !previousWasLatin { result.append(character.lowercased()) }
                previousWasLatin = true
            } else {
                previousWasLatin = false
            }
        }
        return result
    }
}
