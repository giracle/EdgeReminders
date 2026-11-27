import AppKit
import Combine
import EventKit
import UserNotifications

enum ReminderSource: String, Codable, CaseIterable {
    case local, apple

    var label: String {
        switch self {
        case .local: "本机"
        case .apple: "Apple 提醒事项"
        }
    }
}

enum ReminderAccess: String, Equatable {
    case unavailable, notDetermined, requesting, denied, allowed

    var label: String {
        switch self {
        case .unavailable: "当前不可用"
        case .notDetermined: "尚未授权"
        case .requesting: "等待授权"
        case .denied: "未获得权限"
        case .allowed: "已授权"
        }
    }
}

enum ReminderPriority: String, Codable, CaseIterable {
    case none, low, medium, high, custom

    var label: String {
        switch self {
        case .none: "无"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .custom: "自定义"
        }
    }

    fileprivate init(eventKit value: Int) {
        switch value {
        case 0: self = .none
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .custom
        }
    }

    fileprivate var eventKitValue: Int {
        switch self {
        case .none, .custom: 0
        case .low: 9
        case .medium: 5
        case .high: 1
        }
    }
}

enum ReminderRepeat: String, Codable, CaseIterable {
    case never, daily, weekly, monthly, yearly, custom

    var label: String {
        switch self {
        case .never: "不重复"
        case .daily: "每天"
        case .weekly: "每周"
        case .monthly: "每月"
        case .yearly: "每年"
        case .custom: "自定义重复"
        }
    }

    fileprivate init(eventKit rules: [EKRecurrenceRule]?) {
        guard let rules, !rules.isEmpty else { self = .never; return }
        guard rules.count == 1, let rule = rules.first, rule.interval == 1,
              rule.recurrenceEnd == nil, rule.daysOfTheWeek?.isEmpty != false,
              rule.daysOfTheMonth?.isEmpty != false, rule.daysOfTheYear?.isEmpty != false,
              rule.monthsOfTheYear?.isEmpty != false, rule.weeksOfTheYear?.isEmpty != false,
              rule.setPositions?.isEmpty != false else { self = .custom; return }

        switch rule.frequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        @unknown default: self = .custom
        }
    }

    fileprivate var eventKitRule: EKRecurrenceRule? {
        let frequency: EKRecurrenceFrequency
        switch self {
        case .never, .custom: return nil
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)
    }

    fileprivate func nextDate(after reference: Date, anchor: Date) -> Date? {
        let unit: Calendar.Component
        switch self {
        case .never, .custom: return nil
        case .daily: unit = .day
        case .weekly: unit = .weekOfYear
        case .monthly: unit = .month
        case .yearly: unit = .year
        }
        let calendar = Calendar.current
        let elapsed = calendar.dateComponents([unit], from: anchor, to: reference).value(for: unit) ?? 0
        let minimum = max(1, elapsed)
        for interval in minimum...(minimum + 2) {
            if let candidate = calendar.date(byAdding: unit, value: interval, to: anchor), candidate > reference {
                return candidate
            }
        }
        return nil
    }
}

struct ReminderList: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    let source: ReminderSource
    let isWritable: Bool
    let accountName: String?
}

struct ReminderSubtask: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var isCompleted = false
}

struct ReminderTemplate: Identifiable, Hashable, Codable {
    var id = UUID()
    let name: String
    let subtaskTitles: [String]

    func newSubtasks() -> [ReminderSubtask] {
        subtaskTitles.map { ReminderSubtask(title: $0) }
    }
}

struct ReminderItem: Identifiable, Hashable, Codable {
    let id: String
    var listID: String
    var title: String
    var notes: String
    var dueDate: Date?
    var hasTime: Bool
    var alerts: Bool
    var isCompleted: Bool
    var completionDate: Date?
    var priority: ReminderPriority
    var repeatRule: ReminderRepeat
    let source: ReminderSource
    let isWritable: Bool
    fileprivate var repeatAnchor: Date?
    fileprivate var generatedBy: String?
    fileprivate var storedSubtasks: [ReminderSubtask]?
    var snoozedUntil: Date?
    fileprivate var storedResources: [ReminderResource]?
    fileprivate var storedTags: [String]?
    fileprivate var storedDependsOn: [String]?

    var subtasks: [ReminderSubtask] { storedSubtasks ?? [] }
    var resources: [ReminderResource] { storedResources ?? [] }
    var tags: [String] { storedTags ?? [] }
    var dependsOn: [String] { storedDependsOn ?? [] }

