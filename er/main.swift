import Foundation

// er —— 浮光提醒的命令行入口。
// 直接读写 ~/Library/Application Support/EdgeReminders/Reminders.json，
// 写完发 DistributedNotification "EdgeReminders.reload"，应用会自动重载。

struct Subtask: Codable {
    var id: UUID
    var title: String
    var isCompleted: Bool
}

struct Resource: Codable {
    var kind: String
    var url: URL
    var title: String?
    var bookmarkData: Data?
    var addedAt: Date?
}

struct Item: Codable {
    var id: String
    var listID: String
    var title: String
    var notes: String
    var dueDate: Date?
    var hasTime: Bool
    var alerts: Bool
    var isCompleted: Bool
    var completionDate: Date?
    var priority: String
    var repeatRule: String
    var source: String
    var isWritable: Bool
    var repeatAnchor: Date?
    var generatedBy: String?
    var snoozedUntil: Date?
    var subtasks: [Subtask]?
    var resources: [Resource]?
    var tags: [String]?
    var dependsOn: [String]?
}

struct Store: Codable {
    var lists: [List]?
    var items: [Item]
    var pinnedTaskIDs: [String]?
    var templates: [Template]?
    var appleResources: [String: [Resource]]?
    var smartLists: [SmartList]?
    var archivedItems: [Item]?

    struct List: Codable {
        var id: String
        var title: String
        var source: String
        var isWritable: Bool
        var accountName: String?
    }

    struct Template: Codable {
        var id: UUID
        var name: String
        var subtaskTitles: [String]
    }

    struct SmartList: Codable {
        var id: UUID
        var name: String
        var rule: RawRule
    }

    // 智能清单规则在应用里是带关联值的枚举（编码为 ["tag", "值"] 数组），
    // CLI 只做无损透传，不解释具体语义。
    struct RawRule: Codable {
        var parts: [RawValue]

        enum RawValue: Codable {
            case string(String)
            case int(Int)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(String.self) { self = .string(value) }
                else if let value = try? container.decode(Int.self) { self = .int(value) }
                else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的规则值") }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let value): try container.encode(value)
                case .int(let value): try container.encode(value)
                }
            }
        }
    }
}

let inboxID = "local-inbox"
let reloadNotification = Notification.Name("EdgeReminders.reload")

func storeURL() -> URL {
    let support = URL.applicationSupportDirectory
    let candidates = [
        support.appending(path: "local.fuguang.EdgeReminders", directoryHint: .isDirectory),
        support.appending(path: "EdgeReminders", directoryHint: .isDirectory)
    ]
    let fileManager = FileManager.default
    for directory in candidates {
        let url = directory.appending(path: "Reminders.json")
        if fileManager.fileExists(atPath: url.path) { return url }
    }
    return candidates[0].appending(path: "Reminders.json")
}

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func loadStore() -> Store {
    let url = storeURL()
    guard let data = try? Data(contentsOf: url) else {
        die("找不到数据文件：\(url.path)（浮光提醒启动过一次吗？）")
    }
    do {
        return try JSONDecoder().decode(Store.self, from: data)
    } catch {
        die("数据文件无法解析：\(error.localizedDescription)")
    }
}

func saveStore(_ store: Store) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(store)
    let url = storeURL()
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        die("写入失败：\(error.localizedDescription)")
    }
    DistributedNotificationCenter.default().postNotificationName(reloadNotification, object: nil, userInfo: nil, deliverImmediately: true)
}

func parseDue(_ raw: String) -> Date? {
    let formats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd"]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    for format in formats {
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}

func parseArgs(_ args: [String]) -> ([String], [String: String]) {
    var positionals = [String]()
    var options = [String: String]()
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                options[key] = args[index + 1]
                index += 2
                continue
            }
            options[key] = "true"
            index += 1
            continue
        }
        positionals.append(arg)
        index += 1
    }
    return (positionals, options)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("er —— 浮光提醒命令行\n\n用法：\n  er add <事项> [--due \"yyyy-MM-dd [HH:mm]\"] [--tag <标签>] [--priority high|medium|low]\n  er list [--all]\n  er done <标题或ID前缀>\n  er report\n\n数据文件：\(storeURL().path)")
    exit(0)
}

let (positionals, options) = parseArgs(Array(arguments.dropFirst()))

