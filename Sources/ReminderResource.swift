import Foundation

struct ReminderResource: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case web, file
    }

    let id: UUID
    let kind: Kind
    let title: String
    let url: URL
    let bookmark: Data?

    init?(url: URL, title: String? = nil) {
        let fallback: String
        if url.isFileURL, !url.path.isEmpty, url.path != "/", url.host == nil || url.host == "" || url.host == "localhost" {
            kind = .file
            self.url = url.standardizedFileURL
            bookmark = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            fallback = url.lastPathComponent
        } else if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty {
            kind = .web
            self.url = url
            bookmark = nil
            fallback = host
        } else {
            return nil
        }
        id = UUID()
        let label = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = label.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    func resolvedURL() -> URL? {
        guard kind == .file else { return url }
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
