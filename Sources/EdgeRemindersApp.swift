import AppKit
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
    private let store = TaskStore()
    private var floating: FloatingPanelController?
    private var manager: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        UNUserNotificationCenter.current().delegate = self
        floating = FloatingPanelController(store: store) { [weak self] in
            self?.showManager()
        }
        floating?.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floating?.show()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    @objc private func showPanel() { floating?.show() }
    @objc private func hidePanel() { floating?.hide() }

    @objc private func showManager() {
        if manager == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "浮光提醒"
            window.contentMinSize = NSSize(width: 600, height: 420)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TaskManagerView(store: store))
            window.center()
            manager = window
        }
        NSApp.activate()
        manager?.makeKeyAndOrderFront(nil)
    }

    private func installMenus() {
        let barItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "checklist", accessibilityDescription: "浮光提醒")
        icon?.isTemplate = true
        barItem.button?.image = icon
        barItem.button?.toolTip = "浮光提醒"
        let barMenu = NSMenu()
        barMenu.addItem(menuItem("显示浮窗", #selector(showPanel)))
        barMenu.addItem(menuItem("收起浮窗", #selector(hidePanel)))
        barMenu.addItem(.separator())
        barMenu.addItem(menuItem("管理清单…", #selector(showManager), key: "m"))
        barMenu.addItem(.separator())
        barMenu.addItem(withTitle: "退出浮光提醒", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        barItem.menu = barMenu
        statusItem = barItem

        let mainMenu = NSMenu()
        let applicationMenu = NSMenuItem()
        applicationMenu.submenu = NSMenu(title: "浮光提醒")
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
