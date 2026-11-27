import Foundation

struct TaskStats {
    struct DayCount: Identifiable {
        let day: Date
        let count: Int
        var id: Date { day }
    }

    let dailyCompletions: [DayCount]
    let openTotal: Int
    let completedTotal: Int
    let overdue: Int
    let byList: [(title: String, count: Int)]
    let byTag: [(tag: String, count: Int)]
    let byPriority: [(label: String, count: Int)]
    let streak: Int

    init(tasks: [ReminderItem], lists: [ReminderList], now: Date = .now, calendar: Calendar = .current) {
        let open = tasks.filter { !$0.isCompleted }
        let completed = tasks.filter(\.isCompleted)
        openTotal = open.count
        completedTotal = completed.count

        var overdueCount = 0
        for item in open {
            if let due = item.dueDate, due < (item.hasTime ? now : calendar.startOfDay(for: now)) {
                overdueCount += 1
            }
        }
        overdue = overdueCount

        let days: [Date] = (0..<14).compactMap { offset in
            calendar.date(byAdding: .day, value: offset - 13, to: calendar.startOfDay(for: now))
        }
        let completedByDay: [Date: Int] = Dictionary(grouping: completed.compactMap(\.completionDate)) {
            calendar.startOfDay(for: $0)
        }.mapValues(\.count)
        dailyCompletions = days.map { DayCount(day: $0, count: completedByDay[$0] ?? 0) }

        var streakCount = 0
        var cursor = calendar.startOfDay(for: now)
        if (completedByDay[cursor] ?? 0) == 0 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while (completedByDay[cursor] ?? 0) > 0 {
            streakCount += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        streak = streakCount

        let openByList = Dictionary(grouping: open) { item in
            lists.first { $0.id == item.listID }?.title ?? item.source.label
        }
        byList = openByList
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { (title: $0.key, count: $0.value.count) }

        let openByTag = Dictionary(grouping: open.flatMap(\.tags), by: { $0 })
        byTag = openByTag
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (tag: $0.key, count: $0.value.count) }

        let openByPriority = Dictionary(grouping: open.filter { $0.priority != .none }, by: \.priority)
        byPriority = openByPriority
            .sorted { $0.key.rawValue > $1.key.rawValue }
            .map { (label: $0.key.label, count: $0.value.count) }
    }
}