    var localNotificationDate: Date? {
        guard source == .local, !isCompleted else { return nil }
        return snoozedUntil ?? (alerts && hasTime ? dueDate : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, listID, title, notes, dueDate, hasTime, alerts, isCompleted, completionDate
        case priority, repeatRule, source, isWritable, repeatAnchor, generatedBy, snoozedUntil
        case storedSubtasks = "subtasks"
        case storedResources = "resources"
        case storedTags = "tags"
        case storedDependsOn = "dependsOn"
    }

    fileprivate func hasSameEditableFields(as other: Self) -> Bool {
        listID == other.listID && title == other.title && notes == other.notes
            && dueDate == other.dueDate && hasTime == other.hasTime && alerts == other.alerts
            && priority == other.priority && repeatRule == other.repeatRule
            && snoozedUntil == other.snoozedUntil && resources == other.resources
            && tags == other.tags && dependsOn == other.dependsOn
            && subtasks.elementsEqual(other.subtasks) { $0.title == $1.title && $0.isCompleted == $1.isCompleted }
    }
}

struct ReminderDraft: Equatable {
    var id: String?
    var listID: String
    var title = ""
    var notes = ""
    var dueDate: Date?
    var hasTime = false
    var alerts = false
    var priority = ReminderPriority.none
    var repeatRule = ReminderRepeat.never
    var subtasks = [ReminderSubtask]()
    var resources = [ReminderResource]()
    var tags = [String]()
    var dependsOn = [String]()
    fileprivate var original: ReminderItem?

    init(listID: String) {
        self.listID = listID
    }

    init(_ item: ReminderItem) {
        id = item.id
        listID = item.listID
        title = item.title
        notes = item.notes
        dueDate = item.dueDate
        hasTime = item.hasTime
        alerts = item.alerts
        priority = item.priority
        repeatRule = item.repeatRule
        subtasks = item.subtasks
        resources = item.resources
        tags = item.tags
        dependsOn = item.dependsOn
        original = item
    }
}

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var lists = [ReminderList]()
    @Published private(set) var tasks = [ReminderItem]()
    @Published private(set) var access = ReminderAccess.notDetermined
    @Published private(set) var notifications = ReminderAccess.unavailable
    @Published private(set) var pinnedTaskIDs = [String]()
    @Published private(set) var templates = [ReminderTemplate]()
    @Published private(set) var smartLists = [SmartList]()
    @Published private(set) var archivedTasks = [ReminderItem]()
    @Published private(set) var lastCompletedID: UUID?
    @Published var errorMessage: String?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private struct LocalData: Codable {
        static let inbox = ReminderList(id: "local-inbox", title: "收件箱", source: .local, isWritable: true, accountName: nil)

        var lists = [Self.inbox]
        var items = [ReminderItem]()
        var pinnedTaskIDs: [String]?
        var templates: [ReminderTemplate]?
        var appleResources: [String: [ReminderResource]]?
        var smartLists: [SmartList]?
        var archivedItems: [ReminderItem]?

        mutating func setAppleResources(_ resources: [ReminderResource], for id: String) {
            if resources.isEmpty {
                appleResources?[id] = nil
            } else {
                appleResources = appleResources ?? [:]
                appleResources?[id] = resources
            }
        }
    }

    private enum StoreError: LocalizedError {
        case emptyTitle, missing, readOnly, sameSourceRequired, dueDateRequired, invalidCustomRule, storageUnreadable
        case localSubtasks, localSnooze, invalidSnoozeDate, completedSnooze, duplicateSubtasks, emptyTemplate
        case localDependencies, dependencyCycle
        case invalidBackup

        var errorDescription: String? {
            switch self {
            case .emptyTitle: "请输入名称。"
            case .missing: "这个事项或清单已不可用。请刷新后重试。"
            case .readOnly: "这个清单目前无法编辑。"
            case .sameSourceRequired: "只能将事项移到同一来源的清单。"
            case .dueDateRequired: "设置重复前，请先选择日期。"
            case .invalidCustomRule: "请从可用的重复规则中选择。"
            case .storageUnreadable: "无法读取本机清单。原文件已保留，请检查应用支持目录。"
            case .localSubtasks: "子任务可以添加到本机清单。"
            case .localSnooze: "稍后提醒可以用于本机事项。"
            case .invalidSnoozeDate: "请选择未来的提醒时间。"
            case .completedSnooze: "已完成的事项无法安排稍后提醒。"
            case .duplicateSubtasks: "有重复的子任务。请移除重复项后再保存。"
            case .emptyTemplate: "模板需要至少一个子任务。"
            case .localDependencies: "前置依赖可以设置在本机事项上。"
            case .dependencyCycle: "依赖关系出现了循环。请调整前置事项。"
            case .invalidBackup: "无法识别的备份文件。请确认是浮光提醒导出的备份。"
            }
        }
    }

    private let localURL: URL
    private let notificationCenter: UNUserNotificationCenter?
    private let eventStore = EKEventStore()
    private var local = LocalData()
    private var localReadable = true
    private var undoStack: [LocalData] = []
    private var redoStack: [LocalData] = []
    private static let undoLimit = 30
    private var appleLists = [ReminderList]()
    private var appleItems = [ReminderItem]()
    private var subscriptions = Set<AnyCancellable>()
    private var fetchToken: Any?
    private var fetchGeneration = 0
    private var schedulingTask: Task<Void, Never>?
    private var schedulingGeneration = 0
    private static let notificationPrefix = "local-reminder."

