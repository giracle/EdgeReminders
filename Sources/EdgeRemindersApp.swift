import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
@MainActor
enum EdgeRemindersApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = TaskStore.shared
    private let focusTimer = FocusTimer()
    private let timerCompletionBorder = TimerCompletionBorder()
    private var timerPanel: FocusTimerPanelController?
    private var timerMenuObservation: AnyCancellable?
    private var timerCompletionObservation: AnyCancellable?
    private var floating: FloatingPanelController?
    private var globalQuickAdd: GlobalQuickAdd?
    private var clipboardCapture: ClipboardCapture?
    private var httpInbox: LocalHTTPInbox?
    private var cancellables = Set<AnyCancellable>()
    private var manager: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shortcut = GlobalQuickAdd { [weak self] in self?.openQuickAdd() }
        let shortcutAvailable = shortcut.register()
        globalQuickAdd = shortcut
        installMenus(shortcutAvailable: shortcutAvailable)
        UNUserNotificationCenter.current().delegate = self
        timerPanel = FocusTimerPanelController(timer: focusTimer)
        floating = FloatingPanelController(
            store: store,
            onOpenManager: { [weak self] in self?.showManager() },
            onOpenTimer: { [weak self] in self?.showTimer() },
            onQuit: { NSApp.terminate(nil) },
            onFocusTask: { [weak self] in self?.focus(on: $0) },
            onStartTaskTimer: { [weak self] in self?.startTimer(for: $0) },
            onContinueTask: { [weak self] in self?.continueTask($0, startTimer: $1) },
            onCapture: { [weak self] title, notes, resources in
                self?.capture(title: title, notes: notes, resources: resources) ?? false
            }
        )
        timerMenuObservation = focusTimer.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.updateStatusTimer() }
        }
        timerCompletionObservation = focusTimer.$completionID.compactMap { $0 }.sink { [weak self] _ in
            self?.previewTimerCompletion()
        }
        updateStatusTimer()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshTimer),
                                                           name: NSWorkspace.didWakeNotification, object: nil)
        installClipboardCapture()
        installHTTPInbox()
        installExternalReloadObserver()
        if AppPreferences.shared.autoCheckUpdates { checkForUpdates(automatic: true) }
        floating?.show()
        timerPanel?.restoreIfNeeded()
    }

    private func installHTTPInbox() {
        let inbox = LocalHTTPInbox(store: store)
        inbox.start()
        httpInbox = inbox
    }

    private func installExternalReloadObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(reloadLocalData),
            name: Notification.Name("EdgeReminders.reload"),
            object: nil
        )
    }

    @objc private func reloadLocalData() {
        store.reloadLocal()
    }

    @objc private func checkForUpdates(automatic: Bool = false) {
        Task {
            let result = await UpdateChecker.checkCurrent()
            switch result {
            case .success(let update):
                guard let update else {
                    if !automatic { store.errorMessage = "已经是最新版本。" }
                    return
                }
                let alert = NSAlert()
                alert.messageText = "发现新版本 \(update.version)"
                alert.informativeText = "前往 GitHub Release 下载。"
                alert.addButton(withTitle: "打开")
                alert.addButton(withTitle: "稍后")
                let url = URL(string: update.htmlURL)
                if let host = manager ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: host) { response in
                        if response == .alertFirstButtonReturn, let url { NSWorkspace.shared.open(url) }
                    }
                } else {
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn, let url { NSWorkspace.shared.open(url) }
                }
            case .failure(let error):
                if !automatic { store.errorMessage = "检查更新失败：\(error.localizedDescription)" }
            }
        }
    }

    private func installClipboardCapture() {
        let capture = ClipboardCapture(store: store)
        capture.onCaptured = { [weak self] title in self?.showCapturedNotification(title) }
        clipboardCapture = capture
        if AppPreferences.shared.clipboardAutoCapture { capture.start() }
        AppPreferences.shared.$clipboardAutoCapture
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak capture] enabled in
                if enabled { capture?.start() } else { capture?.stop() }
            }
            .store(in: &cancellables)
    }

    private func showCapturedNotification(_ title: String) {
        let content = UNMutableNotificationContent()
        content.title = "已剪藏到收件箱"
        content.body = String(title.prefix(60))
        let request = UNNotificationRequest(
            identifier: "clipboard-capture.\(Date.now.timeIntervalSince1970)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timerCompletionBorder.stop()
        globalQuickAdd?.unregister()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floating?.show()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        if identifier.hasPrefix(FocusTimer.notificationIdentifierPrefix),
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { showTimer() }
        }
    }

    @objc private func showPanel() { floating?.show() }
    @objc private func hidePanel() { floating?.hide() }
    @objc private func openQuickAdd() { floating?.openQuickAdd() }
    @objc private func showTimer() { timerPanel?.show() }
    @objc private func refreshTimer() { focusTimer.refresh() }

    @objc private func previewTimerCompletion() {
        guard let screen = timerPanel?.completionScreen ?? NSScreen.main else { return }
        timerCompletionBorder.play(on: screen)
    }

    private func focus(on item: ReminderItem) {
        timerPanel?.show(task: .init(id: item.id, title: item.title))
    }

    private func startTimer(for item: ReminderItem) {
        guard let current = store.tasks.first(where: { $0.id == item.id && $0.source == item.source }),
              !current.isCompleted else { return }
        if focusTimer.start(mode: .focus, task: .init(id: current.id, title: current.title)) {
            timerPanel?.showClock()
        } else {
            timerPanel?.show()
        }
    }

    private func continueTask(_ item: ReminderItem, startTimer: Bool) {
        let resources = store.resources(for: item)
        guard !resources.isEmpty else { return }
        var opened = false
        var failures = [String]()
        for resource in resources {
            if let url = resource.resolvedURL(), NSWorkspace.shared.open(url) {
                opened = true
            } else {
                failures.append(resource.title)
            }
        }
        if !failures.isEmpty {
            let names = failures.prefix(3).joined(separator: "、")
            let suffix = failures.count > 3 ? "等 \(failures.count) 项" : ""
            store.errorMessage = "无法打开资料。\(names)\(suffix)"
        }
        if startTimer, opened { self.startTimer(for: item) }
    }

    private func capture(title: String, notes: String, resources: [ReminderResource]) -> Bool {
        do {
            try store.capture(title: title, notes: notes, resources: resources)
            return true
        } catch {
            store.errorMessage = error.localizedDescription
            return false
        }
    }

    private func updateStatusTimer() {
        guard let statusItem, let button = statusItem.button else { return }
        let showTime = focusTimer.settings.showInMenuBar && focusTimer.status != .idle
        let hasIcon = button.image != nil
        statusItem.length = showTime || !hasIcon ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.imagePosition = hasIcon ? (showTime ? .imageLeading : .imageOnly) : .noImage
        button.title = showTime ? focusTimer.displayTime : (hasIcon ? "" : "浮光")
        button.toolTip = showTime ? "浮光提醒 · \(focusTimer.displayTime)" : "浮光提醒"
    }

    @objc private func showManager() {
        if manager == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "浮光提醒"
            window.contentMinSize = NSSize(width: 600, height: 420)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TaskManagerView(
                store: store,
                onFocusTask: { [weak self] in self?.focus(on: $0) },
                onStartTaskTimer: { [weak self] in self?.startTimer(for: $0) },
                onContinueTask: { [weak self] in self?.continueTask($0, startTimer: $1) }
            ))
            window.center()
            manager = window
        }
        NSApp.activate()
        manager?.makeKeyAndOrderFront(nil)
    }

    private func installMenus(shortcutAvailable: Bool) {
        let barItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        barItem.autosaveName = "EdgeReminders"
        barItem.isVisible = true
        if let button = barItem.button {
            let icon = NSImage(systemSymbolName: "checklist", accessibilityDescription: "浮光提醒")
                ?? NSImage(named: NSImage.actionTemplateName)
            icon?.isTemplate = true
            button.image = icon
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("浮光提醒")
        }
        let barMenu = NSMenu()
        barMenu.addItem(menuItem("显示浮窗", #selector(showPanel)))
        barMenu.addItem(menuItem("收起浮窗", #selector(hidePanel)))
        let add = menuItem("快速新增…", #selector(openQuickAdd), key: shortcutAvailable ? GlobalQuickAdd.keyEquivalent : "")
        add.keyEquivalentModifierMask = [.control, .shift]
        if !shortcutAvailable { add.toolTip = "全局快捷键当前不可用" }
        barMenu.addItem(add)
        barMenu.addItem(menuItem("计时…", #selector(showTimer)))
        barMenu.addItem(menuItem("预览到点彩虹", #selector(previewTimerCompletion)))
        barMenu.addItem(.separator())
        barMenu.addItem(menuItem("管理清单…", #selector(showManager), key: "m"))
        barMenu.addItem(menuItem("检查更新…", #selector(checkForUpdates)))
        barMenu.addItem(.separator())
        barMenu.addItem(withTitle: "退出浮光提醒", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        barItem.menu = barMenu
        statusItem = barItem

        let mainMenu = NSMenu()
        let applicationMenu = NSMenuItem()
        applicationMenu.submenu = NSMenu(title: "浮光提醒")
        applicationMenu.submenu?.addItem(menuItem("计时…", #selector(showTimer)))
        applicationMenu.submenu?.addItem(menuItem("预览到点彩虹", #selector(previewTimerCompletion)))
        applicationMenu.submenu?.addItem(menuItem("管理清单…", #selector(showManager), key: "m"))
        applicationMenu.submenu?.addItem(withTitle: "退出浮光提醒", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(applicationMenu)

        let editMenu = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.submenu = edit
        mainMenu.addItem(editMenu)
        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
