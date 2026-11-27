import Combine
import Foundation
import Security

/// 极简 Keychain 存取（仅字符串）。
enum Keychain {
    private static let service = "local.fuguang.EdgeReminders"

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// OpenAI 兼容接口：拆子任务、生成周报。
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    @Published var endpoint: String {
        didSet { defaults.set(endpoint, forKey: Keys.endpoint) }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    @Published var hasKey: Bool

    private let defaults: UserDefaults
    private enum Keys {
        static let endpoint = "ai.endpoint"
        static let model = "ai.model"
        static let key = "ai.apiKey"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.endpoint = defaults.string(forKey: Keys.endpoint) ?? "https://api.openai.com/v1"
        self.model = defaults.string(forKey: Keys.model) ?? "gpt-4o-mini"
        self.hasKey = (defaults.string(forKey: Keys.key) ?? "").isEmpty == false
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Keys.key)
        } else {
            Keychain.set(trimmed, for: Keys.key)
        }
        hasKey = !trimmed.isEmpty
    }

    func apiKey() -> String? {
        let stored = Keychain.get(Keys.key)
        return (stored?.isEmpty == false) ? stored : defaults.string(forKey: Keys.key)
    }

    enum AIError: LocalizedError {
        case noKey
        case badResponse
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: "还没有配置 API Key。请在设置里填写。"
            case .badResponse: "模型返回的内容无法解析，请重试。"
            case .http(let code, let body): "请求失败（\(code)）：\(body)"
            }
        }
    }

    /// 让模型把一个事项拆成 2-6 条子任务标题。
    func splitSubtasks(title: String, notes: String) async throws -> [String] {
        let system = """
        你是一个任务拆解助手。把用户的事项拆成 2 到 6 条可执行的子任务标题。
        只输出 JSON 字符串数组，例如 ["确认需求", "写初稿", "内部评审"]，不要输出任何其他文字。
        """
        let user = notes.isEmpty ? "事项：\(title)" : "事项：\(title)\n备注：\(notes)"
        let content = try await chat(system: system, user: user)
        guard let array = extractJSONArray(from: content),
              let titles = array as? [String] else { throw AIError.badResponse }
        let cleaned = titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(cleaned.prefix(6))
    }

    /// 根据本周数据生成一段简短的中文周报。
    func weeklyReport(taskSummary: String, focusSummary: String) async throws -> String {
        let system = """
        你是浮光提醒的助手。根据用户本周的任务与专注数据，写一段不超过 120 字的中文周报，
        语气平实、不夸张，可以提一句建议。直接输出正文，不要标题。
        """
        let user = "任务数据：\(taskSummary)\n专注数据：\(focusSummary)"
        return try await chat(system: system, user: user)
    }

    private func chat(system: String, user: String) async throws -> String {
        guard let key = apiKey() else { throw AIError.noKey }
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.4,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            throw AIError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse
        }
        return content
    }

    private func extractJSONArray(from text: String) -> [Any]? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = cleaned.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array
        }
        // 模型可能把数组包在解释文字里：截取第一个 [ 到最后一个 ]
        guard let first = cleaned.firstIndex(of: "["), let last = cleaned.lastIndex(of: "]"), first < last else {
            return nil
        }
        let slice = String(cleaned[first...last])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }
}
