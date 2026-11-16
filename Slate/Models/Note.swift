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

    // PDF 底稿
    var pdfFileName: String?
    var pdfPageCount: Int = 0

    // 录音
    var audioFileName: String?
    var audioDuration: TimeInterval = 0
    var markers: [AudioMarker] = []

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
        self.pageWidth = Double(pageSize.width)
        self.pageHeight = Double(pageSize.height)
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
