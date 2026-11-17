import Foundation

// MARK: - 版本检查（GitHub Releases）
//
// 从 GitHub Releases 拉取最新版本，与当前 App 版本对比，判断是否有更新。
// 走 GitHub 公开 API：GET /repos/{owner}/{repo}/releases/latest
// 不鉴权（公开仓库即可），返回 JSON 里取 tag_name。

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: String
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
    }
}

enum UpdateStatus: Equatable {
    case unknown                       // 尚未检查
    case checking                      // 检查中
    case upToDate(current: String)     // 已是最新
    case updateAvailable(current: String, latest: String, url: String, notes: String?)  // 有新版本
    case failed(message: String)       // 检查失败
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var status: UpdateStatus = .unknown

    /// 仓库名（可在需要时改）
    var owner = "Ashen-You"
    var repo = "QianNote"

    /// 当前 App 版本号（MARKETING_VERSION，即 CFBundleShortVersionString）
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 当前 build 号（CFBundleVersion）
    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// 检查更新。调用 GitHub Releases API 拿最新 tag，与当前版本做语义化比较。
    func check() async {
        status = .checking
        let current = Self.currentVersion

        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            status = .failed(message: "更新地址无效")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QianNote/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .failed(message: "网络响应异常")
                return
            }
            guard http.statusCode == 200 else {
                status = .failed(message: "检查更新失败（HTTP \(http.statusCode)）")
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            if Self.isNewer(latest, than: current) {
                status = .updateAvailable(current: current,
                                          latest: latest,
                                          url: release.htmlURL,
                                          notes: release.body)
            } else {
                status = .upToDate(current: current)
            }
        } catch {
            status = .failed(message: "检查更新失败：\(error.localizedDescription)")
        }
    }

    /// 语义化版本比较：latest > current 返回 true。
    /// 支持 "1.2.3"、"1.2"、"1" 及带 build 的形式，缺位按 0 处理。
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = splitVersion(latest)
        let b = splitVersion(current)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    /// 把 "1.2.3-beta.4" 这类串拆成数字段（非数字段忽略），返回 [1,2,3]。
    private static func splitVersion(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}
