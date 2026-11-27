import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, markdown, json, backup

    var id: String { rawValue }
}

@MainActor
struct TaskExporter {
    let store: TaskStore

    private var sortedItems: [ReminderItem] {
        store.tasks.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.dueDate != $1.dueDate { return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func listTitle(_ item: ReminderItem) -> String {
        store.lists.first { $0.id == item.listID }?.title ?? item.source.label
    }

    func csv() -> Data {
        var rows = [["标题", "清单", "来源", "状态", "截止日期", "时间", "到时提醒", "优先级", "重复", "标签", "完成时间", "子任务", "备注"]]
        for item in sortedItems {
            rows.append([
                item.title,
                listTitle(item),
                item.source.label,
                item.isCompleted ? "已完成" : "待办",
                item.dueDate?.formatted(.dateTime.year().month(.defaultDigits).day()) ?? "",
                item.hasTime ? (item.dueDate?.formatted(.dateTime.hour().minute()) ?? "") : "",
                item.alerts ? "是" : "",
                item.priority == .none ? "" : item.priority.label,
                item.repeatRule == .never ? "" : item.repeatRule.label,
                item.tags.joined(separator: " "),
                item.completionDate?.formatted(.dateTime.year().month(.defaultDigits).day().hour().minute()) ?? "",
                item.subtasks.map { ($0.isCompleted ? "✓ " : "○ ") + $0.title }.joined(separator: "; "),
                item.notes
            ])
        }
        let text = "\u{FEFF}" + rows.map { row in
            row.map(Self.escapeCSV).joined(separator: ",")
        }.joined(separator: "\n")
        return Data(text.utf8)
    }

    func markdown() -> String {
        var lines = ["# 浮光提醒", "",
                     "导出时间：\(Date.now.formatted(date: .abbreviated, time: .shortened))", ""]
        let open = sortedItems.filter { !$0.isCompleted }
        let done = sortedItems.filter(\.isCompleted)

        lines.append("## 待办（\(open.count)）")
        lines.append("")
        for item in open {
            var suffix = "（\(listTitle(item))）"
            if let due = item.dueDate {
                suffix += " · " + due.formatted(item.hasTime
                    ? .dateTime.month(.defaultDigits).day().hour().minute()
                    : .dateTime.month(.defaultDigits).day())
            }
            if !item.tags.isEmpty {
                suffix += " · " + item.tags.map { "#" + $0 }.joined(separator: " ")
            }
            lines.append("- [ ] \(item.title)\(suffix)")
            for subtask in item.subtasks {
                lines.append("  - [\(subtask.isCompleted ? "x" : " ")] \(subtask.title)")
            }
            if !item.notes.isEmpty {
                lines.append("  > \(item.notes.replacingOccurrences(of: "\n", with: " "))")
            }
        }

        lines.append("")
        lines.append("## 已完成（\(done.count)）")
        lines.append("")
        for item in done.sorted(by: { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }) {
            var suffix = "（\(listTitle(item))）"
            if let completed = item.completionDate {
                suffix += " · 完成于 " + completed.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
            }
            lines.append("- [x] ~~\(item.title)~~\(suffix)")
        }
        return lines.joined(separator: "\n")
    }

    private struct JSONSubtask: Encodable {
        let title: String
        let completed: Bool
    }

    private struct JSONItem: Encodable {
        let id: String
        let title: String
        let notes: String
        let list: String
        let source: String
        let completed: Bool
        let dueDate: Date?
        let hasTime: Bool
        let alert: Bool
        let priority: String
        let repeatRule: String
        let tags: [String]
        let subtasks: [JSONSubtask]
        let completionDate: Date?
    }

    func json() -> Data {
        let items: [JSONItem] = sortedItems.map { item in
            JSONItem(
                id: item.id,
                title: item.title,
                notes: item.notes,
                list: listTitle(item),
                source: item.source.rawValue,
                completed: item.isCompleted,
                dueDate: item.dueDate,
                hasTime: item.hasTime,
                alert: item.alerts,
                priority: item.priority.rawValue,
                repeatRule: item.repeatRule.rawValue,
                tags: item.tags,
                subtasks: item.subtasks.map { JSONSubtask(title: $0.title, completed: $0.isCompleted) },
                completionDate: item.completionDate
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(items)) ?? Data("[]".utf8)
    }

    func backup() -> Data {
        store.backupData()
    }

    func restore(from data: Data) throws {
        try store.restore(from: data)
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
