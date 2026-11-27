import AppIntents
import Foundation

struct AddReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "新增事项"
    static var subtitle: LocalizedStringResource = "浮光提醒"
    static var description = IntentDescription("把一句话记进浮光提醒的收件箱，支持「明天上午十点交周报」这类自然日期。")
    static var openAppWhenRun = false

    @Parameter(title: "内容", description: "事项内容，支持日期和时间。", default: "")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TaskStore.shared
        do {
            try store.quickAdd(text)
            return .result(dialog: "已记入浮光收件箱。")
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }
    }
}

struct ListTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "查看今天事项"
    static var subtitle: LocalizedStringResource = "浮光提醒"
    static var description = IntentDescription("列出浮光提醒中今天到期的事项。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TaskStore.shared
        let calendar = Calendar.current
        let today = store.tasks
            .filter { item in
                !item.isCompleted && (item.dueDate.map { calendar.isDate($0, inSameDayAs: .now) } ?? true)
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        guard !today.isEmpty else { return .result(dialog: "今天没有到期事项。") }
        let style = Date.FormatStyle.dateTime.hour().minute()
        let lines = today.map { item in
            let time = item.dueDate.map { $0.formatted(style) } ?? "未设时间"
            return "· \(item.title)（\(time)）"
        }
        return .result(dialog: IntentDialog(stringLiteral: "今天还有 \(today.count) 项：\n" + lines.joined(separator: "\n")))
    }
}

struct FuguangShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddReminderIntent(text: IntentParameter(default: "明天上午十点交周报")),
            phrases: [
                "把【%1@】记到${applicationName}",
                "${applicationName}新增【%1@】",
                "用${applicationName}记一条待办【%1@】"
            ],
            shortTitle: "新增事项",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: ListTodayIntent(),
            phrases: [
                "${applicationName}今天有什么",
                "${applicationName}今天还有什么事"
            ],
            shortTitle: "今天事项",
            systemImageName: "calendar"
        )
    }
}