    init(localURL: URL? = nil, enablesNotifications: Bool = true) {
        self.localURL = localURL ?? URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "EdgeReminders", directoryHint: .isDirectory)
            .appending(path: "Reminders.json")
        notificationCenter = enablesNotifications ? .current() : nil
        do {
            local = try JSONDecoder().decode(LocalData.self, from: Data(contentsOf: self.localURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            localReadable = false
            errorMessage = StoreError.storageUnreadable.localizedDescription
        }

        publish()
        refresh()
        updateNotificationSchedule()
        let changes = NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: eventStore)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
        changes.sink { [weak self] notification in
            let becameActive = notification.name == NSApplication.didBecomeActiveNotification
            Task { @MainActor in
                self?.refresh()
                if becameActive { self?.updateNotificationSchedule() }
            }
        }.store(in: &subscriptions)
    }

    func requestAppleAccess() async {
        guard access != .requesting else { return }
        access = .requesting
        do {
            _ = try await eventStore.requestFullAccessToReminders()
        } catch {
            errorMessage = error.localizedDescription
        }
        access = appleAuthorization
        refresh()
    }

    func requestNotifications() async {
        guard let notificationCenter, notifications != .requesting else { return }
        notifications = .requesting
        do {
            _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
        } catch {
            if (error as? UNError)?.code != .notificationsNotAllowed {
                errorMessage = "无法请求本机通知权限。请在系统设置中检查通知权限。"
            }
        }
        notifications = .notDetermined
        updateNotificationSchedule()
    }

    /// 从磁盘重新加载本机清单（er 等外部工具写入后调用）。
    func reloadLocal() {
        do {
            local = try JSONDecoder().decode(LocalData.self, from: Data(contentsOf: localURL))
            localReadable = true
        } catch {
            return
        }
        publish()
        updateNotificationSchedule()
    }

