import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 关于 / 设置页
//
// 内容：
// 1. App 图标 + 名称 + 当前版本号
// 2. 「检查更新」：连 GitHub Releases 拿最新版本对比
// 3. 日志：采集（操作 + 异常）、预览、导出（分享到文件）、上传到 GitHub（专用私有仓库）

struct AboutView: View {
    @StateObject private var updateChecker = UpdateChecker()
    @State private var showUpdateAlert = false
    @State private var showLogSheet = false
    @State private var logPreview = ""
    @State private var showTokenSheet = false
    @State private var tokenText = ""
    @State private var uploadState: UploadState = .idle

    enum UploadState: Equatable {
        case idle
        case uploading
        case success(url: String)
        case failed(message: String)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                appHeader
                updateSection
                logSection
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Theme.libraryBackground.ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .alert(updateAlertTitle, isPresented: $showUpdateAlert) {
            switch updateChecker.status {
            case .updateAvailable(_, _, let url, _):
                Button("前往下载") {
                    if let u = URL(string: url) { UIApplication.shared.open(u) }
                }
                Button("取消", role: .cancel) {}
            case .failed:
                Button("好", role: .cancel) {}
            default:
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(updateAlertMessage)
        }
        .alert("设置 GitHub Token", isPresented: $showTokenSheet) {
            TextField("粘贴 fine-grained token", text: $tokenText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") {
                let t = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    GitHubLogUploader.shared.saveToken(t)
                    tokenText = ""
                }
            }
            Button("取消", role: .cancel) { tokenText = "" }
        } message: {
            Text("需要一个 fine-grained token，仅授权 mbc-travis/qiannote-logs 仓库的 Contents: Read and write。保存在本机钥匙串，不会明文外泄。")
        }
        .alert(uploadAlertTitle, isPresented: uploadAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(uploadAlertMessage)
        }
    }

    private var uploadAlertBinding: Binding<Bool> {
        Binding(
            get: {
                if case .success = uploadState { return true }
                if case .failed = uploadState { return true }
                return false
            },
            set: { if !$0 { uploadState = .idle } }
        )
    }

    private var uploadAlertTitle: String {
        switch uploadState {
        case .success: return "上传成功"
        case .failed: return "上传失败"
        default: return ""
        }
    }

    private var uploadAlertMessage: String {
        switch uploadState {
        case .success(let url): return "日志已上传到：\n\(url)"
        case .failed(let message): return message
        default: return ""
        }
    }

    // MARK: - App 信息头

    private var appHeader: some View {
        VStack(spacing: 14) {
            Image(uiImage: currentIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("Qian's Note")
                .font(.title2.bold())

            Text("版本 \(UpdateChecker.currentVersion)（\(UpdateChecker.currentBuild)）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    /// 当前使用的图标缩略图（主图标=截图版，备用=AI 版）。
    /// AppIcon.appiconset 是 app icon 资源，UIImage(named:) 取不到，改用 imageset 缩略图。
    private var currentIconImage: UIImage {
        let thumb = AppIconChoice.current().thumbName
        return UIImage(named: thumb) ?? UIImage(systemName: "square.and.pencil") ?? UIImage()
    }

    // MARK: - 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("版本更新")

            Button {
                Task { await updateChecker.check() }
            } label: {
                HStack {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    statusIndicator
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(updateChecker.status == .checking)

            if case .updateAvailable(let current, let latest, _, _) = updateChecker.status {
                Button {
                    showUpdateAlert = true
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.accent)
                        Text("发现新版本 v\(latest)（当前 v\(current)）")
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch updateChecker.status {
        case .checking:
            ProgressView()
        case .upToDate:
            Text("已是最新")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .updateAvailable(_, let latest, _, _):
            Text("v\(latest) 可用")
                .font(.footnote.bold())
                .foregroundStyle(Theme.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .unknown:
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var updateAlertTitle: String {
        switch updateChecker.status {
        case .updateAvailable: return "发现新版本"
        case .failed: return "检查失败"
        default: return "更新"
        }
    }

    private var updateAlertMessage: String {
        switch updateChecker.status {
        case .updateAvailable(let current, let latest, _, _):
            return "最新版本 v\(latest)，你当前是 v\(current)。是否前往下载？"
        case .failed(let message):
            return message
        case .upToDate(let current):
            return "当前已是最新版本 v\(current)。"
        default:
            return ""
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("日志")

            Text("采集 App 的运行日志（操作与异常），用于排查问题。可导出到「文件」，或上传到 GitHub 的专用私有仓库。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    logPreview = AppLogger.shared.combinedLog()
                    showLogSheet = true
                } label: {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    exportLog()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                uploadLog()
            } label: {
                if case .uploading = uploadState {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("上传中…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("上传到 GitHub", systemImage: "arrow.up.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(uploadState == .uploading)

            // Token 配置
            HStack {
                if GitHubLogUploader.shared.savedToken()?.isEmpty == false {
                    Text("已配置 Token")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未配置 Token")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("设置 Token") { showTokenSheet = true }
                    .font(.footnote)
                Button("清除") { GitHubLogUploader.shared.clearToken() }
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showLogSheet) {
            LogPreviewSheet(log: logPreview, onExport: exportLog, onUpload: uploadLog)
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(spacing: 4) {
            Text("Qian's Note · 为 iPad 与 Apple Pencil 打造")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    // MARK: - 导出 / 上传

    private func exportLog() {
        let log = AppLogger.shared.combinedLog()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("qiannote-log-\(Self.logTimestamp()).log")
        try? log.write(to: tmp, atomically: true, encoding: .utf8)

        let activity = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            if let pop = activity.popoverPresentationController {
                pop.sourceView = root.view
                pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            }
            root.present(activity, animated: true)
        }
    }

    /// 上传到 GitHub 专用私有仓库（qiannote-logs）。
    /// 需要 fine-grained token（仅该仓库 Contents: Read and write），
    /// token 存 Keychain，未配置时引导用户先粘贴。
    private func uploadLog() {
        guard let token = GitHubLogUploader.shared.savedToken(), !token.isEmpty else {
            showTokenSheet = true
            return
        }
        uploadState = .uploading
        let log = AppLogger.shared.combinedLog()
        let device = GitHubLogUploader.deviceName()

        Task {
            do {
                let url = try await GitHubLogUploader.shared.upload(log: log, deviceName: device)
                uploadState = .success(url: url.absoluteString)
            } catch {
                uploadState = .failed(message: error.localizedDescription)
            }
        }
    }

    private static func logTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - 日志预览 / 上传弹窗

private struct LogPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let log: String
    let onExport: () -> Void
    let onUpload: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(log.isEmpty ? "暂无日志" : log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        onExport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
