import Foundation
import CoreGraphics

// MARK: - 文件夹

struct Folder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
}

// MARK: - 页面上的文本框

struct TextBox: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String = ""
    var x: Double
    var y: Double
    var width: Double = 280
    var height: Double = 72
    var fontSize: Double = 22
    var colorHex: String = "#1C1C1E"
}

// MARK: - 录音书签

struct AudioMarker: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var pageIndex: Int
    var time: TimeInterval
}

// MARK: - 笔迹时间戳（逐笔回放）

struct InkStamp: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var pageID: UUID
    var time: TimeInterval
    var strokeCount: Int
}

// MARK: - 页面上的图片

struct ImageItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

// MARK: - 单页

struct NotePage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var textBoxes: [TextBox] = []
    var images: [ImageItem] = []

    init(id: UUID = UUID(), textBoxes: [TextBox] = [], images: [ImageItem] = []) {
        self.id = id
        self.textBoxes = textBoxes
        self.images = images
    }

    /// 宽松解码：老版本没有 images / textBoxes 时不至于整本笔记打不开
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        textBoxes = try container.decodeIfPresent([TextBox].self, forKey: .textBoxes) ?? []
        images = try container.decodeIfPresent([ImageItem].self, forKey: .images) ?? []
    }
}

// MARK: - 笔记

struct Note: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var folderID: UUID?
    var pages: [NotePage] = [NotePage()]
    var paperTemplate: PaperTemplate = .ruled
    var paperTint: PaperTint = .white
    var isFavorite: Bool = false

    // 页面尺寸（点），默认 768 x 1024，导入 PDF 时按第一页比例设置
    var pageWidth: Double = 768
    var pageHeight: Double = 1024

    /// 画布长边上限（点）。
    ///
    /// 页面尺寸不只是 SwiftUI 的 frame —— PencilKit 会按「页面点数 × 屏幕倍率」给整页分配
    /// 帧缓冲（`PKMetalFramebuffer`）。PDF 的 mediaBox 单位是点，手机截图导出的 PDF 常见
    /// 1320×2868，在 3 倍屏上就是 3960×8604 ≈ 3400 万像素、单张 136MB，
    /// 模拟器的 Metal 直接判为非法纹理 → `validateWithDevice:` 断言 → SIGABRT
    ///（崩溃栈落在 com.apple.pencilkit.renderer）。真机上则是几张大纹理同时驻留、内存暴涨。
    /// 手写笔记一页 1400pt 已经很宽（A4 才 595pt），超过就没必要了。
    static let maxPageSide: CGFloat = 1400

    /// 把页面尺寸收进合法区间：非有限值回落到默认页，长边超过 `maxPageSide` 时等比缩小。
    static func normalizedPageSize(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite ? size.width : 768
        let height = size.height.isFinite ? size.height : 1024
        let safeWidth = max(width, 100)
        let safeHeight = max(height, 100)
        let longest = max(safeWidth, safeHeight)
        guard longest > maxPageSide else {
            return CGSize(width: safeWidth.rounded(), height: safeHeight.rounded())
        }
        let ratio = maxPageSide / longest
        return CGSize(width: max((safeWidth * ratio).rounded(), 100),
                      height: max((safeHeight * ratio).rounded(), 100))
    }

    // PDF 底稿
    var pdfFileName: String?
    var pdfPageCount: Int = 0

    // 录音
    var audioFileName: String?
    var audioDuration: TimeInterval = 0
    var markers: [AudioMarker] = []
    /// 录音期间每一笔的落笔时刻，用于回放时逐笔复现
    var inkStamps: [InkStamp] = []

    init(id: UUID = UUID(),
         title: String,
         folderID: UUID? = nil,
         pages: [NotePage] = [NotePage()],
         paperTemplate: PaperTemplate = .ruled,
         paperTint: PaperTint = .white,
         pageSize: CGSize = CGSize(width: 768, height: 1024)) {
        self.id = id
        self.title = title
        self.folderID = folderID
        self.pages = pages
        self.paperTemplate = paperTemplate
        self.paperTint = paperTint
        let size = Note.normalizedPageSize(pageSize)
        self.pageWidth = Double(size.width)
        self.pageHeight = Double(size.height)
    }

    /// 宽松解码：老版本索引里缺少的键（例如 inkStamps）用默认值补齐，
    /// 避免升级后整本笔记读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未命名笔记"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        pages = try container.decodeIfPresent([NotePage].self, forKey: .pages) ?? [NotePage()]
        paperTemplate = try container.decodeIfPresent(PaperTemplate.self, forKey: .paperTemplate) ?? .ruled
        paperTint = try container.decodeIfPresent(PaperTint.self, forKey: .paperTint) ?? .white
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        // 老数据可能存着导入 PDF 时那份「mediaBox 点数」（比如 1320×2868），
        // 读出来就收进合法区间，否则一打开那本笔记 PencilKit 又要分配超大帧缓冲
        let stored = CGSize(width: try container.decodeIfPresent(Double.self, forKey: .pageWidth) ?? 768,
                            height: try container.decodeIfPresent(Double.self, forKey: .pageHeight) ?? 1024)
        let size = Note.normalizedPageSize(stored)
        pageWidth = Double(size.width)
        pageHeight = Double(size.height)
        pdfFileName = try container.decodeIfPresent(String.self, forKey: .pdfFileName)
        pdfPageCount = try container.decodeIfPresent(Int.self, forKey: .pdfPageCount) ?? 0
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        audioDuration = try container.decodeIfPresent(Double.self, forKey: .audioDuration) ?? 0
        markers = try container.decodeIfPresent([AudioMarker].self, forKey: .markers) ?? []
        inkStamps = try container.decodeIfPresent([InkStamp].self, forKey: .inkStamps) ?? []
    }

    var pageSize: CGSize {
        CGSize(width: max(pageWidth, 1), height: max(pageHeight, 1))
    }

    var aspectRatio: CGFloat {
        pageHeight > 0 ? CGFloat(pageWidth / pageHeight) : 0.75
    }

    var hasPDF: Bool { pdfFileName != nil }
    var hasRecording: Bool { audioFileName != nil }

    var pageCountText: String {
        "\(pages.count) 页"
    }
}

// MARK: - 本地索引文件

struct LibraryIndex: Codable {
    var version: Int = 1
    var notes: [Note] = []
    var folders: [Folder] = []
}
