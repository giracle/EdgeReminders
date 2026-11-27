import Combine
import Foundation
import UserNotifications

@MainActor
final class FocusTimer: ObservableObject {
    nonisolated static let notificationIdentifierPrefix = "focus-timer."

    enum Mode: String, CaseIterable, Identifiable {
        case focus, countdown

        var id: Self { self }
        var title: String { self == .focus ? "专注计时" : "普通倒计时" }
    }

    enum Phase: String, Codable {
        case focus, shortBreak, longBreak, countdown

        var title: String {
            switch self {
            case .focus: "专注计时"
            case .shortBreak: "短休息"
            case .longBreak: "长休息"
            case .countdown: "普通倒计时"
            }
        }
    }

    enum Status: String, Codable {
        case idle, running, paused, finished
    }

    struct Settings: Codable, Equatable {
        static let allowedMinutes = 1...180

        var focusMinutes = 25
        var shortBreakMinutes = 5
        var longBreakMinutes = 15
        var countdownMinutes = 15
        var soundEnabled = false
        var showInMenuBar = false

        func minutes(for phase: Phase) -> Int {
            switch phase {
            case .focus: focusMinutes
            case .shortBreak: shortBreakMinutes
            case .longBreak: longBreakMinutes
            case .countdown: countdownMinutes
            }
        }

        fileprivate mutating func clampDurations() {
            focusMinutes = Self.clamp(focusMinutes)
            shortBreakMinutes = Self.clamp(shortBreakMinutes)
            longBreakMinutes = Self.clamp(longBreakMinutes)
            countdownMinutes = Self.clamp(countdownMinutes)
        }

        fileprivate static func clamp(_ minutes: Int) -> Int {
            min(max(minutes, allowedMinutes.lowerBound), allowedMinutes.upperBound)
        }
    }

    struct TaskReference: Codable, Equatable {
        let id: String
        let title: String
    }

    struct SessionLog: Codable {
        let date: Date
        let phase: Phase
        let seconds: Int
        let task: TaskReference?
    }

    struct FocusStats: Equatable {
        var weekSeconds = 0
        var weekRounds = 0
        var totalSeconds = 0
        var activeDays = 0
    }

    private struct Session: Codable, Equatable {
        var id = UUID()
        let phase: Phase
        let initialMinutes: Int
        let task: TaskReference?
        var deadline: Date?
        var pausedSeconds: TimeInterval?
        var status: Status {
            if deadline != nil { return .running }
            if pausedSeconds != nil { return .paused }
            return .finished
        }
    }

    private struct SavedState: Codable {
        var settings = Settings()
        var session: Session?
        var completedFocusRounds = 0
        var logs: [SessionLog] = []
    }

