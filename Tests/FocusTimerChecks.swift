import Foundation

private final class TestClock {
    var instant = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        instant = instant.addingTimeInterval(seconds)
    }
}

@MainActor
private final class TestNotifications: FocusTimerNotificationScheduling {
    var scheduled: [FocusTimerNotification] = []
    var permissionRequests: [Bool] = []
    var cancelled: [UUID] = []

    func schedule(_ notification: FocusTimerNotification, allowPermissionPrompt: Bool) {
        scheduled.append(notification)
        permissionRequests.append(allowPermissionPrompt)
    }

    func cancel(_ id: UUID) {
        cancelled.append(id)
    }
}

@main
@MainActor
enum FocusTimerChecks {
    static func main() {
        verifyPauseAndRestore()
        verifyExpirationAcrossRestart()
        verifyFocusCycle()
        verifyConfiguration()
        print("Focus timer checks passed")
    }

    private static func withTimer(
        _ body: (FocusTimer, UserDefaults, TestClock, TestNotifications) -> Void
    ) {
        let suite = "focus-timer-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock()
        let notifications = TestNotifications()
        body(clockModel(defaults, clock, notifications), defaults, clock, notifications)
    }

    private static func clockModel(
        _ defaults: UserDefaults,
        _ clock: TestClock,
        _ notifications: TestNotifications
    ) -> FocusTimer {
        FocusTimer(defaults: defaults, now: { clock.instant }, ticksAutomatically: false, notifications: notifications)
    }

    private static func verifyPauseAndRestore() {
        withTimer { timer, defaults, clock, notifications in
            precondition(timer.status == .idle && timer.phase == nil)
            precondition(timer.start(mode: .countdown, minutes: 1))
            precondition(timer.displayTime == "01:00" && timer.phase == .countdown)
            precondition(!timer.start(mode: .focus))
            let firstRequest = notifications.scheduled[0]
            precondition(firstRequest.identifier.hasPrefix(FocusTimer.notificationIdentifierPrefix))
            precondition(firstRequest.deadline == clock.instant.addingTimeInterval(60))
            precondition(notifications.permissionRequests == [true])

            clock.advance(10.25)
            timer.pause()
            precondition(timer.remainingSeconds == 50 && timer.status == .paused)
            precondition(notifications.cancelled == [firstRequest.id])
            precondition(!timer.start(mode: .countdown))
            clock.advance(400)

            let restored = clockModel(defaults, clock, notifications)
            precondition(restored.status == .paused && restored.displayTime == "00:50")
            precondition(notifications.scheduled == [firstRequest])
            restored.resume()
            let resumedRequest = notifications.scheduled[1]
            precondition(resumedRequest.id == firstRequest.id)
            precondition(resumedRequest.deadline == clock.instant.addingTimeInterval(49.75))
            clock.advance(49.74)
            restored.refresh()
            precondition(restored.status == .running && restored.displayTime == "00:01")
            clock.advance(0.02)
            restored.refresh()
            precondition(restored.status == .finished && restored.completionID == firstRequest.id)
            restored.refresh()
            precondition(notifications.scheduled.count == 2 && notifications.cancelled.count == 1)

            restored.startNext()
            let nextRequest = notifications.scheduled[2]
            precondition(restored.displayTime == "01:00" && nextRequest.id != firstRequest.id)
            restored.stop()
            precondition(restored.status == .idle && notifications.cancelled.last == nextRequest.id)
        }
    }

    private static func verifyExpirationAcrossRestart() {
        withTimer { timer, defaults, clock, notifications in
            let task = FocusTimer.TaskReference(id: "local-7", title: "Draft")
            precondition(timer.start(mode: .focus, minutes: 1, task: task))
            let firstRequest = notifications.scheduled[0]
            clock.advance(20)
            let reopened = clockModel(defaults, clock, notifications)
            precondition(reopened.displayTime == "00:40" && reopened.task == task)
            precondition(notifications.scheduled == [firstRequest, firstRequest])
            precondition(notifications.permissionRequests == [true, false])

            clock.advance(45)
            let overdue = clockModel(defaults, clock, notifications)
            precondition(overdue.status == .finished && overdue.nextPhase == .shortBreak)
            precondition(overdue.completionID == nil && overdue.completedFocusRounds == 1)
            overdue.refresh()
            precondition(notifications.scheduled.count == 2 && notifications.cancelled.isEmpty)

            let reopenedFinished = clockModel(defaults, clock, notifications)
            precondition(reopenedFinished.completedFocusRounds == 1 && reopenedFinished.completionID == nil)
        }
    }

    private static func verifyFocusCycle() {
        withTimer { timer, _, clock, notifications in
            let task = FocusTimer.TaskReference(id: "apple-7", title: "Prepare slides")
            precondition(timer.start(mode: .focus, minutes: 2, task: task))
            for round in 1...4 {
                timer.startNext()
                precondition(timer.status == .running && timer.phase == .focus && timer.task == task)
                clock.advance(121)
                timer.refresh()
                precondition(timer.status == .finished && timer.completedFocusRounds == round)
                precondition(timer.nextPhase == (round == 4 ? .longBreak : .shortBreak))
                clock.advance(60)
                timer.refresh()
                precondition(timer.status == .finished && timer.completedFocusRounds == round)
                timer.startNext()
                let minutes = round == 4 ? 15 : 5
                precondition(timer.remainingSeconds == minutes * 60)
                clock.advance(TimeInterval(minutes * 60))
                timer.refresh()
                precondition(timer.status == .finished && timer.nextPhase == .focus)
                timer.startNext()
                precondition(timer.displayTime == "02:00" && timer.task == task)
            }
            precondition(timer.completedFocusRounds == 0)
            precondition(Set(notifications.scheduled.map(\.id)).count == 9)
        }
    }

    private static func verifyConfiguration() {
        withTimer { timer, defaults, clock, notifications in
            var settings = timer.settings
            precondition(settings.focusMinutes == 25 && settings.countdownMinutes == 15 && !settings.soundEnabled)
            settings.countdownMinutes = 200
            settings.shortBreakMinutes = 0
            settings.soundEnabled = true
            settings.showInMenuBar = true
            timer.configure(settings)
            precondition(timer.settings.countdownMinutes == 180 && timer.settings.shortBreakMinutes == 1)
            precondition(timer.start(mode: .countdown))
            precondition(timer.displayTime == "180:00" && notifications.scheduled.last?.soundEnabled == true)
            settings.soundEnabled = false
            timer.configure(settings)
            precondition(notifications.scheduled.count == 2)
            precondition(notifications.scheduled[0].id == notifications.scheduled[1].id)
            precondition(notifications.scheduled[0].deadline == notifications.scheduled[1].deadline)
            precondition(notifications.scheduled.last?.soundEnabled == false)
            let restored = clockModel(defaults, clock, notifications)
            precondition(restored.settings == timer.settings)
        }
    }
}
