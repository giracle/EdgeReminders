import AppKit
import SwiftUI

@MainActor
struct TaskPanelView: View {
    @ObservedObject var store: TaskStore
    let onOpenManager: () -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var editor: ReminderEditorRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.primary.opacity(0.07))

            if let editor {
                ReminderEditor(store: store, request: editor, compact: true, onClose: closeEditor)
                    .id(editor.id)
            } else {
                TimelineView(.everyMinute) { context in
                    let sections = DueSection.groups(for: store.tasks.filter { !$0.isCompleted }, at: context.date)
                    if sections.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(sections) { section in
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(section.group.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 5)
                                            .padding(.bottom, 3)

                                        ForEach(section.items, id: \.id) { item in
                                            ReminderRow(
                                                item: item,
                                                subtitle: listSubtitle(for: item, in: store.lists),
                                                group: section.group,
                                                onToggle: { perform { try store.setCompleted(item, !item.isCompleted) } },
                                                onOpen: { open(.init(item: item)) }
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                        }
                        .scrollIndicators(.never)
                    }
                }

                if let message = store.errorMessage {
                    errorMessage(message) { store.errorMessage = nil }
                        .padding(.horizontal, 15)
                        .padding(.bottom, 11)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(TaskViewColors.accent)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if editor == nil {
                Text("待完成")
                    .font(.system(size: 17, weight: .semibold))

                let count = store.tasks.lazy.filter { !$0.isCompleted }.count
                if count > 0 {
                    Text("\(count) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(editor?.item == nil ? "新建提醒事项" : "提醒事项详情")
                    .font(.system(size: 16, weight: .semibold))
            }

            Spacer(minLength: 8)

            if editor == nil {
                Button("打开清单", systemImage: "sidebar.left", action: onOpenManager)
                    .labelStyle(.iconOnly)
                    .help("打开清单")
                    .accessibilityIdentifier("open-task-manager")

                Button("新建提醒事项", systemImage: "plus") { open(.init()) }
                    .labelStyle(.iconOnly)
                    .help("新建提醒事项")
                    .accessibilityIdentifier("quick-add-task")
            } else {
                Button("返回待办", systemImage: "xmark", action: closeEditor)
                    .labelStyle(.iconOnly)
                    .help("返回待办")
            }
        }
        .buttonStyle(PanelIconStyle())
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 50)
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("没有待完成事项")
                .font(.callout.weight(.medium))
            if store.access != .allowed {
                Button("连接 Apple 提醒事项", action: onOpenManager)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func open(_ request: ReminderEditorRequest) {
        onEditingChanged(true)
        editor = request
    }

    private func closeEditor() {
        editor = nil
        onEditingChanged(false)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { store.errorMessage = error.localizedDescription }
    }
}

@MainActor
struct TaskManagerView: View {
    @ObservedObject var store: TaskStore

    @State private var selection: TaskScope? = .all
    @State private var search = ""
    @State private var editor: ReminderEditorRequest?
    @State private var listEditor: ListEditorRequest?
    @State private var pendingDeletion: ReminderList?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 226, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .tint(TaskViewColors.accent)
        .sheet(item: $editor) { request in
            ReminderEditor(store: store, request: request, compact: false) { editor = nil }
                .frame(width: 435, height: 460)
        }
        .sheet(item: $listEditor) { request in
            ListEditor(store: store, request: request) { listEditor = nil }
        }
        .confirmationDialog(
            "删除「\(pendingDeletion?.title ?? "")」？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { list in
            Button("删除清单和事项", role: .destructive) {
                perform {
                    try store.deleteLocalList(list)
                    if selection == .list(list.id) { selection = .all }
                }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("清单中的待办和已完成事项都会删除。")
        }
        .onChange(of: store.lists.map(\.id)) { _, ids in
            if case .list(let id) = selection, !ids.contains(id) { selection = .all }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                Label("全部待办", systemImage: "tray")
                    .tag(TaskScope.all)
                Label("今天", systemImage: "calendar")
                    .tag(TaskScope.today)
                Label("已完成", systemImage: "checkmark.circle")
                    .tag(TaskScope.completed)

                Section("本机清单") {
                    ForEach(store.lists.filter { $0.source == .local }, id: \.id) { list in
                        Label(list.title, systemImage: "list.bullet")
                            .tag(TaskScope.list(list.id))
                            .contextMenu {
                                Button("重命名清单") { listEditor = .init(list: list) }
                                Button("删除清单", role: .destructive) { pendingDeletion = list }
                            }
                    }
                    Button("新建本机清单", systemImage: "plus") { listEditor = .init() }
                        .buttonStyle(.plain)
                        .foregroundStyle(TaskViewColors.accent)
                        .accessibilityIdentifier("add-local-list")
                }

                Section("Apple 提醒事项") {
                    switch store.access {
                    case .allowed:
                        let lists = store.lists.filter { $0.source == .apple }
                        if lists.isEmpty {
                            Text("暂无 Apple 清单").foregroundStyle(.secondary)
                        }
                        ForEach(lists, id: \.id) { list in
                            Label(list.title, systemImage: list.isWritable ? "list.bullet" : "lock")
                                .tag(TaskScope.list(list.id))
                        }
                    case .notDetermined:
                        Button("连接 Apple 提醒事项", systemImage: "link") {
                            Task { await store.requestAppleAccess() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(TaskViewColors.accent)
                    case .denied:
                        VStack(alignment: .leading, spacing: 5) {
                            Text("提醒事项权限已关闭").foregroundStyle(.secondary)
                            Button("打开系统设置") { openSystemSettings(.reminders) }
                                .buttonStyle(.link)
                        }
                    case .requesting:
                        ProgressView("等待授权")
                            .controlSize(.small)
                    case .unavailable:
                        Text("Apple 提醒事项不可用").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)

            if store.notifications == .denied || store.notifications == .notDetermined {
                Divider()
                if store.notifications == .denied {
                    Button("通知设置", systemImage: "bell.badge.slash") { openSystemSettings(.notifications) }
                        .buttonStyle(.borderless)
                        .help("在系统设置中开启本机事项通知")
                        .padding(11)
                } else {
                    Button("开启本机通知", systemImage: "bell") {
                        Task { await store.requestNotifications() }
                    }
                    .buttonStyle(.borderless)
                    .padding(11)
                }
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(detailTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                TextField("搜索事项", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100, idealWidth: 165, maxWidth: 210)
                    .accessibilityIdentifier("task-search")
                if currentList?.source == .local, let list = currentList {
                    Menu("清单操作", systemImage: "ellipsis.circle") {
                        Button("重命名清单") { listEditor = .init(list: list) }
                        Button("删除清单", role: .destructive) { pendingDeletion = list }
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("清单操作")
                }
                Button("新建事项", systemImage: "plus") { editor = .init(listID: currentList?.id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(currentList?.isWritable == false)
                    .accessibilityIdentifier("add-task")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider()

            TimelineView(.everyMinute) { context in
                let items = visibleItems(at: context.date)
                if items.isEmpty {
                    ContentUnavailableView(
                        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无事项" : "未找到事项",
                        systemImage: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "list.bullet.rectangle" : "magnifyingglass"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if selection == .completed {
                            ForEach(items, id: \.id) { item in managerRow(item, group: nil) }
                        } else {
                            ForEach(DueSection.groups(for: items.filter { !$0.isCompleted }, at: context.date)) { section in
                                Section(section.group.title) {
                                    ForEach(section.items, id: \.id) { item in managerRow(item, group: section.group) }
                                }
                            }
                            let completed = items.filter(\.isCompleted)
                            if !completed.isEmpty {
                                Section("已完成") {
                                    ForEach(completed, id: \.id) { item in managerRow(item, group: nil) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }

            if let message = store.errorMessage {
                Divider()
                errorMessage(message) { store.errorMessage = nil }
                    .padding(12)
            }
        }
    }

    private var currentList: ReminderList? {
        guard case .list(let id) = selection else { return nil }
        return store.lists.first { $0.id == id }
    }

    private var detailTitle: String {
        switch selection {
        case .all, nil: "全部待办"
        case .today: "今天"
        case .completed: "已完成"
        case .list: currentList?.title ?? "清单"
        }
    }

    private func visibleItems(at date: Date) -> [ReminderItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = store.tasks.filter { item in
            switch selection {
            case .all, nil: !item.isCompleted
            case .today: !item.isCompleted && item.dueDate.map { Calendar.current.isDate($0, inSameDayAs: date) } == true
            case .completed: item.isCompleted
            case .list(let id): item.listID == id
            }
        }
        let filtered = query.isEmpty ? candidates : candidates.filter { item in
            item.title.localizedStandardContains(query) || item.notes.localizedStandardContains(query)
                || listSubtitle(for: item, in: store.lists).localizedStandardContains(query)
        }
        return filtered.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
    }

    private func managerRow(_ item: ReminderItem, group: DueGroup?) -> some View {
        ReminderRow(
            item: item,
            subtitle: listSubtitle(for: item, in: store.lists),
            group: group,
            onToggle: { perform { try store.setCompleted(item, !item.isCompleted) } },
            onOpen: { editor = .init(item: item) }
        )
        .contextMenu {
            Button(item.isWritable ? "编辑事项" : "查看事项") { editor = .init(item: item) }
            if item.isWritable {
                Button(item.isCompleted ? "恢复待办" : "标为完成") {
                    perform { try store.setCompleted(item, !item.isCompleted) }
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { store.errorMessage = error.localizedDescription }
    }
}

private enum TaskScope: Hashable {
    case all, today, completed, list(String)
}

private enum DueGroup: String, CaseIterable, Identifiable {
    case overdue, today, upcoming, unscheduled

    var id: Self { self }

    var title: String {
        switch self {
        case .overdue: "逾期"
        case .today: "今天"
        case .upcoming: "即将到期"
        case .unscheduled: "未安排日期"
        }
    }

    static func classify(_ item: ReminderItem, at now: Date, calendar: Calendar) -> Self {
        guard let date = item.dueDate else { return .unscheduled }
        if date < (item.hasTime ? now : calendar.startOfDay(for: now)) { return .overdue }
        return calendar.isDate(date, inSameDayAs: now) ? .today : .upcoming
    }
}

private struct DueSection: Identifiable {
    let group: DueGroup
    let items: [ReminderItem]
    var id: DueGroup { group }

    static func groups(for items: [ReminderItem], at now: Date) -> [Self] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { DueGroup.classify($0, at: now, calendar: calendar) }
        return DueGroup.allCases.compactMap { group in
            guard let items = grouped[group] else { return nil }
            let sorted = items.sorted { left, right in
                if left.dueDate != right.dueDate { return (left.dueDate ?? .distantFuture) < (right.dueDate ?? .distantFuture) }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
            return Self(group: group, items: sorted)
        }
    }
}

private func listSubtitle(for item: ReminderItem, in lists: [ReminderList]) -> String {
    guard let list = lists.first(where: { $0.id == item.listID }) else { return item.source.label }
    return "\(listSourceLabel(list)) · \(list.title)"
}

private func listSourceLabel(_ list: ReminderList) -> String {
    if list.source == .apple, let account = list.accountName, !account.isEmpty { return account }
    return list.source.label
}

private enum TaskViewColors {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.59, green: 0.90, blue: 0.91, alpha: 1)
            : NSColor(srgbRed: 0.00, green: 0.36, blue: 0.41, alpha: 1)
    })
    static let overdue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.68, blue: 0.67, alpha: 1)
            : NSColor(srgbRed: 0.58, green: 0.13, blue: 0.16, alpha: 1)
    })
    static let today = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.84, blue: 0.56, alpha: 1)
            : NSColor(srgbRed: 0.46, green: 0.29, blue: 0.05, alpha: 1)
    })
}

private struct PanelIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TaskViewColors.accent)
            .frame(width: 28, height: 28)
            .background(.primary.opacity(configuration.isPressed ? 0.10 : 0.04), in: .circle)
            .contentShape(.circle)
    }
}

private struct ReminderRow: View {
    let item: ReminderItem
    let subtitle: String
    let group: DueGroup?
    let onToggle: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(item.isCompleted ? TaskViewColors.accent : Color.secondary)
                    .frame(width: 30, height: 35)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!item.isWritable)
            .accessibilityLabel(item.isCompleted ? "恢复 \(item.title)" : "完成 \(item.title)")

            Button(action: onOpen) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? .secondary : .primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if item.priority == .high {
                        Image(systemName: "exclamationmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TaskViewColors.overdue)
                            .accessibilityLabel("高优先级")
                    }
                    if let date = item.dueDate {
                        Text(dateLabel(date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(dateColor)
                            .lineLimit(1)
                    }
                }
                .padding(.trailing, 7)
                .frame(minHeight: 42)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(item.title)
        }
        .padding(.horizontal, 2)
        .background(.primary.opacity(hovering ? 0.065 : 0), in: .rect(cornerRadius: 7))
        .onHover { hovering = $0 }
    }

    private var dateColor: Color {
        switch group {
        case .overdue: TaskViewColors.overdue
        case .today: TaskViewColors.today
        default: .secondary
        }
    }

    private func dateLabel(_ date: Date) -> String {
        if group == .today {
            return item.hasTime ? date.formatted(.dateTime.hour().minute()) : "全天"
        }
        if item.hasTime && group != nil {
            return date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
        }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }
}

private struct ReminderEditorRequest: Identifiable {
    let id = UUID()
    var item: ReminderItem? = nil
    var listID: String? = nil
}

@MainActor
private struct ReminderEditor: View {
    @ObservedObject var store: TaskStore
    let request: ReminderEditorRequest
    let compact: Bool
    let onClose: () -> Void

    @State private var draft: ReminderDraft
    @State private var message: String?
    @State private var showDelete = false
    @FocusState private var titleFocused: Bool

    init(store: TaskStore, request: ReminderEditorRequest, compact: Bool, onClose: @escaping () -> Void) {
        self.store = store
        self.request = request
        self.compact = compact
        self.onClose = onClose
        let listID = request.listID ?? store.lists.first(where: { $0.source == .local && $0.isWritable })?.id
            ?? store.lists.first(where: \.isWritable)?.id ?? ""
        _draft = State(initialValue: request.item.map(ReminderDraft.init) ?? ReminderDraft(listID: listID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                Text(request.item == nil ? "新建提醒事项" : "提醒事项详情")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    fields
                        .disabled(request.item?.isWritable == false)
                    if request.item?.isWritable == false {
                        Label("此清单只读", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message { errorMessage(message) { self.message = nil } }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.top)

            Divider()
            HStack {
                if request.item?.isWritable == true {
                    Button("删除事项", systemImage: "trash", role: .destructive) { showDelete = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("删除事项")
                }
                Spacer()
                Button(request.item?.isWritable == false ? "关闭" : "取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                if request.item?.isWritable != false {
                    Button("保存", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                        .accessibilityIdentifier("save-task")
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .task { if request.item == nil { titleFocused = true } }
        .confirmationDialog("删除此事项？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: delete)
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var fields: some View {
        TextField("标题", text: $draft.title)
            .textFieldStyle(.roundedBorder)
            .focused($titleFocused)
            .accessibilityIdentifier("task-title")
        TextField("备注", text: $draft.notes, axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("task-notes")

        Picker("清单", selection: $draft.listID) {
            ForEach(availableLists, id: \.id) { list in
                Text("\(list.title) · \(listSourceLabel(list))").tag(list.id)
            }
            if !availableLists.contains(where: { $0.id == draft.listID }) {
                Text("未选择清单").tag(draft.listID)
            }
        }
        .accessibilityIdentifier("task-list-picker")

        Picker("优先级", selection: $draft.priority) {
            ForEach([ReminderPriority.none, .low, .medium, .high], id: \.self) { option in
                Text(option.label).tag(option)
            }
            if request.item?.priority == .custom { Text(ReminderPriority.custom.label).tag(ReminderPriority.custom) }
        }

        Toggle("设定日期", isOn: Binding(get: { draft.dueDate != nil }, set: { isOn in
            draft.dueDate = isOn ? Calendar.current.startOfDay(for: .now) : nil
            if !isOn {
                draft.hasTime = false
                draft.alerts = false
                draft.repeatRule = .never
            }
        }))
        if draft.dueDate != nil {
            DatePicker("日期", selection: dueDateBinding, displayedComponents: draft.hasTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.field)
            Toggle("设定时间", isOn: Binding(get: { draft.hasTime }, set: { hasTime in
                draft.hasTime = hasTime
                if !hasTime { draft.alerts = false }
                if hasTime, let date = draft.dueDate, date == Calendar.current.startOfDay(for: date) {
                    let calendar = Calendar.current
                    if calendar.isDateInToday(date) {
                        let suggestedTime = Date.now.addingTimeInterval(5 * 60)
                        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date)
                        draft.dueDate = min(suggestedTime, endOfDay ?? suggestedTime)
                    } else {
                        draft.dueDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)
                    }
                }
            }))
            Toggle("到时提醒", isOn: $draft.alerts)
                .disabled(!draft.hasTime)
            Picker("重复", selection: $draft.repeatRule) {
                ForEach([ReminderRepeat.never, .daily, .weekly, .monthly, .yearly], id: \.self) { option in
                    Text(option.label).tag(option)
                }
                if request.item?.repeatRule == .custom { Text(ReminderRepeat.custom.label).tag(ReminderRepeat.custom) }
            }
        }
    }

    private var dueDateBinding: Binding<Date> {
        Binding(get: { draft.dueDate ?? .now }, set: { draft.dueDate = $0 })
    }

    private var availableLists: [ReminderList] {
        guard let item = request.item else { return store.lists.filter(\.isWritable) }
        return store.lists.filter { $0.source == item.source && ($0.isWritable || $0.id == item.listID) }
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && availableLists.contains { $0.id == draft.listID && $0.isWritable }
    }

    private func save() {
        do {
            try store.save(draft)
            if draft.alerts && store.notifications == .notDetermined,
               availableLists.first(where: { $0.id == draft.listID })?.source == .local {
                Task { await store.requestNotifications() }
            }
            onClose()
        } catch { message = error.localizedDescription }
    }

    private func delete() {
        guard let item = request.item else { return }
        do {
            try store.delete(item)
            onClose()
        } catch { message = error.localizedDescription }
    }
}

private struct ListEditorRequest: Identifiable {
    let id = UUID()
    var list: ReminderList? = nil
}

@MainActor
private struct ListEditor: View {
    let store: TaskStore
    let request: ListEditorRequest
    let onClose: () -> Void

    @State private var title: String
    @State private var message: String?

    init(store: TaskStore, request: ListEditorRequest, onClose: @escaping () -> Void) {
        self.store = store
        self.request = request
        self.onClose = onClose
        _title = State(initialValue: request.list?.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.list == nil ? "新建本机清单" : "重命名清单")
                .font(.headline)
            TextField("清单名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("list-name")
            if let message { errorMessage(message) { self.message = nil } }
            HStack {
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-list")
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func save() {
        do {
            if let list = request.list { try store.renameLocalList(list, to: title) }
            else { try store.createLocalList(title) }
            onClose()
        } catch { message = error.localizedDescription }
    }
}

@MainActor
private func errorMessage(_ message: String, dismiss: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 7) {
        Image(systemName: "exclamationmark.circle")
            .accessibilityHidden(true)
        Text(message)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        Button("关闭提示", systemImage: "xmark", action: dismiss)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
    }
    .font(.caption)
    .foregroundStyle(TaskViewColors.overdue)
}

private enum SystemSettingsPane: String {
    case reminders = "com.apple.preference.security?Privacy_Reminders"
    case notifications = "com.apple.Notifications-Settings.extension"
}

@MainActor
private func openSystemSettings(_ pane: SystemSettingsPane) {
    if let url = URL(string: "x-apple.systempreferences:\(pane.rawValue)") { NSWorkspace.shared.open(url) }
}
