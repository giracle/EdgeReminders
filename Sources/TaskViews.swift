import AppKit
import SwiftUI

@MainActor
struct TaskPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var quickAdd: PanelQuickAdd
    @ObservedObject var prefs = AppPreferences.shared
    let onOpenManager: () -> Void
    let onOpenTimer: () -> Void
    let onQuit: () -> Void
    let onFocusTask: (ReminderItem) -> Void
    let onStartTaskTimer: (ReminderItem) -> Void
    let onContinueTask: (ReminderItem, Bool) -> Void
    let onEditingChanged: (Bool) -> Void

    @AppStorage("floatingPanel.filter") private var filter = "all"
    @State private var editor: ReminderEditorRequest?
    @State private var isSearching = false
    @State private var panelQuery = ""
    @State private var searchSelection = 0
    @State private var burstID: UUID?
    @FocusState private var searchFocused: Bool

    private var panelSearchResults: [ReminderItem] {
        store.search(panelQuery, at: .now)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                searchHeader
            } else {
                header
            }
            Divider().overlay(.primary.opacity(0.07))
            if prefs.rainbowHairline { RainbowHairline() }

            if let editor {
                ReminderEditor(store: store, request: editor, compact: true, onClose: closeEditor)
                    .id(editor.id)
            } else if isSearching {
                searchResults
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
        .overlay(alignment: .top) {
            if let burstID {
                CelebrationBurst(color: TaskViewColors.accent)
                    .id(burstID)
                    .offset(y: 30)
                    .task(id: burstID) {
                        do { try await Task.sleep(for: .seconds(1.1)) } catch { return }
                        if self.burstID == burstID { self.burstID = nil }
                    }
            }
        }
        .onChange(of: quickAdd.requestID) {
            if editor == nil { openNewTask() }
        }
        .onMoveCommand { direction in
            guard isSearching, editor == nil, !panelSearchResults.isEmpty else { return }
            searchSelection = (searchSelection + (direction == .down ? 1 : -1) + panelSearchResults.count) % panelSearchResults.count
        }
        .onChange(of: store.lastCompletedID) {
            guard store.lastCompletedID != nil else { return }
            burstID = UUID()
            if prefs.soundEnabled, let sound = NSSound(named: NSSound.Name(prefs.completionSound)) {
                sound.play()
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索：事项、#标签、日期、优先级…", text: $panelQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { openSelectedSearchResult() }
                .onExitCommand { endSearch() }
            if !panelQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(panelSearchResults.count) 项")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("结束搜索", systemImage: "xmark.circle.fill") { endSearch() }
                .labelStyle(.iconOnly)
                .help("结束搜索")
        }
        .buttonStyle(PanelIconStyle())
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 50)
        .task { searchFocused = true }
    }

    private var searchResults: some View {
        Group {
            if panelSearchResults.isEmpty {
                VStack(spacing: 11) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(panelQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "输入关键词开始搜索" : "未找到事项")
                        .font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(panelSearchResults.enumerated()), id: \.element.id) { index, item in
                            ReminderRow(
                                item: item,
                                store: store,
                                group: DueGroup.classify(item, at: .now, calendar: .current),
                                referenceDate: .now,
                                onOpen: { open(.init(item: item)) },
                                onFocus: { searchSelection = index; onFocusTask(item) },
                                onStartTimer: { onStartTaskTimer(item) },
                                onContinue: { onContinueTask(item, $0) }
                            )
                            .background(index == searchSelection ? Color.accentColor.opacity(0.14) : .clear,
                                      in: .rect(cornerRadius: 7))
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.top)
            }
        }
        .animation(.easeOut(duration: 0.12), value: panelQuery)
    }

    private func openSelectedSearchResult() {
        guard panelSearchResults.indices.contains(searchSelection) else { return }
        open(.init(item: panelSearchResults[searchSelection]))
    }

    private func endSearch() {
        isSearching = false
        panelQuery = ""
        searchSelection = 0
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
                Button("搜索", systemImage: "magnifyingglass") {
                    isSearching = true
                }
                .labelStyle(.iconOnly)
                .help("搜索事项")
                .accessibilityIdentifier("panel-search")

                filterMenu

                Button("计时", systemImage: "timer", action: onOpenTimer)
                    .labelStyle(.iconOnly)
                    .help("计时")
                    .accessibilityIdentifier("open-focus-timer")

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

            Button("退出浮光提醒", systemImage: "power", action: onQuit)
                .labelStyle(.iconOnly)
                .help("退出浮光提醒")
                .accessibilityIdentifier("quit-app")
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
                    onOpen: { open(.init(item: item)) },
                    onFocus: { onFocusTask(item) },
                    onStartTimer: { onStartTaskTimer(item) },
                    onContinue: { onContinueTask(item, $0) }
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
    @ObservedObject var prefs = AppPreferences.shared
    let onFocusTask: (ReminderItem) -> Void
    let onStartTaskTimer: (ReminderItem) -> Void
    let onContinueTask: (ReminderItem, Bool) -> Void

    @State private var selection: TaskScope? = .all
    @State private var search = ""
    @State private var editor: ReminderEditorRequest?
    @State private var listEditor: ListEditorRequest?
    @State private var smartListEditor = false
    @State private var statsSheet = false
    @State private var pendingDeletion: ReminderList?
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    @State private var settingsSheet = false

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
                .frame(width: 460, height: 620)
        }
        .sheet(item: $listEditor) { request in
            ListEditor(store: store, request: request) { listEditor = nil }
        }
        .sheet(isPresented: $smartListEditor) {
            SmartListEditor(store: store) { smartListEditor = false }
        }
        .sheet(isPresented: $statsSheet) {
            StatsSheet(store: store, onClose: { statsSheet = false })
        }
        .sheet(isPresented: $settingsSheet) {
            SettingsSheet(store: store, prefs: prefs, onClose: { settingsSheet = false })
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
                Label("即将到期", systemImage: "calendar.badge.clock")
                    .tag(TaskScope.upcoming)
                Label("已完成", systemImage: "checkmark.circle")
                    .tag(TaskScope.completed)
                Label("已归档", systemImage: "archivebox")
                    .tag(TaskScope.archived)

                Section("智能清单") {
                    ForEach(store.smartLists) { list in
                        Label(list.name, systemImage: "sparkles")
                            .tag(TaskScope.smart(list.id))
                            .contextMenu {
                                Button("删除智能清单", role: .destructive) {
                                    perform { try store.deleteSmartList(list) }
                                    if selection == .smart(list.id) { selection = .all }
                                }
                            }
                    }
                    Button("新建智能清单", systemImage: "plus") { smartListEditor = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(TaskViewColors.accent)
                        .help("创建按条件自动聚合的清单")
                        .accessibilityIdentifier("add-smart-list")
                }

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
                        .help("在本机新建清单")
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
                        .help("授权后读取和管理 Apple 提醒事项")
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
            headerBar

            Divider()

            if isSelecting {
                batchBar
                Divider()
            }

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
                        scopeRows(items: items, at: context.date)
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

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(detailTitle)
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
            Spacer(minLength: 10)
            searchField
            moreMenu
            Button("新建事项", systemImage: "plus") {
                editor = .init(listID: currentList?.id)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(currentList?.isWritable == false)
            .help("新建事项（⌘N）")
            .accessibilityIdentifier("add-task")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索事项、#标签、日期、拼音…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityIdentifier("task-search")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 186, height: 24)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.08)))
        .help("支持关键词、拼音、#标签、日期与优先级，可空格分隔多个关键词")
    }

    private var moreMenu: some View {
        Menu {
            Button("撤销", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!store.canUndo)
            Button("重做", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!store.canRedo)
            Divider()
            Button(isSelecting ? "退出批量选择" : "批量选择", systemImage: "rectangle.stack") {
                isSelecting.toggle()
                selectedIDs.removeAll()
            }
            if selection == .all || selection == nil {
                Button("归档已完成", systemImage: "archivebox") {
                    perform { try store.archiveCompletedLocalItems() }
                }
            }
            Divider()
            Menu("导出", systemImage: "square.and.arrow.up") {
                Button("导出 CSV…") { export(.csv) }
                Button("导出 Markdown…") { export(.markdown) }
                Button("导出 JSON…") { export(.json) }
                Divider()
                Button("备份全部数据…") { export(.backup) }
                Button("恢复备份…", action: restoreBackup)
            }
            Button("统计…", systemImage: "chart.bar.xaxis") { statsSheet = true }
            Button("设置…", systemImage: "gearshape") { settingsSheet = true }
            if currentList?.source == .local, let list = currentList {
                Divider()
                Button("重命名清单…") { listEditor = .init(list: list) }
                Button("删除清单…", role: .destructive) { pendingDeletion = list }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityIdentifier("more-actions")
    }

    private var currentList: ReminderList? {
        guard case .list(let id) = selection else { return nil }
        return store.lists.first { $0.id == id }
    }

    private var isArchivedScope: Bool {
        if case .archived = selection { return true }
        return false
    }

    private var detailTitle: String {
        switch selection {
        case .all, nil: "全部待办"
        case .today: "今天"
        case .upcoming: "即将到期"
        case .completed: "已完成"
        case .archived: "已归档"
        case .list: currentList?.title ?? "清单"
        case .smart(let id): store.smartLists.first { $0.id == id }?.name ?? "智能清单"
        }
    }

    private var batchBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(selectedIDs.count) 项")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("全选") { selectedIDs = Set(visibleItems(at: .now).map(\.id)) }
            Button("清空") { selectedIDs.removeAll() }
            Spacer()
            if isArchivedScope {
                Button("恢复") { batchRestore() }
                Button("删除", role: .destructive) { batchDelete() }
            } else {
                Button("标为完成") { batchComplete() }
                Button("归档") { batchArchive() }
                Button("删除", role: .destructive) { batchDelete() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ day: Date, at now: Date) -> some View {
        Text(Calendar.current.isDate(day, inSameDayAs: now) ? "今天" : day.formatted(.dateTime.month(.defaultDigits).day().weekday()))
    }

    @ViewBuilder
    private func scopeRows(items: [ReminderItem], at date: Date) -> some View {
        if !searchTokens.isEmpty {
            ForEach(items, id: \.id) { item in
                managerRow(item, group: nil, at: date)
            }
        } else {
            scopeRowsBySelection(items: items, at: date)
        }
    }

    @ViewBuilder
    private func scopeRowsBySelection(items: [ReminderItem], at date: Date) -> some View {
        switch selection ?? .all {
        case .upcoming:
            ForEach(upcomingSections(items, at: date)) { section in
                Section(header: sectionHeader(section.day, at: date)) {
                    ForEach(section.items, id: \.id) { item in
                        managerRow(item, group: .upcoming, at: date)
                    }
                }
            }
        case .archived:
            ForEach(items, id: \.id) { item in
                managerRow(item, group: nil, at: date)
            }
        case .completed:
            ForEach(items, id: \.id) { item in managerRow(item, group: nil, at: date) }
        default:
            ForEach(DueSection.groups(for: items.filter { !$0.isCompleted }, at: date)) { section in
                Section(section.group.title) {
                    ForEach(section.items, id: \.id) { item in
                        managerRow(item, group: section.group, at: date)
                    }
                }
            }
            let completed = items.filter(\.isCompleted)
            if !completed.isEmpty {
                Section("已完成") {
                    ForEach(completed, id: \.id) { item in
                        managerRow(item, group: nil, at: date)
                    }
                }
            }
        }
    }

    private func upcomingSections(_ items: [ReminderItem], at date: Date) -> [UpcomingSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.dueDate ?? date) }
        return grouped
            .sorted { $0.key < $1.key }
            .map { day, items in
                UpcomingSection(day: day, items: items.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) })
            }
    }

    private func export(_ format: ExportFormat) {
        let exporter = TaskExporter(store: store)
        let suggestedName: String
        switch format {
        case .csv: suggestedName = "浮光提醒.csv"
        case .markdown: suggestedName = "浮光提醒.md"
        case .json: suggestedName = "浮光提醒.json"
        case .backup: suggestedName = "浮光提醒备份.json"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data: Data
                switch format {
                case .csv: data = exporter.csv()
                case .markdown: data = Data(exporter.markdown().utf8)
                case .json: data = exporter.json()
                case .backup: data = exporter.backup()
                }
                try data.write(to: url, options: .atomic)
            } catch {
                store.errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "恢复"
        panel.begin { response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            do {
                try TaskExporter(store: store).restore(from: data)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func batchComplete() {
        let items = visibleItems(at: .now).filter { selectedIDs.contains($0.id) && !$0.isCompleted }
        perform {
            for item in items { try store.setCompleted(item, true) }
            selectedIDs.removeAll()
        }
    }

    private func batchArchive() {
        let items = visibleItems(at: .now).filter { selectedIDs.contains($0.id) && $0.source == .local }
        perform {
            try store.archive(items)
            selectedIDs.removeAll()
        }
    }

    private func batchDelete() {
        let items = visibleItems(at: .now).filter { selectedIDs.contains($0.id) }
        perform {
            if isArchivedScope {
                try store.deleteArchived(Set(items.map(\.id)))
            } else {
                for item in items { try store.delete(item) }
            }
            selectedIDs.removeAll()
        }
    }

    private func batchRestore() {
        let items = visibleItems(at: .now).filter { selectedIDs.contains($0.id) }
        perform {
            try store.restoreArchived(Set(items.map(\.id)))
            selectedIDs.removeAll()
        }
    }

    private var searchTokens: [String] {
        FuzzySearch.tokens(from: NaturalQueryParser.parse(search).text)
    }

    private var isSearchingQuery: Bool {
        let parsed = NaturalQueryParser.parse(search)
        return !searchTokens.isEmpty || parsed.tag != nil || parsed.priority != nil || parsed.date != nil
    }

    private func visibleItems(at date: Date) -> [ReminderItem] {
        let query = NaturalQueryParser.parse(search, now: date)
        let tokens = FuzzySearch.tokens(from: query.text)
        let calendar = Calendar.current

        let base: [ReminderItem]
        if isSearchingQuery {
            // 有关键词/条件时全局搜索：不再受侧栏范围限制，包含已完成与归档。
            base = store.tasks + store.archivedTasks
        } else if selection == .archived {
            base = store.archivedTasks
        } else if case .smart(let id) = selection {
            base = store.smartLists.first { $0.id == id }.map { store.items(matching: $0.rule, at: date) } ?? []
        } else {
            base = store.tasks.filter { item -> Bool in
                switch selection {
                case .all, nil:
                    return !item.isCompleted
                case .today:
                    return item.dueDate.map { calendar.isDate($0, inSameDayAs: date) } == true
                case .upcoming:
                    guard let due = item.dueDate, !item.isCompleted else { return false }
                    guard let end = calendar.date(byAdding: .day, value: 14, to: calendar.startOfDay(for: date)) else { return false }
                    return due >= calendar.startOfDay(for: date) && due <= end
                case .completed:
                    return item.isCompleted
                case .list(let id):
                    return item.listID == id
                case .archived, .smart:
                    return false
                }
            }
        }

        let filtered = base.filter { item in
            if let tag = query.tag,
               !item.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) { return false }
            if let priority = query.priority, item.priority != priority { return false }
            if let due = query.date, !calendar.isDate(item.dueDate ?? .distantPast, inSameDayAs: due) { return false }
            guard !tokens.isEmpty else { return true }
            let listTitle = store.lists.first { $0.id == item.listID }?.title ?? ""
            let text = FuzzySearch.text(for: item, listTitle: listTitle, resources: store.resources(for: item))
            return FuzzySearch.matches(text, tokens: tokens)
        }

        if !tokens.isEmpty {
            return filtered.sorted { lhs, rhs in
                let lTitle = tokens.contains { lhs.title.localizedCaseInsensitiveContains($0) }
                let rTitle = tokens.contains { rhs.title.localizedCaseInsensitiveContains($0) }
                if lTitle != rTitle { return lTitle }
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
        }
        if isSearchingQuery {
            return filtered.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        }
        if selection == .upcoming {
            return filtered.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        }
        return filtered.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
    }


    private func managerRow(_ item: ReminderItem, group: DueGroup?, at date: Date) -> some View {
        HStack(spacing: 8) {
            if isSelecting {
                Toggle("选择 \(item.title)", isOn: Binding(
                    get: { selectedIDs.contains(item.id) },
                    set: { selected in
                        if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            } else {
                Button {
                    perform { try store.setCompleted(item, !item.isCompleted) }
                } label: {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(item.isCompleted ? TaskViewColors.accent : Color.secondary.opacity(0.85))
                        .frame(width: 24, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!item.isWritable)
                .help(item.isCompleted ? "标为未完成" : "标为完成")
                .accessibilityLabel(item.isCompleted ? "恢复 \(item.title)" : "完成 \(item.title)")
            }
            ReminderRow(
                item: item,
                store: store,
                group: group,
                referenceDate: date,
                onOpen: { editor = .init(item: item) },
                onFocus: { onFocusTask(item) },
                onStartTimer: { onStartTaskTimer(item) },
                onContinue: { onContinueTask(item, $0) },
                showsCompletionButton: false
            )
        }
        .contextMenu {
            Button(item.isWritable ? "编辑事项" : "查看事项") { editor = .init(item: item) }
            if isArchivedScope {
                Divider()
                Button("恢复") { perform { try store.restoreArchived([item.id]) } }
                Button("删除", role: .destructive) { perform { try store.deleteArchived([item.id]) } }
            }
            if !store.resources(for: item).isEmpty {
                Button("继续", systemImage: "arrow.up.forward.app") { onContinueTask(item, false) }
                if !item.isCompleted {
                    Button("继续并开始计时", systemImage: "timer") { onContinueTask(item, true) }
                }
            }
            if !item.isCompleted {
                Button("开始倒计时", systemImage: "timer") { onStartTaskTimer(item) }
                Button("专注这件事…", systemImage: "hourglass") { onFocusTask(item) }
                if item.dueDate != nil {
                    Button("加入日历", systemImage: "calendar.badge.plus") {
                        Task {
                            guard await CalendarBridge.requestAccess() else {
                                store.errorMessage = "需要日历权限。请到系统设置里允许访问日历。"
                                return
                            }
                            do { try CalendarBridge.createEvent(for: item) }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            if item.isWritable {
                Button(item.isCompleted ? "恢复待办" : "标为完成") {
                    perform { try store.setCompleted(item, !item.isCompleted) }
                }
                if !isArchivedScope {
                    Button("归档") { perform { try store.archive([item]) } }
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
    case all, today, upcoming, completed, archived, list(String), smart(UUID)
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

private struct UpcomingSection: Identifiable {
    let day: Date
    let items: [ReminderItem]
    var id: Date { day }
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
    @MainActor
    static var accent: Color { AppPreferences.shared.accentTheme.color }
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

// MARK: - 分组表单（分组卡片 + 行标签 + 系统控件）

/// 分组卡片：浅灰圆角底 + 细描边，表单分区的公共容器。
private struct GroupedCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
    }
}

/// 卡片标题行：图标 + 标题 + 右侧可选附属控件。
private struct CardHeader<Accessory: View>: View {
    let title: String
    let icon: String?
    let accessory: Accessory

    init(_ title: String, icon: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.icon = icon
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

extension CardHeader where Accessory == EmptyView {
    init(_ title: String, icon: String? = nil) {
        self.init(title, icon: icon) { EmptyView() }
    }
}

/// 行标签 + 右侧系统控件（开关、菜单、滑杆、输入框）。
private struct FormRow<Content: View>: View {
    let label: String
    let help: String?
    let labelWidth: CGFloat
    let content: Content

    init(_ label: String, help: String? = nil, labelWidth: CGFloat = 56, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.labelWidth = labelWidth
        self.content = content()
    }

    private var row: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    var body: some View {
        if let help {
            row.help(help)
        } else {
            row
        }
    }
}

/// 行间分隔线（左缩进，与标签对齐）。
private struct RowSeparator: View {
    var body: some View {
        Divider()
            .padding(.leading, 12)
            .opacity(0.7)
    }
}

/// 卡片底部脚注（说明文字 / 状态）。
private struct CardFootnote: View {
    let text: String
    var mono: Bool = false

    var body: some View {
        Text(text)
            .font(mono ? .caption2.monospaced() : .caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 10)
    }
}

private struct ReminderRow: View {
    let item: ReminderItem
    @ObservedObject var store: TaskStore
    let group: DueGroup?
    let referenceDate: Date
    let onOpen: () -> Void
    let onFocus: () -> Void
    let onStartTimer: () -> Void
    let onContinue: (Bool) -> Void

    var showsCompletionButton = true
    @State private var hovering = false
    @State private var showsSubtasks = false
    @State private var confirmsParentCompletion = false

    private var isPinned: Bool { store.pinnedTaskIDs.contains(item.id) }
    private var completedSubtasks: Int { item.subtasks.filter(\.isCompleted).count }
    private var hasResources: Bool { !store.resources(for: item).isEmpty }
    private var isBlocked: Bool { !item.isCompleted && !item.dependsOn.isEmpty && store.blockedTaskIDs().contains(item.id) }

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
            if showsCompletionButton {
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
                .help(item.isCompleted ? "标为未完成" : "标为完成")
                .accessibilityLabel(item.isCompleted ? "恢复 \(item.title)" : "完成 \(item.title)")
            }

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
                            ForEach(item.tags.prefix(2), id: \.self) { tag in
                                Text("#\(tag)")
                                    .lineLimit(1)
                            }
                            if isBlocked {
                                Image(systemName: "link.circle")
                                    .accessibilityLabel("等待前置事项完成")
                                    .help("等待前置事项完成")
                            }
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

            if hasResources {
                Button("继续") { onContinue(false) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(TaskViewColors.accent)
                    .padding(.horizontal, 3)
                    .fixedSize()
                    .help("打开关联资料")
                    .accessibilityLabel("继续 \(item.title)")
            }

            if !item.isCompleted {
                Button("开始倒计时", systemImage: "timer", action: onStartTimer)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(TaskViewColors.accent)
                    .frame(width: 23, height: 30)
                    .contentShape(.rect)
                    .help("开始倒计时")
                    .accessibilityLabel("开始 \(item.title) 的倒计时")
                    .accessibilityIdentifier("start-task-countdown")
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
            if hasResources {
                Button("继续并开始计时", systemImage: "timer") { onContinue(true) }
            }
            Button("专注这件事…", systemImage: "hourglass", action: onFocus)
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
    @State private var tagsText = ""
    @State private var message: String?
    @State private var showDelete = false
    @State private var dateWasSetManually = false
    @State private var isSaving = false
    @State private var showTemplateName = false
    @State private var templateName = ""
    @State private var templateToDelete: ReminderTemplate?
    @State private var showResourceLink = false
    @State private var resourceLink = ""
    @State private var aiLoading = false
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
        _tagsText = State(initialValue: request.item?.tags.joined(separator: " ") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                header
                Divider().opacity(0.55)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        basicCard
                        dateCard
                        resourceCard
                        if selectedList?.source == .local {
                            subtaskCard
                            tagsCard
                        }
                    }
                    .disabled(request.item?.isWritable == false)
                    if request.item?.isWritable == false {
                        Label("此清单只读", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message { errorMessage(message) { self.message = nil } }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.top)

            Divider().opacity(0.55)
            footer
        }
        .task { if request.item == nil { titleFocused = true } }
        .confirmationDialog("删除此事项？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: delete)
            Button("取消", role: .cancel) {}
        }
        .alert("添加网页链接", isPresented: $showResourceLink) {
            TextField("网址", text: $resourceLink)
            Button("添加", action: addResourceLink)
                .disabled(resourceLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 布局

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(request.item == nil ? "新建提醒事项" : "提醒事项详情")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    private var footer: some View {
        HStack {
            if request.item?.isWritable == true {
                Button("删除事项", systemImage: "trash", role: .destructive) { showDelete = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("删除事项")
            }
            if let item = request.item, request.item?.isWritable != false {
                Button("加入日历", systemImage: "calendar.badge.plus") {
                    Task {
                        guard await CalendarBridge.requestAccess() else {
                            message = "需要日历权限。请在系统设置里允许浮光提醒访问日历。"
                            return
                        }
                        do {
                            try CalendarBridge.createEvent(for: item)
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("把事项写入 Apple 日历（1 小时事件，到点提醒）")
                .accessibilityIdentifier("add-to-calendar")
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

    // MARK: - 卡片

    private var basicCard: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("基本信息")
                TextField("标题", text: $draft.title)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { save() }
                    .accessibilityIdentifier("task-title")
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                if let suggestion = dateSuggestion {
                    Button {
                        applyDateSuggestion(suggestion, to: &draft)
                    } label: {
                        Label(suggestionLabel(suggestion), systemImage: "calendar.badge.plus")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("apply-suggested-date")
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
                TextField("备注", text: $draft.notes, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("task-notes")
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                RowSeparator()
                FormRow("清单") {
                    Picker("清单", selection: $draft.listID) {
                        ForEach(availableLists, id: \.id) { list in
                            Text("\(list.title) · \(listSourceLabel(list))").tag(list.id)
                        }
                        if !availableLists.contains(where: { $0.id == draft.listID }) {
                            Text("未选择清单").tag(draft.listID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("task-list-picker")
                }
                RowSeparator()
                FormRow("优先级") {
                    Picker("优先级", selection: $draft.priority) {
                        ForEach([ReminderPriority.none, .low, .medium, .high], id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                        if request.item?.priority == .custom { Text(ReminderPriority.custom.label).tag(ReminderPriority.custom) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if hasSubtasksInAppleList {
                    HStack(spacing: 5) {
                        Image(systemName: "checklist")
                            .accessibilityHidden(true)
                        Text("请选择本机清单以保留子任务")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var dateCard: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("日期与时间")
                FormRow("设定日期") {
                    Toggle("设定日期", isOn: dateEnabledBinding)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if draft.dueDate != nil {
                    RowSeparator()
                    FormRow("日期") {
                        DatePicker("日期", selection: dueDateBinding, displayedComponents: draft.hasTime ? [.date, .hourAndMinute] : [.date])
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    RowSeparator()
                    FormRow("设定时间") {
                        Toggle("设定时间", isOn: hasTimeBinding)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    RowSeparator()
                    FormRow("到时提醒") {
                        Toggle("到时提醒", isOn: $draft.alerts)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .disabled(!draft.hasTime)
                    }
                    RowSeparator()
                    FormRow("重复") {
                        Picker("重复", selection: $draft.repeatRule) {
                            ForEach([ReminderRepeat.never, .daily, .weekly, .monthly, .yearly], id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                            if request.item?.repeatRule == .custom { Text(ReminderRepeat.custom.label).tag(ReminderRepeat.custom) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var tagsCard: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("标签与依赖")
                FormRow("标签") {
                    HStack(spacing: 8) {
                        TextField("用空格分隔，例如：工作 面试", text: $tagsText)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("task-tags")
                        if !store.allTags.isEmpty {
                            Menu {
                                ForEach(store.allTags, id: \.self) { tag in
                                    Button(tag) { addTag(tag) }
                                }
                            } label: {
                                Image(systemName: "tag")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("从已有标签中选择")
                        }
                    }
                }
                RowSeparator()
                FormRow("前置事项", help: "完成前置事项后，这条事项才算就绪") {
                    HStack(spacing: 6) {
                        if draft.dependsOn.isEmpty {
                            Text("无")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(draft.dependsOn, id: \.self) { id in
                                Text(store.tasks.first { $0.id == id }?.title ?? id)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.primary.opacity(0.06), in: .rect(cornerRadius: 4))
                            }
                            Button("清空前置事项", systemImage: "xmark.circle") { draft.dependsOn.removeAll() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("清空前置事项")
                        }
                        Spacer(minLength: 4)
                        Menu {
                            let candidates = store.tasks.filter {
                                $0.source == .local && !$0.isCompleted && $0.id != request.item?.id
                            }
                            if candidates.isEmpty {
                                Text("没有其他待办事项").font(.caption)
                            }
                            ForEach(candidates) { candidate in
                                let selected = draft.dependsOn.contains(candidate.id)
                                Button {
                                    if selected {
                                        draft.dependsOn.removeAll { $0 == candidate.id }
                                    } else {
                                        draft.dependsOn.append(candidate.id)
                                    }
                                } label: {
                                    if selected {
                                        Label(candidate.title, systemImage: "checkmark")
                                    } else {
                                        Text(candidate.title)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.turn.down.right")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("添加前置事项")
                    }
                }
            }
        }
    }

    private func addTag(_ tag: String) {
        let parts = tagsText.split(whereSeparator: \.isWhitespace).map(String.init)
        if !parts.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            tagsText = (parts + [tag]).joined(separator: " ")
        }
    }

    private var resourceCard: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("关联资料", icon: "paperclip") {
                    addResourceMenu
                }
                if draft.resources.isEmpty {
                    Text("没有关联资料，可添加网页链接或本地文件。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                } else {
                    ForEach(draft.resources) { resource in
                        HStack(spacing: 6) {
                            ResourceThumbnail(resource: resource)
                            Text(resource.title)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(resource.kind == .web ? resource.url.absoluteString : resource.url.path)
                            Spacer(minLength: 4)
                            Button("移除 \(resource.title)", systemImage: "xmark.circle") {
                                draft.resources.removeAll { $0.id == resource.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("移除关联")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private var addResourceMenu: some View {
        Menu {
            Button("添加网页链接", systemImage: "link") {
                resourceLink = ""
                showResourceLink = true
            }
            Button("选择文件或文件夹…", systemImage: "folder", action: chooseResourceFiles)
        } label: {
            Label("添加资料", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加资料")
        .accessibilityIdentifier("add-task-resource")
    }

    private func addResourceLink() {
        let input = resourceLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = URLComponents(string: input)?.scheme == nil ? "https://" + input : input
        guard let url = URL(string: address), let resource = ReminderResource(url: url), resource.kind == .web else {
            message = "请输入有效的网页链接。"
            return
        }
        appendResource(resource)
    }

    private func chooseResourceFiles() {
        let panel = NSOpenPanel()
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let resource = ReminderResource(url: url) { appendResource(resource) }
            }
        }
    }

    private func appendResource(_ resource: ReminderResource) {
        if !draft.resources.contains(where: { $0.url == resource.url }) {
            draft.resources.append(resource)
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

    private var subtaskCard: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("子任务", icon: "checklist") {
                    HStack(spacing: 2) {
                        aiSplitButton
                        templateMenu
                    }
                }
                if draft.subtasks.isEmpty {
                    Text("把大事项拆成小步骤，逐步完成。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                }
                ForEach($draft.subtasks) { $subtask in
                    let id = subtask.id
                    HStack(spacing: 7) {
                        Toggle("完成子任务", isOn: $subtask.isCompleted)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel(subtask.title.isEmpty ? "完成子任务" : "完成 \(subtask.title)")
                        TextField("子任务标题", text: $subtask.title)
                            .textFieldStyle(.plain)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
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
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
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

    private var aiSplitButton: some View {
        Button {
            Task { await splitWithAI() }
        } label: {
            if aiLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("AI 拆解", systemImage: "sparkles")
                    .font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .disabled(aiLoading
                  || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || !ProLicense.shared.isActive)
        .help(ProLicense.shared.isActive
              ? "用 AI 把事项拆成子任务"
              : "需要 Pro 许可，可在设置里输入演示码 \(ProLicense.demoCode)")
        .accessibilityIdentifier("ai-split-subtasks")
    }

    private func splitWithAI() async {
        aiLoading = true
        defer { aiLoading = false }
        do {
            let titles = try await AIService.shared.splitSubtasks(title: draft.title, notes: draft.notes)
            guard !titles.isEmpty else { throw AIService.AIError.badResponse }
            let existing = Set(draft.subtasks.map { $0.title })
            for title in titles where !existing.contains(title) {
                draft.subtasks.append(ReminderSubtask(title: title))
            }
        } catch {
            message = error.localizedDescription
        }
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

    private var dateEnabledBinding: Binding<Bool> {
        Binding(get: { draft.dueDate != nil }, set: { isOn in
            dateWasSetManually = true
            draft.dueDate = isOn ? Calendar.current.startOfDay(for: .now) : nil
            if !isOn {
                draft.hasTime = false
                draft.alerts = false
                draft.repeatRule = .never
            }
        })
    }

    private var hasTimeBinding: Binding<Bool> {
        Binding(get: { draft.hasTime }, set: { hasTime in
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
        })
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
        savedDraft.tags = tagsText.split(whereSeparator: \.isWhitespace).map(String.init)
        if selectedList?.source != .local { savedDraft.dependsOn = [] }
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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.list == nil ? "新建本机清单" : "重命名清单")
                    .font(.system(size: 15, weight: .semibold))
                Text("本机清单保存在这台 Mac 上，不依赖 Apple 提醒事项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 11)

            Divider().opacity(0.55)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("名称")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    TextField("清单名称", text: $title)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("list-name")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                if let message {
                    Divider().padding(.leading, 12)
                    errorMessage(message) { self.message = nil }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Spacer(minLength: 0)

            Divider().opacity(0.55)
            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-list")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
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
private struct SmartListEditor: View {
    let store: TaskStore
    let onClose: () -> Void

    private enum RuleKind: String, CaseIterable, Identifiable {
        case tag, priority, overdue, dueInDays, noDueDate, list

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tag: "包含标签"
            case .priority: "指定优先级"
            case .overdue: "已逾期"
            case .dueInDays: "即将到期"
            case .noDueDate: "未安排日期"
            case .list: "来自清单"
            }
        }

        var symbol: String {
            switch self {
            case .tag: "number"
            case .priority: "exclamationmark.circle"
            case .overdue: "clock.badge.exclamationmark"
            case .dueInDays: "calendar.badge.clock"
            case .noDueDate: "calendar"
            case .list: "list.bullet"
            }
        }

        var detailTitle: String {
            switch self {
            case .tag: "标签"
            case .priority: "优先级"
            case .dueInDays: "范围"
            case .list: "清单"
            case .overdue, .noDueDate: ""
            }
        }

        var hasDetail: Bool {
            switch self {
            case .tag, .priority, .dueInDays, .list: true
            case .overdue, .noDueDate: false
            }
        }
    }

    @State private var name = ""
    @State private var kind: RuleKind = .tag
    @State private var tagName = ""
    @State private var priorityLevel: ReminderPriority = .high
    @State private var dueDays = 7
    @State private var listID = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 10) {
                ruleCard
                footnote
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(TaskViewColors.overdue)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider().opacity(0.55)
            footer
        }
        .frame(width: 430)
        .task {
            if listID.isEmpty { listID = store.lists.first?.id ?? "" }
        }
        .onChange(of: store.lists.map(\.id)) { _, ids in
            if !ids.contains(listID) { listID = ids.first ?? "" }
        }
    }

    // MARK: - 布局

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("新建智能清单")
                    .font(.system(size: 15, weight: .semibold))
                Text("按条件自动聚合待办，事项仍留在原清单")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !SmartRule.builtIn.isEmpty {
                templateMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    private var templateMenu: some View {
        Menu {
            ForEach(SmartRule.builtIn) { template in
                Button(template.name) {
                    name = template.name
                    apply(template.rule)
                }
            }
        } label: {
            Label("模板", systemImage: "square.on.square")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("用内置模板快速创建")
    }

    private var ruleCard: some View {
        VStack(spacing: 0) {
            row("名称") {
                TextField("例如：本周面试", text: $name)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("smart-list-name")
            }
            separator
            row("条件") {
                Picker("条件", selection: $kind) {
                    ForEach(RuleKind.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if kind.hasDetail {
                separator
                row(kind.detailTitle) { detailControl }
            }
            separator
            row("匹配") {
                HStack(spacing: 5) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(TaskViewColors.accent)
                    Text(rule == nil ? "未设置条件" : "\(matchCount) 项")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
    }

    private var footnote: some View {
        Text("智能清单是筛选视图：改事项本身请到它所在的清单。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("取消", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("保存", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var separator: some View {
        Divider().padding(.leading, 12).opacity(0.7)
    }

    @ViewBuilder private var detailControl: some View {
        switch kind {
        case .tag:
            TextField("例如：工作", text: $tagName)
                .textFieldStyle(.plain)
        case .priority:
            Picker("优先级", selection: $priorityLevel) {
                Text("高").tag(ReminderPriority.high)
                Text("中").tag(ReminderPriority.medium)
                Text("低").tag(ReminderPriority.low)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .dueInDays:
            Picker("范围", selection: $dueDays) {
                Text("1 天内").tag(1)
                Text("3 天内").tag(3)
                Text("7 天内").tag(7)
                Text("14 天内").tag(14)
                Text("30 天内").tag(30)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .list:
            Picker("清单", selection: $listID) {
                ForEach(store.lists, id: \.id) { list in
                    Text(list.title).tag(list.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .overdue, .noDueDate:
            EmptyView()
        }
    }

    // MARK: - 数据

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && rule != nil
    }

    private var matchCount: Int {
        rule.map { store.items(matching: $0).count } ?? 0
    }

    private var rule: SmartRule? {
        switch kind {
        case .tag:
            let tag = tagName.trimmingCharacters(in: .whitespaces)
            return tag.isEmpty ? nil : SmartRule.tag(tag)
        case .priority:
            return .priority(priorityLevel)
        case .overdue:
            return .overdue
        case .dueInDays:
            return .dueInDays(dueDays)
        case .noDueDate:
            return .noDueDate
        case .list:
            return listID.isEmpty ? nil : .list(listID)
        }
    }

    private func apply(_ templateRule: SmartRule) {
        switch templateRule {
        case let .tag(value):
            kind = .tag
            tagName = value
        case let .priority(value):
            kind = .priority
            priorityLevel = value
        case .overdue:
            kind = .overdue
        case let .dueInDays(value):
            kind = .dueInDays
            dueDays = value
        case .noDueDate:
            kind = .noDueDate
        case let .list(value):
            kind = .list
            listID = value
        }
    }

    private func save() {
        guard let rule else { return }
        do {
            try store.createSmartList(name: name, rule: rule)
            onClose()
        } catch {
            message = error.localizedDescription
        }
    }
}

@MainActor
private struct StatsSheet: View {
    let store: TaskStore
    let onClose: () -> Void
    @ObservedObject var ai = AIService.shared
    @ObservedObject var license = ProLicense.shared
    @State private var reportText: String?
    @State private var reportError: String?
    @State private var reportLoading = false

    private static let palette: [Color] = [.blue, .teal, .indigo, .green, .orange, .pink]

    private var stats: TaskStats {
        TaskStats(tasks: store.tasks, lists: store.lists)
    }

    var body: some View {
        let stats = self.stats
        VStack(alignment: .leading, spacing: 20) {
            Text("统计")
                .font(.system(size: 17, weight: .semibold))

            HStack(spacing: 10) {
                statCard("待办", value: stats.openTotal, icon: "tray.fill", color: .blue)
                statCard("已完成", value: stats.completedTotal, icon: "checkmark.circle.fill", color: .green)
                statCard("逾期", value: stats.overdue, icon: "exclamationmark.circle.fill", color: .red)
                statCard("连续完成", value: stats.streak, icon: "flame.fill", color: .orange)
            }

            barChart(stats)

            distribution(stats)

            aiReportSection

            HStack {
                Spacer()
                Button("关闭", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: - 指标卡片

    private func statCard(_ title: String, value: Int, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text("\(value)")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 14 天柱状图

    private func barChart(_ stats: TaskStats) -> some View {
        let maxCount = max(1, stats.dailyCompletions.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("近 14 天完成")
                .font(.system(size: 13, weight: .semibold))
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(stats.dailyCompletions) { entry in
                    VStack(spacing: 5) {
                        Text(entry.count == 0 ? "" : "\(entry.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(entry.count == 0 ? Color.primary.opacity(0.08) : TaskViewColors.accent)
                            .frame(width: 14, height: max(3, CGFloat(entry.count) / CGFloat(maxCount) * 72))
                        Text(weekdayLetter(entry.day))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110, alignment: .bottom)
        }
    }

    // MARK: - 分布

    private func distribution(_ stats: TaskStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分布")
                .font(.system(size: 13, weight: .semibold))
            if stats.byList.isEmpty && stats.byTag.isEmpty {
                Text("暂无待办事项")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(stats.byList.prefix(5).enumerated()), id: \.element.title) { index, row in
                    distributionRow(row.title, count: row.count, total: stats.openTotal,
                                     color: Self.palette[index % Self.palette.count])
                }
                ForEach(Array(stats.byTag.prefix(5).enumerated()), id: \.element.tag) { index, row in
                    distributionRow("#" + row.tag, count: row.count, total: stats.openTotal,
                                     color: Self.palette[(index + 3) % Self.palette.count])
                }
            }
        }
    }

    private func distributionRow(_ label: String, count: Int, total: Int, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(color)
                        .frame(width: total == 0 ? 0 : max(0, proxy.size.width * CGFloat(count) / CGFloat(total)))
                }
            }
            .frame(height: 8)
            Text("\(count)")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: - AI 周报

    private var aiReportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI 周报")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    Task { await generateReport(stats) }
                } label: {
                    if reportLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("生成", systemImage: "sparkles").font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(reportLoading || !license.isActive || !ai.hasKey)
                .help(!license.isActive ? "需要 Pro 许可" : (ai.hasKey ? "用 AI 生成本周简报" : "先在设置里配置 API Key"))
            }
            if let reportError {
                Text(reportError)
                    .font(.system(size: 12))
                    .foregroundStyle(TaskViewColors.overdue)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reportText {
                Text(reportText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            } else if !license.isActive {
                Text("输入 Pro 许可码后可用（设置里可填演示码）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func weekdayLetter(_ day: Date) -> String {
        let index = Calendar.current.component(.weekday, from: day)
        let letters = "一二三四五六日"
        return String(letters[letters.index(letters.startIndex, offsetBy: (index + 5) % 7)])
    }

    private func generateReport(_ stats: TaskStats) async {
        reportLoading = true
        reportError = nil
        defer { reportLoading = false }
        let focus = FocusTimer.storedFocusStats()
        let weekDone = stats.dailyCompletions.map(\.count).reduce(0, +)
        let taskSummary = "待办 \(stats.openTotal) 项，已完成 \(stats.completedTotal) 项，逾期 \(stats.overdue) 项，连续完成 \(stats.streak) 天；近 14 天完成 \(weekDone) 项"
        let focusSummary = "近 7 天专注 \(Int(Double(focus.weekSeconds) / 3600.0)) 小时 \(focus.weekRounds) 轮，累计 \(Int(Double(focus.totalSeconds) / 3600.0)) 小时"
        do {
            reportText = try await AIService.shared.weeklyReport(taskSummary: taskSummary, focusSummary: focusSummary)
        } catch {
            reportError = error.localizedDescription
        }
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

@MainActor
private struct SettingsSheet: View {
    @ObservedObject var prefs: AppPreferences
    @ObservedObject var ai = AIService.shared
    @ObservedObject var license = ProLicense.shared
    @StateObject private var sync: CloudKitSync
    let onClose: () -> Void

    @State private var keyDraft = ""
    @State private var licenseDraft = ""
    @State private var syncMessage: String?
    @State private var aiMessage: String?
    @State private var copiedToken = false

    private static let labelWidth: CGFloat = 108

    private static let soundNames = ["Pop", "Ping", "Glass", "Tink", "Blow", "Purr", "Submarine", "Basso", "Frog", "Funk", "Morse", "Sosumi", "Bottle"]

    init(store: TaskStore, prefs: AppPreferences, onClose: @escaping () -> Void) {
        self.prefs = prefs
        self.onClose = onClose
        _sync = StateObject(wrappedValue: CloudKitSync(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置")
                        .font(.system(size: 15, weight: .semibold))
                    Text("主题、提醒、收件箱、同步与 AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 11)

            Divider().opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    appearanceSection
                    feedbackSection
                    inboxSection
                    syncSection
                    aiSection
                    aboutSection
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 620)
        .task { await sync.refreshAuthorization() }
    }

    // MARK: - 分区

    private var appearanceSection: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("外观", icon: "paintpalette")
                settingsRow("主题") {
                    HStack(spacing: 14) {
                        ForEach(AppTheme.allCases) { theme in
                            themeSwatch(theme)
                        }
                    }
                }
                RowSeparator()
                settingsRow("面板透明度", help: "浮窗与管理窗口的背景不透明度") {
                    HStack(spacing: 8) {
                        Slider(value: $prefs.panelOpacity, in: 0.4...1)
                        Text("\(Int(prefs.panelOpacity * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func themeSwatch(_ theme: AppTheme) -> some View {
        Button {
            prefs.theme = theme.rawValue
        } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(theme.color)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle().strokeBorder(
                            .primary.opacity(prefs.theme == theme.rawValue ? 0.6 : 0.15),
                            lineWidth: 1.5
                        )
                    )
                Text(theme.label)
                    .font(.caption2)
                    .foregroundStyle(prefs.theme == theme.rawValue ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(theme.label)
    }

    private var feedbackSection: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("反馈", icon: "bell.badge")
                settingsRow("完成提示音", help: "完成事项时播放提示音") {
                    Toggle("完成事项时播放提示音", isOn: $prefs.soundEnabled)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                RowSeparator()
                settingsRow("提示音", help: "点击喇叭图标试听") {
                    HStack(spacing: 8) {
                        Picker("提示音", selection: $prefs.completionSound) {
                            ForEach(Self.soundNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                        Spacer(minLength: 0)
                        Button {
                            if let sound = NSSound(named: NSSound.Name(prefs.completionSound)) { sound.play() }
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("试听提示音")
                    }
                    .disabled(!prefs.soundEnabled)
                }
                RowSeparator()
                settingsRow("完成动画", help: "完成事项时播放粒子小动画") {
                    Toggle("完成事项时播放小动画", isOn: $prefs.celebrationEnabled)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                RowSeparator()
                settingsRow("彩虹细线", help: "在浮窗顶部显示彩虹细线") {
                    Toggle("彩虹细线", isOn: $prefs.rainbowHairline)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var inboxSection: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("收件箱", icon: "tray")
                settingsRow("剪贴板自动收集", help: "在其他应用复制文本、链接或文件时，自动存入浮光收件箱") {
                    Toggle("剪贴板自动收集", isOn: $prefs.clipboardAutoCapture)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                RowSeparator()
                settingsRow("本地接口") {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text("http://127.0.0.1:\(LocalHTTPInbox.port)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
                RowSeparator()
                settingsRow("Token") {
                    HStack(spacing: 6) {
                        Text(tokenValue)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button(copiedToken ? "已复制" : "复制", action: copyToken)
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
                CardFootnote(
                    text: "curl -X POST http://127.0.0.1:\(LocalHTTPInbox.port)/inbox -H \"X-Fuguang-Token: <token>\" -d '{\"title\":\"看文档\"}'",
                    mono: true
                )
            }
        }
    }

    private var syncSection: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("跨设备同步（CloudKit）", icon: "icloud")
                settingsRow("容器 ID", help: "需要在 Apple 开发者后台创建同名 CloudKit 容器") {
                    TextField("iCloud.local.fuguang.EdgeReminders", text: $sync.containerID)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                RowSeparator()
                settingsRow("同步") {
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                if let epoch = await sync.push() {
                                    syncMessage = "已上传（\(Date(timeIntervalSince1970: Double(epoch)).formatted(.dateTime.month().day().hour().minute()))）"
                                } else {
                                    syncMessage = syncStatusText
                                }
                            }
                        } label: {
                            Label("上传本机数据", systemImage: "arrow.up.circle")
                        }
                        .controlSize(.small)
                        Button {
                            Task {
                                let restored = await sync.pull()
                                syncMessage = restored ? "已从云端恢复。" : syncStatusText
                            }
                        } label: {
                            Label("从云端恢复", systemImage: "arrow.down.circle")
                        }
                        .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                    .disabled(sync.status == .working)
                }
                RowSeparator()
                settingsRow("状态") {
                    Text(syncMessage ?? syncStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                CardFootnote(text: "默认容器 iCloud.local.fuguang.EdgeReminders，需在开发者后台创建。")
            }
        }
    }

    private var aiSection: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("AI 助手", icon: "sparkles")
                if license.isActive {
                    settingsRow("Pro") {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                            Text("已激活")
                        }
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    settingsRow("许可码", help: "AI 拆子任务与 AI 周报需要 Pro；演示码 \(ProLicense.demoCode)") {
                        HStack(spacing: 8) {
                            TextField("输入 Pro 许可码", text: $licenseDraft)
                                .textFieldStyle(.plain)
                                .font(.caption)
                            Button("激活", action: activateLicense)
                                .controlSize(.small)
                        }
                    }
                }
                RowSeparator()
                settingsRow("接口地址", help: "OpenAI 兼容的 /chat/completions 服务地址") {
                    TextField("OpenAI 兼容接口", text: $ai.endpoint)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                RowSeparator()
                settingsRow("模型") {
                    TextField("模型名称", text: $ai.model)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                RowSeparator()
                settingsRow("API Key", help: "保存在钥匙串中") {
                    HStack(spacing: 8) {
                        SecureField("输入 API Key", text: $keyDraft)
                            .textFieldStyle(.plain)
                            .font(.caption)
                        Button("保存", action: saveKey)
                            .controlSize(.small)
                    }
                }
                CardFootnote(text: aiMessage ?? (ai.hasKey ? "Key 已保存。" : "尚未设置 Key。"))
            }
        }
    }

    private var aboutSection: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("关于", icon: "info.circle")
                settingsRow("版本") {
                    Text("浮光提醒 \(versionText)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                RowSeparator()
                settingsRow("启动时检查更新") {
                    Toggle("启动时检查更新", isOn: $prefs.autoCheckUpdates)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                RowSeparator()
                settingsRow("链接") {
                    HStack(spacing: 14) {
                        Button("项目主页") { openLink("https://github.com/giracle/EdgeReminders") }
                            .buttonStyle(.link)
                            .font(.caption)
                        Button("产品页") { openLink("https://giracle.github.io/EdgeReminders/showcase/") }
                            .buttonStyle(.link)
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func settingsRow<Content: View>(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        FormRow(label, help: help, labelWidth: Self.labelWidth, content: content)
    }

    private func activateLicense() {
        if license.activate(licenseDraft) {
            licenseDraft = ""
            aiMessage = "Pro 已激活。"
        } else {
            aiMessage = "许可码无效。演示码：\(ProLicense.demoCode)"
        }
    }

    private func saveKey() {
        ai.saveKey(keyDraft)
        keyDraft = ""
        aiMessage = ai.hasKey ? "Key 已保存。" : "Key 已清除。"
    }

    private var tokenValue: String {
        UserDefaults.standard.string(forKey: "httpInbox.token") ?? "—"
    }

    private var syncStatusText: String {
        switch sync.status {
        case .idle:
            return "尚未连接 iCloud。"
        case .working:
            return "正在同步…"
        case .ready:
            let last = sync.lastPushDate?.formatted(.dateTime.month().day().hour().minute()) ?? "从未"
            return "iCloud 可用。上次上传：\(last)"
        case .denied:
            return "iCloud 未授权。请在系统设置中登录 iCloud。"
        case .failed(let message):
            return message
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tokenValue, forType: .string)
        copiedToken = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedToken = false
        }
    }

    private func openLink(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

@MainActor
private struct ResourceThumbnail: View {
    let resource: ReminderResource
    @State private var image: NSImage?

    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"]

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: resource.kind == .web ? "link" : "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .onAppear(perform: load)
    }

    private func load() {
        guard resource.kind == .file, image == nil,
              Self.imageExtensions.contains(resource.url.pathExtension.lowercased()) else { return }
        let url = resource.url
        Task { @MainActor in
            guard let loaded = NSImage(contentsOf: url) else { return }
            let scaled = NSImage(size: NSSize(width: 22, height: 22))
            scaled.lockFocus()
            loaded.draw(
                in: NSRect(x: 0, y: 0, width: 22, height: 22),
                from: NSRect(origin: .zero, size: loaded.size),
                operation: .copy, fraction: 1
            )
            scaled.unlockFocus()
            self.image = scaled
        }
    }
}
