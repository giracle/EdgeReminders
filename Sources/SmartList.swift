import Foundation

struct SmartList: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var rule: SmartRule

    init(id: UUID = UUID(), name: String, rule: SmartRule) {
        self.id = id
        self.name = name
        self.rule = rule
    }
}

enum SmartRule: Hashable, Codable {
    case tag(String)
    case priority(ReminderPriority)
    case overdue
    case dueInDays(Int)
    case noDueDate
    case list(String)

    var label: String {
        switch self {
        case let .tag(name): "标签「\(name)」"
        case let .priority(level): "优先级为\(level.label)"
        case .overdue: "已逾期"
        case let .dueInDays(days): "未来 \(days) 天内到期"
        case .noDueDate: "未安排日期"
        case let .list(id): "清单「\(id)」"
        }
    }

    var pickerTitle: String {
        switch self {
        case .tag: "包含标签"
        case .priority: "指定优先级"
        case .overdue: "已逾期"
        case .dueInDays: "即将到期"
        case .noDueDate: "未安排日期"
        case .list: "来自清单"
        }
    }

    static let builtIn: [SmartList] = [
        SmartList(name: "重要且紧急", rule: .priority(.high)),
        SmartList(name: "本周到期", rule: .dueInDays(7)),
        SmartList(name: "需要安排", rule: .noDueDate),
    ]

    func matches(_ item: ReminderItem, at now: Date) -> Bool {
        let calendar = Calendar.current
        switch self {
        case let .tag(name):
            return item.tags.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
        case let .priority(level):
            return item.priority == level
        case .overdue:
            guard let due = item.dueDate, !item.isCompleted else { return false }
            return due < (item.hasTime ? now : calendar.startOfDay(for: now))
        case let .dueInDays(days):
            guard let due = item.dueDate, !item.isCompleted else { return false }
            guard let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return false }
            return due >= calendar.startOfDay(for: now) && due <= end
        case .noDueDate:
            return item.dueDate == nil && !item.isCompleted
        case let .list(id):
            return item.listID == id
        }
    }
}
