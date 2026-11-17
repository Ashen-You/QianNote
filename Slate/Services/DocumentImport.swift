import Foundation
import UIKit
import WebKit
import PDFKit

enum DocumentImportError: LocalizedError {
    case unsupported
    case renderFailed
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unsupported: return "这个格式暂时不支持，可以先转成 PDF 或 Word 再导入。"
        case .renderFailed: return "文档渲染失败，换个文件试试。"
        case .emptyDocument: return "文档里没有可导入的内容。"
        }
    }
}

/// 把 Word / RTF / HTML / 纯文本 / 图片转成 PDF，复用现有的 PDF 笔记管线。
final class DocumentImporter: NSObject {

    static let shared = DocumentImporter()

    static let supportedExtensions: [String] = [
        "pdf", "doc", "docx", "rtf", "rtfd", "html", "htm", "txt", "md", "csv",
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "bmp"
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    /// 统一入口：返回一个可被 PDFKit 打开的本地 PDF
    func convertToPDF(url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return url
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "bmp":
            return try imageToPDF(url: url)
        default:
            return try await webToPDF(url: url)
        }
    }

    // MARK: - 图片 → PDF

    private func imageToPDF(url: URL) throws -> URL {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw DocumentImportError.renderFailed
        }

        let pageSize = CGSize(width: 612, height: 792)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Slate"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-import-\(UUID().uuidString).pdf")

        try renderer.writePDF(to: output) { context in
            context.beginPage()
            let scale = min(pageSize.width / max(image.size.width, 1),
                            pageSize.height / max(image.size.height, 1))
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (pageSize.width - width) / 2,
                                  y: (pageSize.height - height) / 2,
                                  width: width,
                                  height: height))
        }
        return output
    }

    // MARK: - Office / 文本 → PDF

    private func webToPDF(url: URL) async throws -> URL {
        let view: WKWebView = await MainActor.run {
            // 放在屏幕外而不是 isHidden：隐藏的 WebView 有时渲染不出内容
            let webView = WKWebView(frame: CGRect(x: -3000, y: -3000, width: 612, height: 792))
            webView.navigationDelegate = self
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            window?.addSubview(webView)
            return webView
        }
        self.webView = view

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            DispatchQueue.main.async {
                view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
                self?.finishNavigation(error: DocumentImportError.renderFailed)
            }
        }

        let data: Data
        do {
            data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                view.createPDF(configuration: WKPDFConfiguration()) { result in
                    switch result {
                    case .success(let pdfData):
                        continuation.resume(returning: pdfData)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            cleanup()
            throw DocumentImportError.renderFailed
        }

        guard !data.isEmpty else {
            cleanup()
            throw DocumentImportError.emptyDocument
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-import-\(UUID().uuidString).pdf")
        try data.write(to: output, options: .atomic)

        let pageCount = PDFDocument(data: data)?.pageCount ?? 0
        cleanup()
        guard pageCount > 0 else { throw DocumentImportError.emptyDocument }
        return output
    }

    private func cleanup() {
        webView?.removeFromSuperview()
        webView = nil
    }

    private func finishNavigation(error: Error?) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

extension DocumentImporter: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error: error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finishNavigation(error: error)
    }
}
