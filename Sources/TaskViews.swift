import AppKit
import SwiftUI

@MainActor
struct TaskPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var quickAdd: PanelQuickAdd
    let onOpenManager: () -> Void
    let onEditingChanged: (Bool) -> Void

    @AppStorage("floatingPanel.filter") private var filter = "all"
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
                    let items = visibleItems(at: context.date)
                    let pinned = store.pinnedTaskIDs.compactMap { id in items.first { $0.id == id } }
                    let pinnedIDs = Set(pinned.map(\.id))
                    let sections = DueSection.groups(for: items.filter { !pinnedIDs.contains($0.id) }, at: context.date)
                    if items.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if !pinned.isEmpty {
                                    panelSection("置顶", items: pinned, at: context.date)
                                }
                                ForEach(sections) { section in
                                    panelSection(section.group.title, items: section.items, at: context.date)
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
        .onChange(of: quickAdd.requestID) {
            if editor == nil { openNewTask() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if editor == nil {
                Text(filterTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)

                TimelineView(.everyMinute) { context in
                    let count = visibleItems(at: context.date).count
                    if count > 0 {
                        Text("\(count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(editor?.item == nil ? "新建提醒事项" : "提醒事项详情")
                    .font(.system(size: 16, weight: .semibold))
            }

            Spacer(minLength: 8)

            if editor == nil {
                filterMenu

                Button("打开清单", systemImage: "sidebar.left", action: onOpenManager)
                    .labelStyle(.iconOnly)
                    .help("打开清单")
                    .accessibilityIdentifier("open-task-manager")

                Button("新建提醒事项", systemImage: "plus", action: openNewTask)
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

    private var selectedList: ReminderList? {
        store.lists.first { "list:" + $0.id == filter }
    }

    private var filterTitle: String {
        filter == "today" ? "今天" : selectedList?.title ?? "待完成"
    }

    private var filterMenu: some View {
        Menu {
            filterOption("全部待办", tag: "all")
            filterOption("今天", tag: "today")
            if !store.lists.isEmpty {
                Divider()
                ForEach(store.lists) { list in
                    filterOption("\(list.title) · \(listSourceLabel(list))", tag: "list:" + list.id)
                }
            }
        } label: {
            Label("筛选待办", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选待办")
        .accessibilityIdentifier("task-panel-filter")
    }

    private func filterOption(_ title: String, tag: String) -> some View {
        let effectiveFilter = selectedList == nil && filter != "today" ? "all" : filter
        return Button {
            filter = tag
        } label: {
            if effectiveFilter == tag {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func visibleItems(at date: Date) -> [ReminderItem] {
        let listID = selectedList?.id
        let calendar = Calendar.current
        return store.tasks.filter { item in
            guard !item.isCompleted else { return false }
            if filter == "today" {
                return item.dueDate.map { calendar.isDate($0, inSameDayAs: date) } == true
            }
            return listID == nil || item.listID == listID
        }
    }

    private func panelSection(_ title: String, items: [ReminderItem], at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 5)
                .padding(.bottom, 3)

            ForEach(items) { item in
                ReminderRow(
                    item: item,
                    store: store,
                    group: DueGroup.classify(item, at: date, calendar: .current),
                    referenceDate: date,
                    onOpen: { open(.init(item: item)) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(filter == "today" ? "今天没有待办" : selectedList != nil ? "此清单没有待办" : "没有待完成事项")
                .font(.callout.weight(.medium))
            if store.access != .allowed && selectedList == nil && filter != "today" {
                Button("连接 Apple 提醒事项", action: onOpenManager)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func openNewTask() {
        open(.init(listID: selectedList?.isWritable == true ? selectedList?.id : nil))
    }

    private func open(_ request: ReminderEditorRequest) {
        onEditingChanged(true)
        editor = request
    }

    private func closeEditor() {
        editor = nil
        onEditingChanged(false)
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
                            ForEach(items, id: \.id) { item in managerRow(item, group: nil, at: context.date) }
                        } else {
                            ForEach(DueSection.groups(for: items.filter { !$0.isCompleted }, at: context.date)) { section in
                                Section(section.group.title) {
                                    ForEach(section.items, id: \.id) { item in
                                        managerRow(item, group: section.group, at: context.date)
                                    }
                                }
                            }
                            let completed = items.filter(\.isCompleted)
                            if !completed.isEmpty {
                                Section("已完成") {
                                    ForEach(completed, id: \.id) { item in
                                        managerRow(item, group: nil, at: context.date)
                                    }
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
                || item.subtasks.contains { $0.title.localizedStandardContains(query) }
        }
        return filtered.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
    }

    private func managerRow(_ item: ReminderItem, group: DueGroup?, at date: Date) -> some View {
        ReminderRow(
            item: item,
            store: store,
            group: group,
            referenceDate: date,
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
    @ObservedObject var store: TaskStore
    let group: DueGroup?
    let referenceDate: Date
    let onOpen: () -> Void

    @State private var hovering = false
    @State private var showsSubtasks = false
    @State private var confirmsParentCompletion = false

    private var isPinned: Bool { store.pinnedTaskIDs.contains(item.id) }
    private var completedSubtasks: Int { item.subtasks.filter(\.isCompleted).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if showsSubtasks && !item.subtasks.isEmpty {
                subtaskRows
            }
        }
        .padding(.horizontal, 2)
        .background(.primary.opacity(hovering ? 0.065 : 0), in: .rect(cornerRadius: 7))
        .onHover { hovering = $0 }
    }

    private var summary: some View {
        HStack(spacing: 4) {
            Button {
                perform { try store.setCompleted(item, !item.isCompleted) }
            } label: {
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
                        HStack(spacing: 3) {
                            if isPinned {
                                Image(systemName: "pin.fill")
                                    .accessibilityLabel("已置顶")
                            }
                            Text(listSubtitle(for: item, in: store.lists))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let snoozedUntil = item.snoozedUntil, snoozedUntil > referenceDate, !item.isCompleted {
                            Label("提醒推迟至 \(snoozedUntil.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))",
                                  systemImage: "bell.badge")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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
                .frame(minHeight: 42)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(item.title)

            if !item.subtasks.isEmpty {
                Button {
                    showsSubtasks.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("\(completedSubtasks)/\(item.subtasks.count)")
                            .monospacedDigit()
                        Image(systemName: showsSubtasks ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 30)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(showsSubtasks ? "折叠子任务" : "展开子任务")
                .accessibilityValue("已完成 \(completedSubtasks) 项，共 \(item.subtasks.count) 项")
                .help(showsSubtasks ? "折叠子任务" : "展开子任务")
            }

            if !item.isCompleted {
                actionMenu
            }
        }
        .padding(.trailing, 3)
    }

    private var subtaskRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(item.subtasks) { subtask in
                Button {
                    toggleSubtask(subtask)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.isCompleted ? TaskViewColors.accent : .secondary)
                            .accessibilityHidden(true)
                        Text(subtask.title)
                            .strikethrough(subtask.isCompleted)
                            .foregroundStyle(subtask.isCompleted ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .frame(minHeight: 26)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(item.isCompleted || !item.isWritable)
                .accessibilityLabel(subtask.isCompleted ? "恢复子任务 \(subtask.title)" : "完成子任务 \(subtask.title)")
            }
            if confirmsParentCompletion && completedSubtasks == item.subtasks.count && !item.isCompleted {
                HStack(spacing: 8) {
                    Button("完成主事项") {
                        perform { try store.setCompleted(item, true) }
                        confirmsParentCompletion = false
                    }
                    .buttonStyle(.bordered)
                    Button("保留待办") { confirmsParentCompletion = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .padding(.vertical, 4)
            }
        }
        .padding(.leading, 34)
        .padding(.trailing, 6)
        .padding(.bottom, 5)
    }

    private var actionMenu: some View {
        Menu {
            Button(isPinned ? "取消置顶" : "置顶到浮窗", systemImage: isPinned ? "pin.slash" : "pin") {
                perform { try store.setPinned(item, !isPinned) }
            }
            if item.source == .local && item.isWritable {
                Menu("稍后提醒", systemImage: "bell") {
                    Button("10 分钟后") { snooze(until: Date.now.addingTimeInterval(600)) }
                    Button("1 小时后") { snooze(until: Date.now.addingTimeInterval(3600)) }
                    Button("明早 9:00") {
                        let calendar = Calendar.current
                        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now),
                           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
                            snooze(until: morning)
                        }
                    }
                    if item.snoozedUntil != nil {
                        Divider()
                        Button("取消稍后提醒") { snooze(until: nil) }
                    }
                }
            }
        } label: {
            Label("事项操作", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("事项操作")
        .accessibilityLabel("事项操作 \(item.title)")
    }

    private func toggleSubtask(_ subtask: ReminderSubtask) {
        perform {
            let completed = !subtask.isCompleted
            try store.setSubtaskCompleted(item, subtaskID: subtask.id, completed: completed)
            let latest = store.tasks.first { $0.id == item.id }
            confirmsParentCompletion = completed && latest?.subtasks.allSatisfy(\.isCompleted) == true
        }
    }

    private func snooze(until date: Date?) {
        perform {
            try store.snooze(item, until: date)
            if date != nil {
                if store.notifications == .notDetermined {
                    Task { await store.requestNotifications() }
                } else if store.notifications == .denied {
                    store.errorMessage = "已保存稍后提醒。请在系统设置中允许浮光提醒发送通知。"
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { store.errorMessage = error.localizedDescription }
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
    @State private var dateWasSetManually = false
    @State private var isSaving = false
    @State private var showTemplateName = false
    @State private var templateName = ""
    @State private var templateToDelete: ReminderTemplate?
    @FocusState private var titleFocused: Bool
    @FocusState private var focusedSubtask: UUID?

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
                    Button("保存") { save() }
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
            .onSubmit { save() }
            .accessibilityIdentifier("task-title")
        if let suggestion = dateSuggestion {
            Button {
                applyDateSuggestion(suggestion, to: &draft)
            } label: {
                Label(suggestionLabel(suggestion), systemImage: "calendar.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("apply-suggested-date")
        }
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
        if hasSubtasksInAppleList {
            Label("请选择本机清单以保留子任务", systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Picker("优先级", selection: $draft.priority) {
            ForEach([ReminderPriority.none, .low, .medium, .high], id: \.self) { option in
                Text(option.label).tag(option)
            }
            if request.item?.priority == .custom { Text(ReminderPriority.custom.label).tag(ReminderPriority.custom) }
        }

        Toggle("设定日期", isOn: Binding(get: { draft.dueDate != nil }, set: { isOn in
            dateWasSetManually = true
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

        if selectedList?.source == .local {
            subtaskSection
        }
    }

    private var dateSuggestion: QuickEntryParser.Result? {
        guard request.item == nil, draft.dueDate == nil, !dateWasSetManually else { return nil }
        return QuickEntryParser.parse(draft.title)
    }

    private func suggestionLabel(_ suggestion: QuickEntryParser.Result) -> String {
        let style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
        let date = suggestion.date.formatted(suggestion.hasTime ? style.hour().minute() : style)
        return "采用 \(date)"
    }

    private func applyDateSuggestion(_ suggestion: QuickEntryParser.Result, to draft: inout ReminderDraft) {
        draft.title = suggestion.title
        draft.dueDate = suggestion.date
        draft.hasTime = suggestion.hasTime
        draft.alerts = suggestion.hasTime
    }

    private var subtaskSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.vertical, 2)
            HStack {
                Text("子任务")
                    .font(.callout.weight(.semibold))
                Spacer()
                templateMenu
            }

            ForEach($draft.subtasks) { $subtask in
                let id = subtask.id
                HStack(spacing: 7) {
                    Toggle("完成子任务", isOn: $subtask.isCompleted)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(subtask.title.isEmpty ? "完成子任务" : "完成 \(subtask.title)")
                    TextField("子任务标题", text: $subtask.title)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedSubtask, equals: id)
                        .accessibilityIdentifier("subtask-title")
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                        .draggable(id.uuidString)
                        .help("拖动排序")
                        .accessibilityHidden(true)
                    subtaskMenu(id)
                }
                .dropDestination(for: String.self) { values, _ in
                    guard let value = values.first, let sourceID = UUID(uuidString: value) else { return false }
                    return moveSubtask(sourceID, to: id)
                }
            }

            HStack {
                Button("添加子任务", systemImage: "plus", action: addSubtask)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("add-subtask")
                if let parent = parentReadyToComplete {
                    Spacer()
                    Button("保存并完成主事项", systemImage: "checkmark.circle") { save(completing: parent) }
                        .buttonStyle(.borderless)
                        .disabled(!canSave)
                }
            }
        }
        .alert("存为子任务模板", isPresented: $showTemplateName) {
            TextField("模板名称", text: $templateName)
            Button("保存", action: saveTemplate)
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除子任务模板？", isPresented: Binding(
            get: { templateToDelete != nil },
            set: { if !$0 { templateToDelete = nil } }
        ), titleVisibility: .visible, presenting: templateToDelete) { template in
            Button("删除 \(template.name)", role: .destructive) { deleteTemplate(template) }
            Button("取消", role: .cancel) {}
        }
    }

    private var templateMenu: some View {
        Menu {
            if !store.templates.isEmpty {
                Menu("添加模板步骤") {
                    ForEach(store.templates) { template in
                        Button(template.name) { draft.subtasks.append(contentsOf: template.newSubtasks()) }
                    }
                }
            }
            Button("将当前步骤存为模板") {
                templateName = ""
                showTemplateName = true
            }
            .disabled(!draft.subtasks.contains { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            if !store.templates.isEmpty {
                Menu("删除模板") {
                    ForEach(store.templates) { template in
                        Button(template.name, role: .destructive) { templateToDelete = template }
                    }
                }
            }
        } label: {
            Label("模板", systemImage: "list.bullet.rectangle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("subtask-templates")
    }

    private func subtaskMenu(_ id: UUID) -> some View {
        let index = draft.subtasks.firstIndex { $0.id == id }
        return Menu {
            Button("上移", systemImage: "arrow.up") { shiftSubtask(id, by: -1) }
                .disabled(index == nil || index == 0)
            Button("下移", systemImage: "arrow.down") { shiftSubtask(id, by: 1) }
                .disabled(index == nil || index == draft.subtasks.indices.last)
            Divider()
            Button("删除子任务", systemImage: "trash", role: .destructive) {
                draft.subtasks.removeAll { $0.id == id }
            }
        } label: {
            Label("子任务操作", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("子任务操作")
    }

    private func addSubtask() {
        let item = ReminderSubtask(title: "")
        draft.subtasks.append(item)
        focusedSubtask = item.id
    }

    private func shiftSubtask(_ id: UUID, by offset: Int) {
        guard let index = draft.subtasks.firstIndex(where: { $0.id == id }),
              draft.subtasks.indices.contains(index + offset) else { return }
        draft.subtasks.swapAt(index, index + offset)
    }

    private func moveSubtask(_ sourceID: UUID, to targetID: UUID) -> Bool {
        guard sourceID != targetID,
              let source = draft.subtasks.firstIndex(where: { $0.id == sourceID }),
              let target = draft.subtasks.firstIndex(where: { $0.id == targetID }) else { return false }
        let item = draft.subtasks.remove(at: source)
        draft.subtasks.insert(item, at: target)
        return true
    }

    private func saveTemplate() {
        let steps = draft.subtasks.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        do { try store.createTemplate(name: templateName, subtasks: steps) }
        catch { message = error.localizedDescription }
    }

    private func deleteTemplate(_ template: ReminderTemplate) {
        do { try store.deleteTemplate(template) }
        catch { message = error.localizedDescription }
    }

    private var dueDateBinding: Binding<Date> {
        Binding(get: { draft.dueDate ?? .now }, set: { draft.dueDate = $0 })
    }

    private var availableLists: [ReminderList] {
        guard let item = request.item else { return store.lists.filter(\.isWritable) }
        return store.lists.filter { $0.source == item.source && ($0.isWritable || $0.id == item.listID) }
    }

    private var selectedList: ReminderList? {
        availableLists.first { $0.id == draft.listID }
    }

    private var hasSubtasksInAppleList: Bool {
        selectedList?.source == .apple && draft.subtasks.contains {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedList?.isWritable == true && !hasSubtasksInAppleList
    }

    private var parentReadyToComplete: ReminderItem? {
        guard let item = request.item, !item.isCompleted,
              item.subtasks.contains(where: { !$0.isCompleted }),
              !draft.subtasks.isEmpty, draft.subtasks.allSatisfy(\.isCompleted) else { return nil }
        return item
    }

    private func save(completing parent: ReminderItem? = nil) {
        guard canSave, !isSaving else { return }
        if selectedList?.source == .local,
           draft.subtasks.contains(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            message = "请填写或移除空白子任务。"
            return
        }
        isSaving = true
        var savedDraft = draft
        if let suggestion = dateSuggestion { applyDateSuggestion(suggestion, to: &savedDraft) }
        if selectedList?.source != .local { savedDraft.subtasks = [] }
        do {
            try store.save(savedDraft)
            if let parent { try store.setCompleted(parent, true) }
            if savedDraft.alerts && store.notifications == .notDetermined, selectedList?.source == .local {
                Task { await store.requestNotifications() }
            }
            onClose()
        } catch {
            isSaving = false
            message = error.localizedDescription
        }
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