    @Published private var saved: SavedState
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var completionID: UUID?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let ticksAutomatically: Bool
    private let notifications: FocusTimerNotificationScheduling
    private var ticker: Timer?
    private static let storageKey = "focusTimer.state.v1"

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        ticksAutomatically: Bool = true,
        notifications: FocusTimerNotificationScheduling? = nil
    ) {
        self.defaults = defaults
        self.now = now
        self.ticksAutomatically = ticksAutomatically
        self.notifications = notifications ?? SystemFocusTimerNotifications()
        if let data = defaults.data(forKey: Self.storageKey),
           var restored = try? JSONDecoder().decode(SavedState.self, from: data) {
            restored.settings.clampDurations()
            restored.completedFocusRounds = min(max(restored.completedFocusRounds, 0), 4)
            saved = restored
        } else {
            saved = SavedState()
        }
        refresh(emitCompletion: false)
        updateTicker()
        scheduleNotification()
    }

    var status: Status { saved.session?.status ?? .idle }
    var phase: Phase? { saved.session?.phase }
    var settings: Settings { saved.settings }
    var task: TaskReference? { saved.session?.task }
    var completedFocusRounds: Int { saved.completedFocusRounds }

    var nextPhase: Phase? {
        guard status == .finished else { return nil }
        switch phase {
        case .focus: return completedFocusRounds == 4 ? .longBreak : .shortBreak
        case .shortBreak, .longBreak: return .focus
        case .countdown, nil: return nil
        }
    }

    var displayTime: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    func configure(_ settings: Settings) {
        var settings = settings
        settings.clampDurations()
        guard settings != saved.settings else { return }
        let soundChanged = settings.soundEnabled != saved.settings.soundEnabled
        saved.settings = settings
        persist()
        if soundChanged { scheduleNotification() }
    }

    @discardableResult
    func start(mode: Mode, minutes: Int? = nil, task: TaskReference? = nil) -> Bool {
        refresh()
        guard status == .idle || status == .finished else { return false }
        let phase: Phase = mode == .focus ? .focus : .countdown
        let initialMinutes = Settings.clamp(minutes ?? settings.minutes(for: phase))
        start(phase: phase, initialMinutes: initialMinutes, task: mode == .focus ? task : nil)
        return true
    }

    func pause() {
        refresh()
        guard var session = saved.session, let deadline = session.deadline else { return }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { refresh(); return }
        session.deadline = nil
        session.pausedSeconds = remaining
        saved.session = session
        notifications.cancel(session.id)
        persist()
        updateTicker()
    }

    func resume() {
        guard var session = saved.session, let remaining = session.pausedSeconds else { return }
        session.deadline = now().addingTimeInterval(remaining)
        session.pausedSeconds = nil
        saved.session = session
        persist()
        updateTicker()
        scheduleNotification(allowPermissionPrompt: true)
    }

    func stop() {
        refresh()
        guard let session = saved.session else { return }
        if session.status == .running || session.status == .paused {
            notifications.cancel(session.id)
        }
        if session.phase == .focus, session.status != .finished {
            let remaining = session.deadline?.timeIntervalSince(now()) ?? session.pausedSeconds ?? 0
            let elapsed = session.initialMinutes * 60 - Int(max(0, remaining))
            if elapsed >= 60 {
                appendLog(to: &saved, phase: .focus, seconds: elapsed, task: session.task)
            }
        }
        saved.session = nil
        remainingSeconds = 0
        persist()
        updateTicker()
    }

    func startNext() {
        guard let session = saved.session, session.status == .finished else { return }
        let phase = nextPhase ?? session.phase
        start(phase: phase, initialMinutes: session.initialMinutes, task: session.task)
    }

    func refresh() {
        refresh(emitCompletion: true)
    }

    private func start(phase: Phase, initialMinutes: Int, task: TaskReference?) {
        let duration = phase == .shortBreak || phase == .longBreak ? settings.minutes(for: phase) : initialMinutes
        let deadline = now().addingTimeInterval(TimeInterval(duration * 60))
        saved.session = Session(phase: phase, initialMinutes: initialMinutes, task: task, deadline: deadline)
        persist()
        refresh()
        updateTicker()
        scheduleNotification(allowPermissionPrompt: true)
    }

    private func refresh(emitCompletion: Bool) {
        guard var session = saved.session else { return }
        let remaining = session.deadline?.timeIntervalSince(now()) ?? session.pausedSeconds ?? 0
        // Bound the time display if the system clock was moved back.
        let seconds = Int(ceil(min(max(remaining, 0), TimeInterval(Settings.allowedMinutes.upperBound * 60))))
        if remainingSeconds != seconds { remainingSeconds = seconds }
        guard session.deadline != nil && remaining <= 0 else { return }

        session.deadline = nil
        var finished = saved
        finished.session = session
        if session.phase == .focus {
            finished.completedFocusRounds = min(4, finished.completedFocusRounds + 1)
            appendLog(to: &finished, phase: .focus, seconds: session.initialMinutes * 60, task: session.task)
        } else if session.phase == .longBreak {
            finished.completedFocusRounds = 0
        }
        saved = finished
        persist()
        updateTicker()
        if emitCompletion { completionID = session.id }
    }

    /// 专注统计：近 7 天的专注时长与轮数、累计时长、活跃天数。
    func focusStats(now: Date = .now, calendar: Calendar = .current) -> FocusStats {
        Self.stats(from: saved.logs, now: now, calendar: calendar)
    }

    /// 不创建计时器实例、直接读持久化数据的统计（供管理窗口使用）。
    static func storedFocusStats(defaults: UserDefaults = .standard, now: Date = .now,
                                 calendar: Calendar = .current) -> FocusStats {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return FocusStats() }
        return stats(from: saved.logs, now: now, calendar: calendar)
    }

    private static func stats(from logs: [SessionLog], now: Date, calendar: Calendar) -> FocusStats {
        var stats = FocusStats()
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        var days = Set<TimeInterval>()
        for log in logs where log.phase == .focus {
            stats.totalSeconds += log.seconds
            if log.date >= weekStart {
                stats.weekSeconds += log.seconds
                stats.weekRounds += 1
                days.insert(calendar.startOfDay(for: log.date).timeIntervalSince1970)
            }
        }
        stats.activeDays = days.count
        return stats
    }

    private func appendLog(to state: inout SavedState, phase: Phase, seconds: Int, task: TaskReference?) {
        guard seconds >= 30 else { return }
        state.logs.append(SessionLog(date: now(), phase: phase, seconds: seconds, task: task))
        if state.logs.count > 400 { state.logs.removeFirst(state.logs.count - 400) }
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(saved) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }

    private func updateTicker() {
        guard status == .running && ticksAutomatically else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let ticker = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refresh()
            }
        }
        ticker.tolerance = 0.03
        self.ticker = ticker
        RunLoop.main.add(ticker, forMode: .common)
    }

    private func scheduleNotification(allowPermissionPrompt: Bool = false) {
        guard let session = saved.session, let deadline = session.deadline else { return }
        notifications.schedule(
            FocusTimerNotification(id: session.id, phase: session.phase, deadline: deadline, soundEnabled: settings.soundEnabled),
            allowPermissionPrompt: allowPermissionPrompt
        )
    }
}

