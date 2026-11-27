import AppKit
import Foundation

/// 轮询系统剪贴板：复制文本 / 链接 / 文件时自动存入收件箱。
@MainActor
final class ClipboardCapture: ObservableObject {
    var onCaptured: ((String) -> Void)?

    private let store: TaskStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private var recent: [String] = []
    private static let recentLimit = 32

    init(store: TaskStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let content = InboxDropContent(pasteboard: pasteboard) else { return }
        let key = content.title + "\u{1}" + content.notes
            + "\u{1}" + content.resources.map(\.url.absoluteString).joined(separator: ",")
        guard !recent.contains(key) else { return }
        recent.append(key)
        if recent.count > Self.recentLimit { recent.removeFirst() }
        do {
            try store.capture(title: content.title, notes: content.notes, resources: content.resources)
            onCaptured?(content.title)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}
