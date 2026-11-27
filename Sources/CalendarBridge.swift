import EventKit
import Foundation

/// 把事项写入 Apple 日历（默认日历，1 小时事件，到点提醒）。
enum CalendarBridge {
    enum BridgeError: LocalizedError {
        case noAccess
        case noCalendar

        var errorDescription: String? {
            switch self {
            case .noAccess: "还没有日历权限。请在系统设置里允许浮光提醒访问日历。"
            case .noCalendar: "找不到可用的日历。"
            }
        }
    }

    @MainActor
    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    @MainActor
    static func createEvent(for item: ReminderItem) throws {
        let store = EKEventStore()
        guard let target = store.defaultCalendarForNewEvents else { throw BridgeError.noCalendar }

        let dayCalendar = Calendar.current
        let start = item.dueDate ?? Date.now.addingTimeInterval(3600)
        let end = dayCalendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3600)

        let event = EKEvent(eventStore: store)
        event.title = item.title
        event.startDate = start
        event.endDate = end
        event.calendar = target
        if !item.notes.isEmpty { event.notes = item.notes }
        event.addAlarm(EKAlarm(absoluteDate: start))

        try store.save(event, span: .thisEvent)
    }
}