struct FocusTimerNotification: Equatable {
    let id: UUID
    let phase: FocusTimer.Phase
    let deadline: Date
    let soundEnabled: Bool

    var identifier: String { FocusTimer.notificationIdentifierPrefix + id.uuidString }
}

@MainActor
protocol FocusTimerNotificationScheduling {
    func schedule(_ notification: FocusTimerNotification, allowPermissionPrompt: Bool)
    func cancel(_ id: UUID)
}

@MainActor
private final class SystemFocusTimerNotifications: FocusTimerNotificationScheduling {
    private let center = UNUserNotificationCenter.current()
    private var revision = 0
    private var pendingUpdate: Task<Void, Never>?

    func schedule(_ notification: FocusTimerNotification, allowPermissionPrompt: Bool) {
        revision += 1
        let revision = revision
        let previousUpdate = pendingUpdate
        pendingUpdate = Task { [weak self] in
            await previousUpdate?.value
            guard let self, revision == self.revision else { return }

            var authorization = await self.center.notificationSettings().authorizationStatus
            guard revision == self.revision else { return }
            if authorization == .notDetermined && allowPermissionPrompt {
                _ = try? await self.center.requestAuthorization(options: [.alert, .sound])
                authorization = await self.center.notificationSettings().authorizationStatus
            }
            guard revision == self.revision,
                  authorization == .authorized || authorization == .provisional,
                  notification.deadline > Date.now else { return }

            let existing = await self.center.pendingNotificationRequests().first { $0.identifier == notification.identifier }
            guard revision == self.revision, notification.deadline > Date.now else { return }
            let deadlineKey = notification.deadline.timeIntervalSince1970
            if let existing,
               existing.content.userInfo["focusTimerDeadline"] as? Double == deadlineKey,
               (existing.content.sound != nil) == notification.soundEnabled {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = notification.phase.title + "结束"
            content.body = notification.phase == .focus ? "可以开始休息了。" : ""
            content.sound = notification.soundEnabled ? .default : nil
            content.userInfo = ["focusTimerDeadline": deadlineKey]

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let roundedDeadline = Date(timeIntervalSince1970: ceil(deadlineKey))
            let components = calendar.dateComponents(
                [.timeZone, .year, .month, .day, .hour, .minute, .second],
                from: roundedDeadline
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await self.center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
        }
    }

    func cancel(_ id: UUID) {
        revision += 1
        let identifier = FocusTimer.notificationIdentifierPrefix + id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        // A previous add may still be completing in the system notification service.
        let previousUpdate = pendingUpdate
        pendingUpdate = Task { [weak self] in
            await previousUpdate?.value
            self?.center.removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    }
}
