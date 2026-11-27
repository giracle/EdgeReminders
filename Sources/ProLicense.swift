import Foundation

/// 极简 Pro 许可：输入许可码解锁 Pro 功能（AI 拆子任务、AI 周报）。
/// 0.5.0 阶段为占位实现，后续可换成在线校验。
@MainActor
final class ProLicense: ObservableObject {
    static let shared = ProLicense()
    static let demoCode = "FUGUANG-PRO-2026"

    @Published var code: String {
        didSet { defaults.set(code, forKey: "pro.licenseCode") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.code = defaults.string(forKey: "pro.licenseCode") ?? ""
    }

    var isActive: Bool {
        let normalized = code.uppercased().replacingOccurrences(of: "-", with: "")
        guard !normalized.isEmpty else { return false }
        return normalized == "FUGUANGPRO2026" || normalized.hasPrefix("FUGUANG")
    }

    func activate(_ input: String) -> Bool {
        code = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return isActive
    }
}
