import AppKit
import SwiftUI

@MainActor
struct InboxDropContent {
    let title: String
    let notes: String
    let resources: [ReminderResource]

    private static let urlName = NSPasteboard.PasteboardType("public.url-name")
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    init?(pasteboard: NSPasteboard) {
        var resources: [ReminderResource] = []
        var seenURLs: Set<URL> = []
        var firstResourceTitle: String?
        var texts: [String] = []

        func addResource(_ string: String, title: String? = nil) -> Bool {
            guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let resource = ReminderResource(url: url, title: title) else { return false }
            if seenURLs.insert(resource.url).inserted {
                if resources.isEmpty {
                    firstResourceTitle = title.flatMap(Self.shortTitle) ?? resource.title
                }
                resources.append(resource)
            }
            return true
        }

        for item in pasteboard.pasteboardItems ?? [] {
            if let file = item.string(forType: .fileURL), addResource(file) { continue }
            if let link = item.string(forType: .URL), addResource(link, title: item.string(forType: Self.urlName)) {
                continue
            }
            if let text = item.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let isSingleLink = !text.contains(where: \.isWhitespace)
                    && (text.lowercased().hasPrefix("https://") || text.lowercased().hasPrefix("http://"))
                if !isSingleLink || !addResource(text) { texts.append(text) }
            }
        }

        let notes = texts.joined(separator: "\n\n")
        let firstLine = notes.split(whereSeparator: \.isNewline).first.map(String.init)
        guard let title = firstResourceTitle.flatMap(Self.shortTitle) ?? firstLine.flatMap(Self.shortTitle) else {
            return nil
        }
        self.title = title
        self.notes = notes
        self.resources = resources
    }

    private static func shortTitle(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        let result = String(words.joined(separator: " ").prefix(100))
        return result.isEmpty ? nil : result
    }
}

@MainActor
final class InboxDropFeedback: ObservableObject {
    enum State { case idle, targeting, captured }

    @Published private(set) var state: State = .idle
    private var clearTask: Task<Void, Never>?

    func show(_ state: State) {
        clearTask?.cancel()
        self.state = state
        if state == .captured {
            clearTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1.25)) } catch { return }
                self?.state = .idle
            }
        }
    }
}

struct InboxDropIndicator: View {
    @ObservedObject var feedback: InboxDropFeedback

    var body: some View {
        if feedback.state != .idle {
            ZStack(alignment: .bottom) {
                if feedback.state == .targeting {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 2)
                        .padding(3)
                }
                Label(feedback.state == .targeting ? "放入收件箱" : "已加入收件箱",
                      systemImage: feedback.state == .targeting ? "tray.and.arrow.down" : "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(feedback.state == .targeting)
        }
    }
}

@MainActor
final class InboxDropView: NSView {
    var onCapture: ((InboxDropContent) -> Bool)?
    var onFeedback: ((InboxDropFeedback.State) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(InboxDropContent.types)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = dragOperation(sender)
        onFeedback?(operation.isEmpty ? .idle : .targeting)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onFeedback?(.idle)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !dragOperation(sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let saved = InboxDropContent(pasteboard: sender.draggingPasteboard).map { onCapture?($0) == true } ?? false
        onFeedback?(saved ? .captured : .idle)
        return saved
    }

    private func dragOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: InboxDropContent.types) != nil else { return [] }
        for operation: NSDragOperation in [.copy, .link, .generic] where sender.draggingSourceOperationMask.contains(operation) {
            return operation
        }
        return []
    }
}
