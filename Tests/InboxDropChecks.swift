import AppKit

@MainActor
private final class Drop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@main
@MainActor
enum InboxDropChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localURL = directory.appending(path: "Reminders.json")
        let localFile = directory.appending(path: "Example.txt")
        try Data("example".utf8).write(to: localFile)

        let store = TaskStore(localURL: localURL, enablesNotifications: false)
        let dropView = InboxDropView(frame: NSRect(x: 0, y: 0, width: 380, height: 390))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var feedback = InboxDropFeedback.State.idle
        dropView.onFeedback = { feedback = $0 }
        dropView.onCapture = { payload in
            do {
                try store.capture(title: payload.title, notes: payload.notes, resources: payload.resources)
                return true
            } catch {
                preconditionFailure(error.localizedDescription)
            }
        }

        func deliver(_ values: [NSPasteboard.PasteboardType: String]) {
            let item = NSPasteboardItem()
            for (type, value) in values { item.setString(value, forType: type) }
            pasteboard.clearContents()
            precondition(pasteboard.writeObjects([item]))
            let drop = Drop(pasteboard)
            precondition(dropView.draggingEntered(drop) == .copy && feedback == .targeting)
            precondition(dropView.prepareForDragOperation(drop))
            precondition(dropView.performDragOperation(drop) && feedback == .captured)
        }

        deliver([.URL: "https://example.com/article", .init("public.url-name"): "Article"])
        deliver([.fileURL: localFile.absoluteString])
        deliver([.string: "Selected text\nSecond line"])

        let tasks = TaskStore(localURL: localURL, enablesNotifications: false).tasks
        precondition(tasks.count == 3 && tasks.allSatisfy { $0.listID == "local-inbox" })
        precondition(tasks.first { $0.title == "Article" }?.resources.first?.url.absoluteString == "https://example.com/article")
        let resolvedFile = tasks.first { $0.title == "Example.txt" }?.resources.first?.resolvedURL()
        precondition(resolvedFile?.resolvingSymlinksInPath().path == localFile.resolvingSymlinksInPath().path)
        precondition(tasks.first { $0.title == "Selected text" }?.notes == "Selected text\nSecond line")
        print("AppKit drop destination and inbox persistence checks passed")
    }
}
