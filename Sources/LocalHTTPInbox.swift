import Foundation
import Network

/// 在 127.0.0.1:8742 上收 POST /inbox 请求，把内容写进收件箱。
/// 只绑定回环地址；用 X-Fuguang-Token 头校验。
@MainActor
final class LocalHTTPInbox: ObservableObject {
    static let port: UInt16 = 8742

    @Published private(set) var isRunning = false

    private let store: TaskStore
    private let token: String
    private var listener: NWListener?

    init(store: TaskStore) {
        self.store = store
        let chars = Array("0123456789abcdef")
        if let stored = UserDefaults.standard.string(forKey: "httpInbox.token"), !stored.isEmpty {
            self.token = stored
        } else {
            self.token = String((0..<24).map { _ in chars[Int.random(in: 0..<16)] })
            UserDefaults.standard.set(self.token, forKey: "httpInbox.token")
        }
    }

    var tokenValue: String { token }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: Self.port) ?? .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.isRunning = (state == .ready)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handle(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private final class ConnectionBuffer: @unchecked Sendable {
        var data = Data()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveLoop(connection, buffer: ConnectionBuffer())
    }

    private func receiveLoop(_ connection: NWConnection, buffer: ConnectionBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let connection else { return }
                if let data { buffer.data.append(data) }
                let raw = String(data: buffer.data, encoding: .utf8) ?? ""
                if let headerEnd = raw.range(of: "\r\n\r\n") {
                    let head = String(raw[raw.startIndex..<headerEnd.upperBound])
                    let contentLength = Int(Self.headerValue("content-length", in: head) ?? "0") ?? 0
                    let body = raw[headerEnd.upperBound...]
                    let bodyAvailable = Data(body.utf8).count
                    if bodyAvailable >= contentLength {
                        self.respond(connection, head: head, body: body.prefix(contentLength))
                        buffer.data = Data()
                        return
                    }
                }
                if isComplete || error != nil {
                    buffer.data = Data()
                    connection.cancel()
                } else {
                    self.receiveLoop(connection, buffer: buffer)
                }
            }
        }
    }

    private static func headerValue(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == name.lowercased() {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func respond(_ connection: NWConnection, head: String, body: Substring) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel(); return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let path = String(parts[1])

        if method == "GET", path == "/health" {
            send(connection, status: "200 OK", payload: #"{"ok":true,"app":"fuguang-reminders"}"#)
        } else if method == "POST", path == "/inbox" {
            guard Self.headerValue("x-fuguang-token", in: head) == token else {
                send(connection, status: "401 Unauthorized", payload: #"{"error":"bad token"}"#)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
                send(connection, status: "400 Bad Request", payload: #"{"error":"invalid json"}"#)
                return
            }
            let title = (json["title"] as? String) ?? ""
            let notes = (json["notes"] as? String) ?? ""
            let urls = (json["resources"] as? [String]) ?? []
            let resources: [ReminderResource] = urls.compactMap { URL(string: $0) }
                .compactMap { ReminderResource(url: $0) }
            do {
                try store.capture(title: title, notes: notes, resources: resources)
                send(connection, status: "201 Created", payload: #"{"ok":true}"#)
            } catch {
                send(connection, status: "400 Bad Request", payload: #"{"error":"capture failed"}"#)
            }
        } else {
            send(connection, status: "404 Not Found", payload: #"{"error":"not found"}"#)
        }
    }

    private func send(_ connection: NWConnection, status: String, payload: String) {
        let data = Data(payload.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n\(payload)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
