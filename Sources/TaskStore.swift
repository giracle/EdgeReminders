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

    fileprivate func hasSameEditableFields(as other: Self) -> Bool {
        listID == other.listID && title == other.title && notes == other.notes
            && dueDate == other.dueDate && hasTime == other.hasTime && alerts == other.alerts
            && priority == other.priority && repeatRule == other.repeatRule
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
        original = item
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var lists = [ReminderList]()
    @Published private(set) var tasks = [ReminderItem]()
    @Published private(set) var access = ReminderAccess.notDetermined
    @Published private(set) var notifications = ReminderAccess.unavailable
    @Published var errorMessage: String?

    private struct LocalData: Codable {
        var lists = [ReminderList(id: "local-inbox", title: "收件箱", source: .local, isWritable: true, accountName: nil)]
        var items = [ReminderItem]()
    }

    private enum StoreError: LocalizedError {
        case emptyTitle, missing, readOnly, sameSourceRequired, dueDateRequired, invalidCustomRule, storageUnreadable

        var errorDescription: String? {
            switch self {
            case .emptyTitle: "请输入名称。"
            case .missing: "这个事项或清单已不可用。请刷新后重试。"
            case .readOnly: "这个清单目前无法编辑。"
            case .sameSourceRequired: "只能将事项移到同一来源的清单。"
            case .dueDateRequired: "设置重复前，请先选择日期。"
            case .invalidCustomRule: "请从可用的重复规则中选择。"
            case .storageUnreadable: "无法读取本机清单。原文件已保留，请检查应用支持目录。"
            }
        }
    }

    private let localURL: URL
    private let notificationCenter: UNUserNotificationCenter?
    private let eventStore = EKEventStore()
    private var local = LocalData()
    private var localReadable = true
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
            let item = ReminderItem(id: draft.id ?? UUID().uuidString, listID: list.id, title: title,
                                    notes: draft.notes, dueDate: date, hasTime: date != nil && draft.hasTime,
                                    alerts: date != nil && draft.hasTime && draft.alerts,
                                    isCompleted: existing?.isCompleted ?? false, completionDate: existing?.completionDate,
                                    priority: draft.priority, repeatRule: draft.repeatRule, source: .local, isWritable: true,
                                    repeatAnchor: scheduleChanged ? date : existing?.repeatAnchor,
                                    generatedBy: existing?.generatedBy)
            try changeLocal { data in
                if let index = data.items.firstIndex(where: { $0.id == item.id }) {
                    data.items[index] = item
                } else {
                    data.items.append(item)
                }
            }
        case .apple:
            try saveApple(draft, title: title, existing: existing)
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
                                        isWritable: true, repeatAnchor: stored.repeatAnchor ?? due, generatedBy: stored.id)
                }
                data.items[index].isCompleted = completed
                data.items[index].completionDate = completed ? now : nil
                if completed, let next {
                    data.items.append(next)
                } else if !completed, let next {
                    // Only remove an untouched pending occurrence when reversing a completion.
                    data.items.removeAll { candidate in
                        guard candidate.generatedBy == stored.id else { return false }
                        return !candidate.isCompleted && candidate.hasSameEditableFields(as: next)
                    }
                }
            }
        case .apple:
            let reminder = try writableAppleItem(item.id)
            guard reminder.isCompleted != completed else { return }
            reminder.isCompleted = completed
            try commitApple(reminder)
        }
    }

    func delete(_ item: ReminderItem) throws {
        switch item.source {
        case .local:
            try changeLocal { $0.items.removeAll { $0.id == item.id } }
        case .apple:
            let reminder = try writableAppleItem(item.id)
            try eventStore.remove(reminder, commit: true)
            appleItems.removeAll { $0.id == item.id }
            refresh()
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
            data.items.removeAll { $0.listID == list.id }
            if data.lists.isEmpty { data.lists = LocalData().lists }
        }
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

    private func publish() {
        lists = local.lists + appleLists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        tasks = local.items + appleItems
    }

    private func changeLocal(_ edit: (inout LocalData) throws -> Void) throws {
        guard localReadable else { throw StoreError.storageUnreadable }
        var updated = local
        try edit(&updated)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: localURL, options: .atomic)
        local = updated
        publish()
        updateNotificationSchedule()
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
        guard changingDate || changingAlarm || changingRepeat || changingList || changingTitle || changingNotes || changingPriority else { return }

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
        try commitApple(reminder, previousID: existing?.id)
    }

    private func commitApple(_ reminder: EKReminder, previousID: String? = nil) throws {
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            eventStore.reset()
            refresh()
            throw error
        }
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
        let scheduled = local.items.filter { !$0.isCompleted && $0.alerts && $0.hasTime && $0.dueDate != nil }
        let activeIDs = Set(scheduled.map { Self.notificationPrefix + $0.id })
        let staleIDs = owned.map(\.identifier).filter { !activeIDs.contains($0) }
        if !staleIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: staleIDs) }

        for item in scheduled {
            guard generation == schedulingGeneration else { return }
            guard let due = item.dueDate else { continue }
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
