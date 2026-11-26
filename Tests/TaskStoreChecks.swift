import Foundation

@main
@MainActor
struct TaskStoreChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Reminders.json")
        let store = TaskStore(localURL: file, enablesNotifications: false)
        try store.createLocalList("  本机测试  ")
        let list = store.lists.first { $0.title == "本机测试" }!
        try store.renameLocalList(list, to: "重命名清单")

        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        var draft = ReminderDraft(listID: list.id)
        draft.title = "  定期复查  "
        draft.notes = "检查持久化"
        draft.dueDate = tomorrow
        draft.repeatRule = .weekly
        draft.priority = .high
        try store.save(draft)
        let initial = store.tasks.first { $0.listID == list.id }!
        precondition(initial.title == "定期复查" && initial.dueDate == tomorrow)

        try store.setCompleted(initial, true)
        let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: tomorrow)!
        precondition(store.tasks.contains { !$0.isCompleted && $0.dueDate == nextWeek })
        try store.setCompleted(initial, false)
        precondition(store.tasks.filter { $0.listID == list.id }.count == 1)
        precondition(store.tasks.contains { $0.id == initial.id && !$0.isCompleted })

        let reopened = TaskStore(localURL: file, enablesNotifications: false)
        precondition(reopened.lists.contains { $0.id == list.id && $0.title == "重命名清单" })
        let restored = reopened.tasks.first { $0.id == initial.id }!
        precondition(restored.priority == .high && restored.notes == "检查持久化")
        var edit = ReminderDraft(restored)
        edit.title = "复查完毕"
        try reopened.save(edit)
        let edited = reopened.tasks.first { $0.id == initial.id }!
        precondition(edited.title == "复查完毕")
        try reopened.delete(edited)
        try reopened.deleteLocalList(list)
        precondition(!reopened.tasks.contains { $0.listID == list.id })
        precondition(!reopened.lists.contains { $0.id == list.id })

        let corruptFile = directory.appending(path: "Corrupt.json")
        let invalidContents = Data("cannot decode".utf8)
        try invalidContents.write(to: corruptFile)
        let corrupt = TaskStore(localURL: corruptFile, enablesNotifications: false)
        precondition(corrupt.errorMessage != nil)
        do {
            try corrupt.createLocalList("不应覆盖数据")
            preconditionFailure("Malformed storage must remain intact")
        } catch {
            let preserved = try Data(contentsOf: corruptFile)
            precondition(preserved == invalidContents)
        }

        try checkLegacyUpgrade(in: directory)
        try checkSubtasksAndLocalPreferences(in: directory)
    }

    private static func checkLegacyUpgrade(in directory: URL) throws {
        let file = directory.appending(path: "Legacy.json")
        let legacyContents = """
            {
              "lists": [{"id": "local-inbox", "title": "收件箱", "source": "local", "isWritable": true}],
              "items": [{
                "id": "old-task", "listID": "local-inbox", "title": "旧事项", "notes": "",
                "hasTime": false, "alerts": false, "isCompleted": false, "priority": "none",
                "repeatRule": "never", "source": "local", "isWritable": true
              }]
            }
            """
        try Data(legacyContents.utf8).write(to: file)
        let store = TaskStore(localURL: file, enablesNotifications: false)
        let original = store.tasks.first { $0.id == "old-task" }!
        precondition(original.title == "旧事项" && original.subtasks.isEmpty && original.snoozedUntil == nil)
        precondition(store.templates.isEmpty && store.pinnedTaskIDs.isEmpty)
        var edit = ReminderDraft(original)
        edit.subtasks = [ReminderSubtask(title: "兼容旧数据")]
        try store.save(edit)
        let reopened = TaskStore(localURL: file, enablesNotifications: false)
        precondition(reopened.tasks.first { $0.id == "old-task" }?.subtasks == edit.subtasks)
    }

    private static func checkSubtasksAndLocalPreferences(in directory: URL) throws {
        let file = directory.appending(path: "Upgraded.json")
        let store = TaskStore(localURL: file, enablesNotifications: false)
        let list = store.lists.first { $0.source == .local }!
        let deadline = Calendar.current.startOfDay(for: .now.addingTimeInterval(172_800))
        var draft = ReminderDraft(listID: list.id)
        draft.title = "版本发布"
        draft.dueDate = deadline
        draft.repeatRule = .weekly
        draft.subtasks = [ReminderSubtask(title: " 运行测试 ", isCompleted: true), ReminderSubtask(title: "打包")]
        try store.save(draft)
        let parent = store.tasks.first { $0.title == draft.title }!
        precondition(parent.subtasks.map(\.title) == ["运行测试", "打包"])
        precondition(parent.subtasks.map(\.isCompleted) == [true, false])

        var edit = ReminderDraft(parent)
        try store.setSubtaskCompleted(parent, subtaskID: parent.subtasks[1].id, completed: true)
        edit.subtasks.swapAt(0, 1)
        try store.save(edit)
        let reordered = store.tasks.first { $0.id == parent.id }!
        precondition(reordered.subtasks.map(\.id) == [parent.subtasks[1].id, parent.subtasks[0].id])
        precondition(reordered.subtasks.allSatisfy(\.isCompleted))
        precondition(!reordered.isCompleted)

        let snooze = Date.now.addingTimeInterval(3_600)
        try store.snooze(reordered, until: snooze)
        let delayed = store.tasks.first { $0.id == parent.id }!
        precondition(delayed.dueDate == deadline && delayed.localNotificationDate == snooze)
        try store.setPinned(delayed, true)
        try store.createTemplate(name: " 发布模板 ", subtasks: delayed.subtasks)
        let template = store.templates.first!
        precondition(template.name == "发布模板" && template.subtaskTitles == ["打包", "运行测试"])
        let applied = template.newSubtasks()
        precondition(applied.map(\.title) == template.subtaskTitles && applied.allSatisfy { !$0.isCompleted })
        precondition(Set(applied.map(\.id)).isDisjoint(with: delayed.subtasks.map(\.id)))

        try store.setCompleted(delayed, true)
        let generated = store.tasks.first { $0.id != parent.id }!
        let completed = store.tasks.first { $0.id == parent.id }!
        precondition(completed.localNotificationDate == nil)
        precondition(generated.snoozedUntil == nil && generated.subtasks.allSatisfy { !$0.isCompleted })
        precondition(generated.subtasks.map(\.title) == delayed.subtasks.map(\.title))
        precondition(Set(generated.subtasks.map(\.id)).isDisjoint(with: delayed.subtasks.map(\.id)))
        try store.setCompleted(completed, false)
        precondition(store.tasks.count == 1 && store.tasks.first?.subtasks.allSatisfy(\.isCompleted) == true)

        try store.setCompleted(parent, true)
        let editedNext = store.tasks.first { $0.id != parent.id }!
        try store.setSubtaskCompleted(editedNext, subtaskID: editedNext.subtasks[0].id, completed: true)
        try store.setCompleted(parent, false)
        precondition(store.tasks.contains { $0.id == editedNext.id && $0.subtasks[0].isCompleted })
        try store.setCompleted(parent, true)
        precondition(store.tasks.count == 2)
        try store.setCompleted(parent, false)

        let reopened = TaskStore(localURL: file, enablesNotifications: false)
        let restored = reopened.tasks.first { $0.id == parent.id }!
        precondition(restored.snoozedUntil == snooze && restored.dueDate == deadline)
        precondition(reopened.pinnedTaskIDs == [parent.id] && reopened.templates == [template])
        try reopened.snooze(restored, until: nil)
        precondition(reopened.tasks.first { $0.id == parent.id }?.localNotificationDate == nil)
        try reopened.deleteTemplate(template)
        try reopened.deleteLocalList(list)
        precondition(reopened.tasks.isEmpty && reopened.pinnedTaskIDs.isEmpty && reopened.templates.isEmpty)
    }
}
