import Foundation
import UIKit

// MARK: - 主屏快捷操作

/// 主屏长按图标出现的快捷操作类型（与 Info.plist 的 UIApplicationShortcutItemType 对应）
enum HomeShortcut: String {
    case newNote = "com.example.qiannote.newNote"
    case importDocument = "com.example.qiannote.importDocument"
}

/// 冷启动时的快捷操作要先存下来：`configurationForConnecting` 跑在界面出现之前，
/// 那时 LibraryView 还没订阅通知，直接发通知会丢。
enum ShortcutInbox {
    private static let lock = NSLock()
    private static var pending: String?

    static func put(_ type: String) {
        lock.lock()
        pending = type
        lock.unlock()
    }

    static func take() -> HomeShortcut? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = pending else { return nil }
        pending = nil
        return HomeShortcut(rawValue: value)
    }
}

extension Notification.Name {
    /// App 已在运行时收到快捷操作（冷启动走 ShortcutInbox）
    static let qianNoteShortcutTriggered = Notification.Name("qiannote.shortcut.triggered")
}

// MARK: - 外部文档打开

/// 从「文件」、其它 app 的分享面板、AirDrop 打开一个文档：
/// PDF 直接用，Word / 图片 / 文本先转成 PDF，再走与「导入文档」完全相同的管线。
final class DocumentOpenCoordinator: ObservableObject {

    /// 导入完成后需要跳转过去的笔记
    @Published var noteToOpen: UUID?
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false

    private var queue: [URL] = []
    private var working = false

    /// 外部传入的文件 URL（可能一次多个，例如多选后「在 Qian's Note 中打开」）
    func open(_ urls: [URL], store: NoteStore) {
        let valid = urls.filter(\.isFileURL)
        guard !valid.isEmpty else { return }
        queue.append(contentsOf: valid)
        guard !working else { return }

        working = true
        isImporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty {
                let url = self.queue.removeFirst()
                await self.importOne(url, store: store)
            }
            self.working = false
            self.isImporting = false
        }
    }

    private func importOne(_ url: URL, store: NoteStore) async {
        guard DocumentImporter.isSupported(url) else {
            let ext = url.pathExtension.uppercased()
            errorMessage = ext.isEmpty
                ? "这个文件打不开，Qian's Note 目前支持 PDF、Word、图片和纯文本。"
                : "暂不支持 \(ext) 格式，可以先转成 PDF 再导入。"
            return
        }

        // 外部文件是安全作用域 URL：必须在整个读取期间持有访问权
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let pdfURL = try await DocumentImporter.shared.convertToPDF(url: url)
            let note = try store.importPDF(from: pdfURL)
            noteToOpen = note.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