    func refresh() {
        guard access != .requesting else { return }
        access = appleAuthorization
        fetchGeneration += 1
        if let fetchToken { eventStore.cancelFetchRequest(fetchToken) }
        fetchToken = nil
        guard access == .allowed else {
            appleLists = []
            appleItems = []
            publish()
            return
        }

        appleLists = eventStore.calendars(for: .reminder).map { calendar in
            ReminderList(id: calendar.calendarIdentifier, title: calendar.title, source: .apple,
                         isWritable: calendar.allowsContentModifications, accountName: calendar.source?.title)
        }
        let requestGeneration = fetchGeneration
        let predicate = eventStore.predicateForReminders(in: nil)
        fetchToken = eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor in
                guard let self, self.fetchGeneration == requestGeneration else { return }
                self.fetchToken = nil
                if let reminders {
                    self.appleItems = reminders.compactMap(Self.item(from:))
                }
                self.publish()
            }
        }
        publish()
    }

    func save(_ draft: ReminderDraft) throws {
        let existing = try draft.id.map { id in
            guard let item = tasks.first(where: { $0.id == id }) else { throw StoreError.missing }
            return item
        }
        guard let list = lists.first(where: { $0.id == draft.listID }) else { throw StoreError.missing }
        guard list.isWritable, existing?.isWritable != false else { throw StoreError.readOnly }
        if let existing, existing.source != list.source { throw StoreError.sameSourceRequired }
        let original = draft.original
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty, original?.title != draft.title { throw StoreError.emptyTitle }
        if draft.repeatRule != .never, draft.dueDate == nil,
           original?.repeatRule != draft.repeatRule || original?.dueDate != draft.dueDate {
            throw StoreError.dueDateRequired
        }
        if draft.repeatRule == .custom, original?.repeatRule != .custom { throw StoreError.invalidCustomRule }

        switch list.source {
        case .local:
            let date = normalizedLocalDate(draft.dueDate, hasTime: draft.hasTime)
            let scheduleChanged = existing?.dueDate != date || existing?.repeatRule != draft.repeatRule
            let subtasks = try localSubtasks(for: draft, existing: existing)
            let resources = draft.resources == original?.resources ? existing?.resources ?? [] : distinctResources(draft.resources)
            let tags = Self.cleanTags(draft.tags)
            let item = ReminderItem(id: draft.id ?? UUID().uuidString, listID: list.id, title: title,
                                    notes: draft.notes, dueDate: date, hasTime: date != nil && draft.hasTime,
                                    alerts: date != nil && draft.hasTime && draft.alerts,
                                    isCompleted: existing?.isCompleted ?? false, completionDate: existing?.completionDate,
                                    priority: draft.priority, repeatRule: draft.repeatRule, source: .local, isWritable: true,
                                    repeatAnchor: scheduleChanged ? date : existing?.repeatAnchor,
                                    generatedBy: existing?.generatedBy, storedSubtasks: subtasks,
                                    snoozedUntil: existing?.snoozedUntil, storedResources: resources,
                                    storedTags: tags.isEmpty ? nil : tags,
                                    storedDependsOn: draft.dependsOn.isEmpty ? nil : draft.dependsOn)
            try changeLocal { data in
                if let index = data.items.firstIndex(where: { $0.id == item.id }) {
                    try ensureNoDependencyCycle(itemID: item.id, prerequisites: item.dependsOn, in: data)
                    data.items[index] = item
                } else {
                    data.items.append(item)
                }
            }
        case .apple:
            guard draft.subtasks.isEmpty else { throw StoreError.localSubtasks }
            try saveApple(draft, title: title, existing: existing)
        }
    }

    func capture(title: String, notes: String, resources: [ReminderResource]) throws {
        let item = ReminderItem(id: UUID().uuidString, listID: LocalData.inbox.id, title: try listTitle(title),
                                notes: notes, hasTime: false, alerts: false, isCompleted: false,
                                priority: .none, repeatRule: .never, source: .local, isWritable: true,
                                storedResources: distinctResources(resources))
        try changeLocal { data in
            if !data.lists.contains(where: { $0.id == LocalData.inbox.id }) {
                data.lists.insert(LocalData.inbox, at: 0)
            }
            data.items.append(item)
        }
    }

    /// 自然语言快速新增：能解析出日期就带上，否则原样进收件箱。
    func quickAdd(_ text: String, now: Date = .now) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyTitle }
        if let parsed = QuickEntryParser.parse(trimmed, now: now) {
            var draft = ReminderDraft(listID: LocalData.inbox.id)
            draft.title = parsed.title
            draft.dueDate = parsed.date
            draft.hasTime = parsed.hasTime
            draft.alerts = parsed.hasTime
            try save(draft)
        } else {
            try capture(title: trimmed, notes: "", resources: [])
        }
    }

    func resources(for item: ReminderItem) -> [ReminderResource] {
        tasks.first { $0.id == item.id && $0.source == item.source }?.resources ?? []
    }

    func saveResources(_ resources: [ReminderResource], for item: ReminderItem) throws {
        guard let current = tasks.first(where: { $0.id == item.id && $0.source == item.source }) else {
            throw StoreError.missing
        }
        let resources = distinctResources(resources)
        guard current.resources != resources else { return }
        try changeLocal { data in
            switch item.source {
            case .local:
                guard let index = data.items.firstIndex(where: { $0.id == item.id }) else { throw StoreError.missing }
                data.items[index].storedResources = resources
            case .apple:
                data.setAppleResources(resources, for: item.id)
            }
        }
    }

    func setSubtaskCompleted(_ parent: ReminderItem, subtaskID: UUID, completed: Bool) throws {
        guard parent.source == .local else { throw StoreError.localSubtasks }
        try changeLocal { data in
            guard let index = data.items.firstIndex(where: { $0.id == parent.id }),
                  let subtaskIndex = data.items[index].subtasks.firstIndex(where: { $0.id == subtaskID }) else {
                throw StoreError.missing
            }
            data.items[index].storedSubtasks?[subtaskIndex].isCompleted = completed
        }
    }

    func setCompleted(_ item: ReminderItem, _ completed: Bool) throws {
        switch item.source {
        case .local:
            try changeLocal { data in
                guard let index = data.items.firstIndex(where: { $0.id == item.id }) else { throw StoreError.missing }
                guard data.items[index].isCompleted != completed else { return }
                let now = Date()
                let stored = data.items[index]
                var next: ReminderItem?
                if let due = stored.dueDate, let reference = completed ? now : stored.completionDate,
                   let date = stored.repeatRule.nextDate(after: max(due, reference), anchor: stored.repeatAnchor ?? due) {
                    next = ReminderItem(id: UUID().uuidString, listID: stored.listID, title: stored.title,
                                        notes: stored.notes, dueDate: date, hasTime: stored.hasTime,
                                        alerts: stored.alerts, isCompleted: false, completionDate: nil,
                                        priority: stored.priority, repeatRule: stored.repeatRule, source: .local,
                                        isWritable: true, repeatAnchor: stored.repeatAnchor ?? due, generatedBy: stored.id,
                                        storedSubtasks: stored.subtasks.map { ReminderSubtask(title: $0.title) },
                                        storedResources: stored.storedResources)
                }
                data.items[index].isCompleted = completed
                data.items[index].completionDate = completed ? now : nil
                if completed, let next, !data.items.contains(where: { $0.generatedBy == stored.id }) {
                    data.items.append(next)
                } else if !completed, let next {
                    // Only remove an untouched pending occurrence when reversing a completion.
                    let pins = Set(data.pinnedTaskIDs ?? [])
                    data.items.removeAll { candidate in
                        guard candidate.generatedBy == stored.id else { return false }
                        return !candidate.isCompleted && !pins.contains(candidate.id)
                            && candidate.hasSameEditableFields(as: next)
                    }
                }
            }
            if completed { lastCompletedID = UUID() }
        case .apple:
            let reminder = try writableAppleItem(item.id)
            guard reminder.isCompleted != completed else { return }
            reminder.isCompleted = completed
            try commitApple(reminder, previousID: item.id)
        }
    }

    func snooze(_ item: ReminderItem, until date: Date?) throws {
        guard item.source == .local else { throw StoreError.localSnooze }
        if let date, date <= .now { throw StoreError.invalidSnoozeDate }
        try changeLocal { data in
            guard let index = data.items.firstIndex(where: { $0.id == item.id }) else { throw StoreError.missing }
            if date != nil, data.items[index].isCompleted { throw StoreError.completedSnooze }
            data.items[index].snoozedUntil = date
        }
    }

    func setPinned(_ item: ReminderItem, _ pinned: Bool) throws {
        guard tasks.contains(where: { $0.id == item.id && $0.source == item.source }) else { throw StoreError.missing }
        guard pinnedTaskIDs.contains(item.id) != pinned else { return }
        try changeLocal { data in
            var ids = data.pinnedTaskIDs ?? []
            if pinned {
                ids.insert(item.id, at: 0)
            } else {
                ids.removeAll { $0 == item.id }
            }
            data.pinnedTaskIDs = ids
        }
    }

    func createTemplate(name: String, subtasks: [ReminderSubtask]) throws {
        let title = try listTitle(name)
        guard !subtasks.isEmpty else { throw StoreError.emptyTemplate }
        let titles = try subtasks.map { try listTitle($0.title) }
        try changeLocal { data in
            data.templates = (data.templates ?? []) + [ReminderTemplate(name: title, subtaskTitles: titles)]
        }
    }

    func deleteTemplate(_ template: ReminderTemplate) throws {
        try changeLocal { $0.templates?.removeAll { $0.id == template.id } }
    }

    func delete(_ item: ReminderItem) throws {
        switch item.source {
        case .local:
            try changeLocal {
                $0.items.removeAll { $0.id == item.id }
                $0.pinnedTaskIDs?.removeAll { $0 == item.id }
            }
        case .apple:
            let reminder = try writableAppleItem(item.id)
            try eventStore.remove(reminder, commit: true)
            appleItems.removeAll { $0.id == item.id }
            refresh()
            if pinnedTaskIDs.contains(item.id) || local.appleResources?[item.id] != nil {
                try? changeLocal { data in
                    data.pinnedTaskIDs?.removeAll { $0 == item.id }
                    data.setAppleResources([], for: item.id)
                }
            }
        }
    }

    func createLocalList(_ name: String) throws {
        let title = try listTitle(name)
        try changeLocal { data in
            data.lists.append(ReminderList(id: UUID().uuidString, title: title, source: .local,
                                           isWritable: true, accountName: nil))
        }
    }

    func renameLocalList(_ list: ReminderList, to name: String) throws {
        let title = try listTitle(name)
        try changeLocal { data in
            guard let index = data.lists.firstIndex(where: { $0.id == list.id }) else { throw StoreError.missing }
            data.lists[index].title = title
        }
    }

    func deleteLocalList(_ list: ReminderList) throws {
        guard list.source == .local else { throw StoreError.readOnly }
        try changeLocal { data in
            data.lists.removeAll { $0.id == list.id }
            let deletedIDs = Set(data.items.lazy.filter { $0.listID == list.id }.map(\.id))
            data.items.removeAll { $0.listID == list.id }
            data.pinnedTaskIDs?.removeAll { deletedIDs.contains($0) }
            if data.lists.isEmpty { data.lists = LocalData().lists }
        }
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(local)
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(local)
        restore(snapshot)
    }

    // MARK: - Tags

    static func cleanTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result = [String]()
        for value in raw {
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    func setTags(_ item: ReminderItem, tags: [String]) throws {
        let cleaned = Self.cleanTags(tags)
        try changeLocal { data in
            guard let index = data.items.firstIndex(where: { $0.id == item.id }) else { throw StoreError.missing }
            data.items[index].storedTags = cleaned.isEmpty ? nil : cleaned
        }
    }

    var allTags: [String] {
        Set(tasks.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Dependencies

    func setDependsOn(_ item: ReminderItem, prerequisites: [String]) throws {
        guard item.source == .local else { throw StoreError.localDependencies }
        let ids = Array(Set(prerequisites))
        try changeLocal { data in
            guard let index = data.items.firstIndex(where: { $0.id == item.id }) else { throw StoreError.missing }
            try ensureNoDependencyCycle(itemID: item.id, prerequisites: ids, in: data)
            data.items[index].storedDependsOn = ids.isEmpty ? nil : ids
        }
    }

    private func ensureNoDependencyCycle(itemID: String, prerequisites: [String], in data: LocalData) throws {
        guard !prerequisites.isEmpty else { return }
        guard !prerequisites.contains(itemID) else { throw StoreError.dependencyCycle }
        let graph = Dictionary(uniqueKeysWithValues: data.items
            .filter { $0.source == .local }
            .map { ($0.id, $0.storedDependsOn ?? []) })
        var stack = prerequisites
        var visited = Set<String>()
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            if current == itemID { throw StoreError.dependencyCycle }
            stack.append(contentsOf: graph[current] ?? [])
        }
    }

    func blockedTaskIDs() -> Set<String> {
        let open = Set(tasks.filter { !$0.isCompleted }.map(\.id))
        return Set(tasks.lazy
            .filter { !$0.isCompleted && !$0.dependsOn.isEmpty }
            .filter { $0.dependsOn.contains(where: open.contains) }
            .map(\.id))
    }

    // MARK: - Smart lists

    func createSmartList(name: String, rule: SmartRule) throws {
        let title = try listTitle(name)
        try changeLocal { data in
            var smart = data.smartLists ?? []
            smart.append(SmartList(name: title, rule: rule))
            data.smartLists = smart
        }
    }

    func deleteSmartList(_ list: SmartList) throws {
        try changeLocal { data in
            data.smartLists?.removeAll { $0.id == list.id }
        }
    }

    func items(matching rule: SmartRule, at now: Date = .now) -> [ReminderItem] {
        tasks.filter { rule.matches($0, at: now) }
    }

    // MARK: - Archive

    func archive(_ items: [ReminderItem]) throws {
        let ids = Set(items.map(\.id))
        guard !ids.isEmpty else { return }
        try changeLocal { data in
            var archived = data.archivedItems ?? []
            archived.append(contentsOf: data.items.filter { ids.contains($0.id) })
            data.items.removeAll { ids.contains($0.id) }
            data.pinnedTaskIDs?.removeAll { ids.contains($0) }
            data.archivedItems = archived
        }
    }

    func restoreArchived(_ ids: Set<String>) throws {
        try changeLocal { data in
            guard var archived = data.archivedItems, !archived.isEmpty else { return }
            let restored = archived.filter { ids.contains($0.id) }
            data.items.append(contentsOf: restored)
            archived.removeAll { ids.contains($0.id) }
            data.archivedItems = archived.isEmpty ? nil : archived
        }
    }

    func deleteArchived(_ ids: Set<String>) throws {
        try changeLocal { data in
            data.archivedItems?.removeAll { ids.contains($0.id) }
        }
    }

    func archiveCompletedLocalItems() throws {
        try archive(tasks.filter { $0.isCompleted && $0.source == .local })
    }

    // MARK: - Batch

    func setCompletedMany(_ ids: [String], _ completed: Bool) throws {
        let idSet = Set(ids)
        for item in tasks.filter({ idSet.contains($0.id) }) {
            try setCompleted(item, completed)
        }
    }

    // MARK: - Search

    func search(_ query: String, at now: Date = .now) -> [ReminderItem] {
        let parsed = NaturalQueryParser.parse(query, now: now)
        guard !parsed.isEmpty else { return [] }
        let tokens = FuzzySearch.tokens(from: parsed.text)
        let calendar = Calendar.current
        let pool = tasks + archivedTasks
        var result = pool.filter { item in
            if let tag = parsed.tag, !item.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
            if let priority = parsed.priority, item.priority != priority { return false }
            if let due = parsed.date {
                // 未设定日期的事项默认当天到期，只匹配「今天」类日期条件。
                let matchesDate = item.dueDate.map { calendar.isDate($0, inSameDayAs: due) }
                    ?? calendar.isDate(due, inSameDayAs: now)
                if !matchesDate { return false }
            }
            guard !tokens.isEmpty else { return true }
            let listTitle = lists.first { $0.id == item.listID }?.title ?? ""
            let text = FuzzySearch.text(for: item, listTitle: listTitle, resources: resources(for: item))
            return FuzzySearch.matches(text, tokens: tokens)
        }
        result.sort { lhs, rhs in
            let lTitle = tokens.contains { lhs.title.localizedCaseInsensitiveContains($0) }
            let rTitle = tokens.contains { rhs.title.localizedCaseInsensitiveContains($0) }
            if lTitle != rTitle { return lTitle }
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
        }
        return result
    }

    // MARK: - Backup

    func backupData() -> Data {
        (try? JSONEncoder().encode(local)) ?? Data("{}".utf8)
    }

    func restore(from data: Data) throws {
        let decoded: LocalData
        do {
            decoded = try JSONDecoder().decode(LocalData.self, from: data)
        } catch {
            throw StoreError.invalidBackup
        }
        var updated = decoded
        if !updated.lists.contains(where: { $0.id == LocalData.inbox.id }) {
            updated.lists.insert(LocalData.inbox, at: 0)
        }
        pushUndo(local)
        redoStack.removeAll()
        local = updated
        publish()
        updateNotificationSchedule()
    }

    private var appleAuthorization: ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .allowed
        case .notDetermined: .notDetermined
        case .denied, .restricted, .writeOnly: .denied
        @unknown default: .unavailable
        }
    }

    private func listTitle(_ name: String) throws -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.emptyTitle }
        return title
    }

    private func localSubtasks(for draft: ReminderDraft, existing: ReminderItem?) throws -> [ReminderSubtask] {
        let original = draft.original?.subtasks ?? []
        let current = existing?.subtasks ?? []
        if original == draft.subtasks { return current }
        guard Set(draft.subtasks.map(\.id)).count == draft.subtasks.count else { throw StoreError.duplicateSubtasks }

        let previousStates = Dictionary(original.map { ($0.id, $0.isCompleted) }, uniquingKeysWith: { first, _ in first })
        let currentStates = Dictionary(current.map { ($0.id, $0.isCompleted) }, uniquingKeysWith: { first, _ in first })
        return try draft.subtasks.map { subtask in
            var edited = subtask
            edited.title = try listTitle(edited.title)
            if previousStates[edited.id] == edited.isCompleted, let state = currentStates[edited.id] {
                edited.isCompleted = state
            }
            return edited
        }
    }

    private func publish() {
        lists = local.lists + appleLists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        tasks = local.items + appleItems.map { item in
            var item = item
            item.storedResources = local.appleResources?[item.id]
            return item
        }
        let pins = local.pinnedTaskIDs ?? []
        let templates = local.templates ?? []
        let smart = local.smartLists ?? []
        let archived = local.archivedItems ?? []
        if pinnedTaskIDs != pins { pinnedTaskIDs = pins }
        if self.templates != templates { self.templates = templates }
        if self.smartLists != smart { self.smartLists = smart }
        if self.archivedTasks != archived { self.archivedTasks = archived }
    }

    private func changeLocal(_ edit: (inout LocalData) throws -> Void) throws {
        guard localReadable else { throw StoreError.storageUnreadable }
        var updated = local
        try edit(&updated)
        try writeLocal(updated)
        pushUndo(local)
        redoStack.removeAll()
        local = updated
        publish()
        updateNotificationSchedule()
    }

    private func pushUndo(_ snapshot: LocalData) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
    }

    private func restore(_ data: LocalData) {
        local = data
        publish()
        updateNotificationSchedule()
    }

    private func writeLocal(_ data: LocalData) throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(data).write(to: localURL, options: .atomic)
    }

    private func distinctResources(_ resources: [ReminderResource]) -> [ReminderResource] {
        var urls = Set<URL>()
        return resources.filter { urls.insert($0.url).inserted }
    }

    private func normalizedLocalDate(_ date: Date?, hasTime: Bool) -> Date? {
        guard let date else { return nil }
        let calendar = Calendar.current
        return hasTime ? calendar.dateInterval(of: .minute, for: date)?.start ?? date : calendar.startOfDay(for: date)
    }

    private static func date(from components: DateComponents?) -> Date? {
        guard var components else { return nil }
        let calendar = components.calendar ?? Calendar(identifier: .gregorian)
        components.calendar = calendar
        return components.date
    }

    private static func isDueAlarm(_ alarm: EKAlarm, due: Date?, start: Date?) -> Bool {
        guard alarm.type == .display, alarm.structuredLocation == nil, let due else { return false }
        if let absolute = alarm.absoluteDate { return abs(absolute.timeIntervalSince(due)) < 1 }
        return abs((start ?? due).addingTimeInterval(alarm.relativeOffset).timeIntervalSince(due)) < 1
    }

    private static func item(from reminder: EKReminder) -> ReminderItem? {
        guard let calendar = reminder.calendar else { return nil }
        let due = date(from: reminder.dueDateComponents)
        let start = date(from: reminder.startDateComponents)
        return ReminderItem(id: reminder.calendarItemIdentifier, listID: calendar.calendarIdentifier,
                            title: reminder.title ?? "未命名事项", notes: reminder.notes ?? "", dueDate: due,
                            hasTime: reminder.dueDateComponents?.hour != nil,
                            alerts: reminder.alarms?.contains { isDueAlarm($0, due: due, start: start) } ?? false,
                            isCompleted: reminder.isCompleted, completionDate: reminder.completionDate,
                            priority: ReminderPriority(eventKit: reminder.priority),
                            repeatRule: ReminderRepeat(eventKit: reminder.recurrenceRules), source: .apple,
                            isWritable: calendar.allowsContentModifications)
    }

    private func writableAppleItem(_ id: String) throws -> EKReminder {
        guard appleAuthorization == .allowed else { throw StoreError.readOnly }
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { throw StoreError.missing }
        guard reminder.calendar?.allowsContentModifications == true else { throw StoreError.readOnly }
        return reminder
    }

    private func saveApple(_ draft: ReminderDraft, title: String, existing: ReminderItem?) throws {
        guard appleAuthorization == .allowed else { throw StoreError.readOnly }
        guard let calendar = eventStore.calendar(withIdentifier: draft.listID), calendar.allowsContentModifications else {
            throw StoreError.readOnly
        }

        let reminder = try existing.map { try writableAppleItem($0.id) } ?? EKReminder(eventStore: eventStore)
        let original = draft.original ?? existing
        let current = Self.item(from: reminder)
        let changingDate = original?.dueDate != draft.dueDate || (original?.hasTime ?? false) != draft.hasTime
        let changingAlarm = (original?.alerts ?? false) != draft.alerts
        let changingRepeat = (original?.repeatRule ?? .never) != draft.repeatRule
        let changingList = original?.listID != draft.listID
        let changingTitle = original?.title != draft.title
        let changingNotes = (original?.notes ?? "") != draft.notes
        let changingPriority = (original?.priority ?? .none) != draft.priority
        let resources = draft.resources == original?.resources ? nil : distinctResources(draft.resources)
        guard changingDate || changingAlarm || changingRepeat || changingList || changingTitle || changingNotes || changingPriority else {
            if let resources, let existing { try saveResources(resources, for: existing) }
            return
        }

        if changingList { reminder.calendar = calendar }
        if changingTitle { reminder.title = title }
        if changingNotes { reminder.notes = draft.notes.isEmpty ? nil : draft.notes }
        if changingPriority, draft.priority != .custom { reminder.priority = draft.priority.eventKitValue }
        if changingRepeat, draft.repeatRule != .custom {
            reminder.recurrenceRules = draft.repeatRule.eventKitRule.map { [$0] }
        }

        if changingDate {
            let calendar = Calendar(identifier: .gregorian)
            reminder.dueDateComponents = draft.dueDate.map { date in
                let units: Set<Calendar.Component> = draft.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                var components = calendar.dateComponents(units, from: date)
                components.calendar = calendar
                return components
            }
        }
        if changingAlarm || changingDate && current?.alerts == true {
            let oldDue = current?.dueDate
            let oldStart = Self.date(from: reminder.startDateComponents)
            for alarm in reminder.alarms ?? [] where Self.isDueAlarm(alarm, due: oldDue, start: oldStart) {
                reminder.removeAlarm(alarm)
            }
            let enabled = changingAlarm ? draft.alerts : current?.alerts == true
            if enabled, reminder.dueDateComponents?.hour != nil, let due = Self.date(from: reminder.dueDateComponents) {
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
        }
        try commitApple(reminder, previousID: existing?.id, resources: resources)
    }

    private func commitApple(_ reminder: EKReminder, previousID: String?, resources: [ReminderResource]? = nil) throws {
        let previousResources = previousID.flatMap { local.appleResources?[$0] }
        let resourcesToKeep = resources ?? previousResources
        var updatedLocal: LocalData?
        do {
            if let resourcesToKeep, !resourcesToKeep.isEmpty || previousResources != nil {
                // Stage EventKit first to obtain the identifier without publishing a task before its links are stored.
                try eventStore.save(reminder, commit: false)
                let id = reminder.calendarItemIdentifier
                if id != previousID || resourcesToKeep != previousResources {
                    guard localReadable else { throw StoreError.storageUnreadable }
                    var updated = local
                    if let previousID, id != previousID { updated.setAppleResources([], for: previousID) }
                    updated.setAppleResources(resourcesToKeep, for: id)
                    try writeLocal(updated)
                    updatedLocal = updated
                }
                try eventStore.commit()
            } else {
                try eventStore.save(reminder, commit: true)
            }
        } catch {
            if updatedLocal != nil {
                do { try writeLocal(local) }
                catch { localReadable = false }
            }
            eventStore.reset()
            refresh()
            throw error
        }
        if let updatedLocal { local = updatedLocal }
        if let saved = Self.item(from: reminder) {
            appleItems.removeAll { $0.id == saved.id || $0.id == previousID }
            appleItems.append(saved)
        }
        refresh()
    }

    private func updateNotificationSchedule() {
        guard notificationCenter != nil else { return }
        schedulingGeneration += 1
        if schedulingTask == nil {
            schedulingTask = Task { [weak self] in await self?.reconcileNotifications() }
        }
    }

    private func reconcileNotifications() async {
        defer { schedulingTask = nil }
        guard let notificationCenter else { return }
        var generation: Int
        repeat {
            generation = schedulingGeneration
            let settings = await notificationCenter.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                if notifications != .requesting { notifications = .allowed }
                if localReadable { await syncRequests(using: notificationCenter, generation: generation) }
            case .denied:
                if notifications != .requesting { notifications = .denied }
            case .notDetermined:
                if notifications != .requesting { notifications = .notDetermined }
            @unknown default:
                if notifications != .requesting { notifications = .unavailable }
            }
        } while generation != schedulingGeneration
    }

    private func syncRequests(using center: UNUserNotificationCenter, generation: Int) async {
        let pending = await center.pendingNotificationRequests()
        guard generation == schedulingGeneration else { return }
        let owned = pending.filter { $0.identifier.hasPrefix(Self.notificationPrefix) }
        let existingByID = Dictionary(uniqueKeysWithValues: owned.map { ($0.identifier, $0) })
        let scheduled = local.items.compactMap { item in item.localNotificationDate.map { (item, $0) } }
        let activeIDs = Set(scheduled.map { Self.notificationPrefix + $0.0.id })
        let staleIDs = owned.map(\.identifier).filter { !activeIDs.contains($0) }
        if !staleIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: staleIDs) }

        for (item, due) in scheduled {
            guard generation == schedulingGeneration else { return }
            let id = Self.notificationPrefix + item.id
            let units: Set<Calendar.Component> = [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second]
            let components = Calendar.current.dateComponents(units, from: due)
            let existing = existingByID[id]
            if let trigger = existing?.trigger as? UNCalendarNotificationTrigger, trigger.dateComponents == components,
               existing?.content.title == item.title, existing?.content.body == item.notes { continue }
            guard due > Date() else {
                if let trigger = existing?.trigger as? UNCalendarNotificationTrigger,
                   abs((trigger.nextTriggerDate() ?? .distantPast).timeIntervalSince(due)) >= 1,
                   trigger.dateComponents != components {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                }
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.notes
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                if (error as? UNError)?.code == .notificationsNotAllowed {
                    notifications = .denied
                    errorMessage = "事项已保存。请在系统设置中允许浮光提醒发送通知。"
                    return
                }
                errorMessage = "事项已保存，但无法安排定时通知。"
            }
        }
    }
}