let calendar = Calendar.current
switch command {
case "add":
    guard !positionals.isEmpty else { die("用法：er add <事项> [--due ...] [--tag ...] [--priority ...]") }
    var store = loadStore()
    if store.lists == nil { store.lists = [] }
    if !store.lists!.contains(where: { $0.id == inboxID }) {
        store.lists?.insert(Store.List(id: inboxID, title: "收件箱", source: "local", isWritable: true, accountName: nil), at: 0)
    }
    var dueDate: Date?
    var hasTime = false
    if let raw = options["due"] {
        guard let date = parseDue(raw) else { die("无法解析日期：\(raw)（支持 yyyy-MM-dd 或 yyyy-MM-dd HH:mm）") }
        dueDate = date
        hasTime = raw.contains(":")
    }
    let priority = (options["priority"] == "high") ? "high" : (options["priority"] == "medium") ? "medium" : (options["priority"] == "low") ? "low" : "none"
    var tags = options["tag"].map { [$0] }
    if let existing = tags {
        let firstLine = positionals.joined(separator: " ").split(whereSeparator: \.isNewline).first.map(String.init)
        if let firstLine {
            let fromText = firstLine.components(separatedBy: "#").dropFirst().compactMap { chunk -> String? in
                let tag = chunk.split { $0 == " " || $0 == "，" || $0 == "," }.first.map(String.init)
                return (tag?.isEmpty == false) ? tag : nil
            }
            tags = (existing + fromText).uniqued()
        }
    }
    let item = Item(
        id: UUID().uuidString,
        listID: inboxID,
        title: positionals.joined(separator: " "),
        notes: "",
        dueDate: dueDate,
        hasTime: hasTime,
        alerts: hasTime,
        isCompleted: false,
        completionDate: nil,
        priority: priority,
        repeatRule: "never",
        source: "local",
        isWritable: true,
        repeatAnchor: nil,
        generatedBy: nil,
        snoozedUntil: nil,
        subtasks: nil,
        resources: nil,
        tags: tags?.isEmpty == true ? nil : tags,
        dependsOn: nil
    )
    store.items.append(item)
    saveStore(store)
    let dueText = dueDate.map { " · 截止 \($0.formatted(.dateTime.year().month().day().hour().minute()))" } ?? ""
    print("已添加：\(item.title)\(dueText)（收件箱）")

case "list":
    let store = loadStore()
    let now = Date.now
    var items = store.items.filter { !$0.isCompleted }
    if options["all"] == nil {
        items = items.filter { item in
            item.dueDate.map { calendar.isDate($0, inSameDayAs: now) } == true
        }
    }
    items.sort { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    guard !items.isEmpty else {
        print(options["all"] == nil ? "今天没有待办。" : "没有待办。")
        exit(0)
    }
    for item in items {
        let time = item.dueDate.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "无日期"
        let priorityMark = item.priority == "high" ? "!" : item.priority == "medium" ? "△" : " "
        let tagText = item.tags.map { $0.map { "#\($0)" }.joined(separator: " ") } ?? ""
        print("\(priorityMark) \(time.padding(toLength: 13, withPad: " ", startingAt: 0))  \(item.title)\(tagText.isEmpty ? "" : "  " + tagText)")
    }

case "done":
    guard let query = positionals.first, !query.isEmpty else { die("用法：er done <标题或ID前缀>") }
    var store = loadStore()
    let match = store.items.first {
        $0.id.hasPrefix(query) || $0.title.localizedCaseInsensitiveContains(query)
    }
    guard let item = match, !item.isCompleted else {
        die("没找到未完成的事项：\(query)")
    }
    guard let index = store.items.firstIndex(where: { $0.id == item.id }) else { die("内部错误") }
    store.items[index].isCompleted = true
    store.items[index].completionDate = .now
    saveStore(store)
    print("已完成：\(item.title)")

case "report":
    let store = loadStore()
    let now = Date.now
    let open = store.items.filter { !$0.isCompleted }
    let overdue = open.filter { $0.dueDate.map { $0 < calendar.startOfDay(for: now) } == true }
    let today = open.filter { $0.dueDate.map { calendar.isDate($0, inSameDayAs: now) } == true }
    let completedThisWeek = store.items.filter {
        $0.isCompleted && $0.completionDate.map { $0 >= calendar.date(byAdding: .day, value: -7, to: now)! } == true
    }
    print("待办 \(open.count) 项 · 今天 \(today.count) 项 · 逾期 \(overdue.count) 项 · 近 7 天完成 \(completedThisWeek.count) 项")
    if !overdue.isEmpty {
        print("\n逾期：")
        for item in overdue.sorted(by: { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }) {
            print("  · \(item.title)")
        }
    }

default:
    die("未知命令：\(command)（可用 add / list / done / report）")
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
