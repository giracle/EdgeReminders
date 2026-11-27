import Foundation

/// 通过 GitHub Releases API 检查更新（无 Sparkle 依赖）。
enum UpdateChecker {
    struct UpdateInfo: Equatable {
        let version: String
        let htmlURL: String
    }

    private static let repository = "giracle/EdgeReminders"

    static func checkCurrent() async -> Result<UpdateInfo?, Error> {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String else {
                return .failure(URLError(.badServerResponse))
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  compare(version, current) == .orderedDescending else {
                return .success(nil)
            }
            return .success(UpdateInfo(version: version, htmlURL: htmlURL))
        } catch {
            return .failure(error)
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let components = { (version: String) in
            version.split(separator: ".").compactMap { Int($0) }
        }
        let a = components(lhs)
        let b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
