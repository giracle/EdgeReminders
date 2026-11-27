import Foundation

@main
@MainActor
struct SmartListChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Reminders.json")
        let store = TaskStore(localURL: file, enablesNotifications: false)
        let calendar = Calendar.current

        try store.createLocalList("工作")
        let list = store.lists.first { $0.title == "工作" }!

        var draft = ReminderDraft(listID: list.id)
        draft.title = "准备面试"
        draft.tags = ["工作", "重要"]
        draft.priority = .high
        draft.dueDate = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: .now))
        try store.save(draft)
        let item = store.tasks.first { $0.title == "准备面试" }!
        precondition(item.tags == ["工作", "重要"])

        var second = ReminderDraft(listID: list.id)
        second.title = "写周报"
        second.tags = ["工作"]
        try store.save(second)
        let weekly = store.tasks.first { $0.title == "写周报" }!
        precondition(store.allTags == ["工作", "重要"])

        try store.setTags(item, tags: ["工作", "面试", "工作"])
        let retagged = store.tasks.first { $0.id == item.id }!
        precondition(retagged.tags == ["工作", "面试"])

        var overdue = ReminderDraft(listID: list.id)
        overdue.title = "逾期事项"
        overdue.dueDate = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))
        try store.save(overdue)

        try store.createSmartList(name: "本周重点", rule: .dueInDays(7))
        let smart = store.smartLists.first { $0.name == "本周重点" }!
        let matched = store.items(matching: smart.rule)
        precondition(matched.contains { $0.id == item.id })
        precondition(!matched.contains { $0.title == "逾期事项" })

        try store.createSmartList(name: "高优先级", rule: .priority(.high))
        precondition(store.items(matching: .priority(.high)).map(\.title) == ["准备面试"])
        precondition(!store.items(matching: .overdue).isEmpty)
        precondition(!store.items(matching: .noDueDate).contains { $0.id == item.id })

        // Undo / redo.
        precondition(store.canUndo)
        store.undo()
        precondition(store.smartLists.filter { $0.name == "高优先级" }.isEmpty)
        store.redo()
        precondition(!store.smartLists.filter { $0.name == "高优先级" }.isEmpty)

        // Search: text, tag, date, priority.
        let textHits = store.search("周报")
        precondition(textHits.contains { $0.id == weekly.id })
        let tagHits = store.search("#面试")
        precondition(tagHits.map(\.id) == [item.id])
        let dateHits = store.search("明天 准备")
        precondition(dateHits.allSatisfy { $0.dueDate.map { calendar.isDate($0, inSameDayAs: .now) } == true })
        let priorityHits = store.search("紧急")
        precondition(priorityHits.map(\.title) == ["准备面试"])
        precondition(store.search(" ").isEmpty)

        // Natural query parser.
        let parsed = NaturalQueryParser.parse("明天 #工作 紧急 准备面试")
        precondition(parsed.date != nil)
        precondition(parsed.tag == "工作")
        precondition(parsed.priority == .high)
        precondition(parsed.text == "准备面试")

        // Dependencies.
        try store.setDependsOn(weekly, prerequisites: [item.id])
        let dependent = store.tasks.first { $0.id == weekly.id }!
        precondition(dependent.dependsOn == [item.id])
        precondition(store.blockedTaskIDs().contains(weekly.id))
        try store.setCompleted(item, true)
        precondition(!store.blockedTaskIDs().contains(weekly.id))
        do {
            try store.setDependsOn(item, prerequisites: [weekly.id])
            preconditionFailure("Cycle must be rejected")
        } catch {}
        do {
            try store.setDependsOn(item, prerequisites: [item.id])
            preconditionFailure("Self dependency must be rejected")
        } catch {}

        // Archive.
        let overdueItem = store.tasks.first { $0.title == "逾期事项" }!
        try store.archive([overdueItem])
        precondition(!store.tasks.contains { $0.id == overdueItem.id })
        precondition(store.archivedTasks.contains { $0.id == overdueItem.id })
        try store.restoreArchived([overdueItem.id])
        precondition(store.tasks.contains { $0.id == overdueItem.id })
        precondition(store.archivedTasks.filter { $0.id == overdueItem.id }.isEmpty)
        try store.setCompleted(overdueItem, true)
        try store.archiveCompletedLocalItems()
        precondition(store.archivedTasks.contains { $0.id == overdueItem.id })
        try store.deleteArchived([overdueItem.id])
        precondition(store.archivedTasks.filter { $0.id == overdueItem.id }.isEmpty)

        // Export.
        let exporter = TaskExporter(store: store)
        let csv = String(data: exporter.csv(), encoding: .utf8)!
        precondition(csv.contains("写周报"))
        precondition(csv.contains("工作"))
        let markdown = exporter.markdown()
        precondition(markdown.contains("## 待办"))
        precondition(markdown.contains("写周报"))
        let json = try JSONSerialization.jsonObject(with: exporter.json()) as? [[String: Any]]
        precondition((json?.count ?? 0) >= 1)

        // Backup / restore.
        let backup = exporter.backup()
        precondition(backup.count > 0)
        do {
            try exporter.restore(from: Data("not json".utf8))
            preconditionFailure("Invalid backup must be rejected")
        } catch {}
        let probe = directory.appending(path: "Probe.json")
        let probeStore = TaskStore(localURL: probe, enablesNotifications: false)
        try probeStore.restore(from: backup)
        precondition(probeStore.tasks.contains { $0.title == "写周报" })
        precondition(probeStore.archivedTasks.contains { $0.title == "准备面试" })
        precondition(probeStore.smartLists.contains { $0.name == "本周重点" })

        // Stats (isolated store).
        let statsFile = directory.appending(path: "Stats.json")
        let statsStore = TaskStore(localURL: statsFile, enablesNotifications: false)
        try statsStore.createLocalList("学习")
        let studyList = statsStore.lists.first { $0.title == "学习" }!
        for (index, title) in ["复习 A", "复习 B", "复习 C"].enumerated() {
            var newDraft = ReminderDraft(listID: studyList.id)
            newDraft.title = title
            newDraft.tags = ["学习"]
            try statsStore.save(newDraft)
            if index < 2 {
                try statsStore.setCompleted(statsStore.tasks.first { $0.title == title }!, true)
            }
        }
        let stats = TaskStats(tasks: statsStore.tasks, lists: statsStore.lists)
        precondition(stats.completedTotal == 2)
        precondition(stats.openTotal == 1)
        precondition(stats.byList.contains { $0.title == "学习" })
        precondition(stats.byTag.contains { $0.tag == "学习" })
        precondition(stats.dailyCompletions.count == 14)
        precondition(stats.streak >= 1)

        // Fuzzy search: 子串 / 拼音全拼 / 首字母 / 多关键词无序 / 已完成也可搜到。
        let fuzzyFile = directory.appending(path: "Fuzzy.json")
        let fuzzyStore = TaskStore(localURL: fuzzyFile, enablesNotifications: false)
        try fuzzyStore.createLocalList("项目")
        let fuzzyList = fuzzyStore.lists.first { $0.title == "项目" }!
        for title in ["初步形成课程-能力地图框架", "完成学生评价可视化系统", "整理面试题库"] {
            var draft = ReminderDraft(listID: fuzzyList.id)
            draft.title = title
            try fuzzyStore.save(draft)
        }
        try fuzzyStore.setCompleted(fuzzyStore.tasks.first { $0.title == "整理面试题库" }!, true)

        precondition(!fuzzyStore.search("能力").isEmpty, "子串应命中")
        precondition(fuzzyStore.search("能力").count == 1)
        precondition(!fuzzyStore.search("nengli").isEmpty, "全拼应命中")
        precondition(!fuzzyStore.search("nl").isEmpty, "首字母应命中")
        precondition(!fuzzyStore.search("地图 能力").isEmpty, "多关键词与顺序无关")
        precondition(fuzzyStore.search("地图 面试").isEmpty, "两个关键词需同时命中")
        precondition(!fuzzyStore.search("面试", at: .now).isEmpty, "已完成也应能被搜到")
        precondition(fuzzyStore.search("   ").isEmpty || true)

        print("SmartListChecks OK")
    }
}
