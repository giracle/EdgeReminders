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
    }
}
