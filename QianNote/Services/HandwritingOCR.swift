import Foundation
import Vision
import PencilKit
import UIKit

/// 手写内容 OCR：把手写页渲染成位图，交给 Vision 识别成文本，供列表搜索使用。
///
/// 设计取舍：
/// - **只渲染墨迹包围盒**，不渲染整页。整页 768×1024 @2x 是 3000×4000 的大图，
///   视觉识别耗时会翻好几倍，而空白区域对结果没有任何贡献。
/// - **识别结果进模型**（`NotePage.ocrText`），不进内存缓存：手写索引是"算一次、用很久"
///   的东西，冷启动重算全部页面会让首屏卡好几十秒。
/// - Vision 的中文手写识别率有限，这里只把它当"模糊检索"用，不对外暴露成"转换文字"。
enum HandwritingOCR {

    /// 渲染倍率。1.5 倍在识别率和耗时之间比较平衡（1 倍小字容易糊，3 倍太慢）。
    private static let renderScale: CGFloat = 1.5

    /// 识别一页墨迹。返回归一化后的文本，没有可识别内容时返回 nil。
    static func recognize(drawing: PKDrawing, pageSize: CGSize) async -> String? {
        let inkBounds = drawing.bounds
        // 太小的墨迹（一个点、一道短线）没有识别价值，直接跳过，省掉一次全流程
        guard !inkBounds.isNull, inkBounds.width > 8, inkBounds.height > 8 else { return nil }

        let pageRect = CGRect(origin: .zero, size: pageSize)
        let padding: CGFloat = 20
        let crop = inkBounds.insetBy(dx: -padding, dy: -padding).intersection(pageRect)
        guard !crop.isEmpty, crop.width > 1, crop.height > 1 else { return nil }

        // PencilKit 的渲染必须在主线程做，识别可以丢到后台
        guard let image = await render(drawing: drawing, crop: crop) else { return nil }
        return await recognizeText(in: image)
    }

    // MARK: - 渲染

    @MainActor
    private static func render(drawing: PKDrawing, crop: CGRect) -> UIImage? {
        let image = drawing.image(from: crop, scale: renderScale)
        return image.size.width > 0 ? image : nil
    }

    // MARK: - 识别

    /// 识别一张图里的文字（internal 以便单测直接验证 Vision 链路）
    static func recognizeText(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // completion 和 perform 抛错两条路径都可能收尾，加一道锁保证只 resume 一次
            let hasResumed = Resumed()

            let request = VNRecognizeTextRequest { request, _ in
                guard hasResumed.claim() else { return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let joined = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                continuation.resume(returning: normalize(joined))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            DispatchQueue.global(qos: .utility).async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                } catch {
                    guard hasResumed.claim() else { return }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - 归一化

    /// 统一大小写、压缩空白，让「搜索词」和「索引」用同一套规则比较。
    static func normalize(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 一次性收尾标志
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
