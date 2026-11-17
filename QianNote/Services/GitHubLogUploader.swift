import Foundation
import Security

// MARK: - GitHub 日志上传服务
//
// 把 App 采集的日志上传到专用私有仓库 qiannote-logs。
// 通道：GitHub Contents API —— PUT /repos/{owner}/{repo}/contents/{path}
//
// 鉴权：fine-grained token（仅授权目标仓库 Contents: Read and write）。
// token 存 Keychain，首次在 App 里粘贴一次，之后自动读取，不写死、不落明文盘。

final class GitHubLogUploader {
    static let shared = GitHubLogUploader()

    private let owner = "mbc-travis"
    private let repo = "qiannote-logs"

    private static let tokenService = "com.example.qiannote.github"
    private static let tokenAccount = "log-upload-token"

    // MARK: - Token 存取（Keychain）

    /// 读取已保存的 token，没有返回 nil
    func savedToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService,
            kSecAttrAccount as String: Self.tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 保存 token（覆盖旧值）
    func saveToken(_ token: String) {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService,
            kSecAttrAccount as String: Self.tokenAccount
        ]
        // 先删旧值，再写新值（避免 errSecDuplicateItem）
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clearToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService,
            kSecAttrAccount as String: Self.tokenAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 上传

    /// 上传一段日志文本到仓库 logs/ 目录。
    /// - Parameter log: 日志内容
    /// - Parameter deviceName: 设备名（iPad 机型），用于拼文件名
    /// - Returns: 上传后的文件 URL，失败抛错
    func upload(log: String, deviceName: String) async throws -> URL {
        guard let token = savedToken(), !token.isEmpty else {
            throw UploadError.noToken
        }

        // 文件名：设备名-日期-时间.log，非法字符替换成 -
        let safeDevice = deviceName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let timestamp = Self.fileTimestampFormatter.string(from: Date())
        let fileName = "\(safeDevice)-\(timestamp).log"
        let path = "logs/\(fileName)"

        // GitHub Contents API
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(path)"
        guard let url = URL(string: urlString) else {
            throw UploadError.invalidURL
        }

        // 请求体：message（commit message）+ content（base64 编码的文件内容）
        let base64 = log.data(using: .utf8)!.base64EncodedString()
        let body: [String: Any] = [
            "message": "上传日志 \(fileName)",
            "content": base64,
            "branch": "main"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw UploadError.encodeFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("QianNote/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")", forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.networkFailed
        }

        switch http.statusCode {
        case 200, 201:
            // 成功：解析返回里的 html_url（或直接拼文件 URL）
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [String: Any],
               let htmlURL = content["html_url"] as? String,
               let fileURL = URL(string: htmlURL) {
                return fileURL
            }
            return URL(string: "https://github.com/\(owner)/\(repo)/blob/main/\(path)")!
        case 401:
            throw UploadError.badToken
        case 404:
            throw UploadError.repoNotFound
        case 409:
            throw UploadError.fileExists
        default:
            // 尝试从响应里读 GitHub 的 message 字段
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["message"] as? String
            throw UploadError.http(http.statusCode, message)
        }
    }

    // MARK: - 设备信息

    /// 当前设备名（"iPad Pro" 之类），用于日志文件名前缀
    static func deviceName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return Self.deviceName(fromModelIdentifier: identifier)
    }

    private static func deviceName(fromModelIdentifier identifier: String) -> String {
        // 常见的 iPad 机型标识 → 友好名（不全，按需补充）
        let map: [String: String] = [
            "iPad13,18": "iPad 10", "iPad13,19": "iPad 10",
            "iPad14,3": "iPad Pro 11 M2", "iPad14,4": "iPad Pro 11 M2",
            "iPad14,5": "iPad Pro 12.9 M2", "iPad14,6": "iPad Pro 12.9 M2",
            "iPad16,3": "iPad Pro 11 M4", "iPad16,4": "iPad Pro 11 M4",
            "iPad16,5": "iPad Pro 13 M4", "iPad16,6": "iPad Pro 13 M4"
        ]
        return map[identifier] ?? identifier
    }

    // MARK: - 错误

    enum UploadError: LocalizedError {
        case noToken
        case invalidURL
        case encodeFailed
        case networkFailed
        case badToken
        case repoNotFound
        case fileExists
        case http(Int, String?)

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "尚未配置 GitHub Token，请先在「设置」里粘贴。"
            case .invalidURL, .encodeFailed:
                return "请求构造失败。"
            case .networkFailed:
                return "网络请求失败，请检查网络连接。"
            case .badToken:
                return "Token 无效或已过期，请重新粘贴。"
            case .repoNotFound:
                return "日志仓库不存在或 Token 无权访问。"
            case .fileExists:
                return "同名日志已存在（文件名冲突，稍后重试）。"
            case .http(let code, let message):
                return message ?? "上传失败（HTTP \(code)）。"
            }
        }
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
