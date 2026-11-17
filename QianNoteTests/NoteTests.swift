import XCTest
import CoreGraphics
@testable import QianNote

final class NoteTests: XCTestCase {

    // MARK: - normalizedPageSize

    func testNormalizedPageSize_keepsSmallPageUnchanged() {
        let size = Note.normalizedPageSize(CGSize(width: 768, height: 1024))
        XCTAssertEqual(size.width, 768)
        XCTAssertEqual(size.height, 1024)
    }

    func testNormalizedPageSize_clampsOversizedLongestSide() {
        // 手机截图导出的 PDF 常见 1320×2868，长边远超 1400 上限，应等比缩小
        let size = Note.normalizedPageSize(CGSize(width: 1320, height: 2868))
        let longest = max(size.width, size.height)
        XCTAssertLessThanOrEqual(longest, Note.maxPageSide)
        // 等比：宽高比保持不变（允许浮点取整误差）
        let ratio = size.width / size.height
        XCTAssertEqual(ratio, 1320 / 2868, accuracy: 0.01)
    }

    func testNormalizedPageSize_fallsBackOnNonFinite() {
        let nanSize = Note.normalizedPageSize(CGSize(width: CGFloat.nan, height: CGFloat.infinity))
        XCTAssertEqual(nanSize.width, 768)
        XCTAssertEqual(nanSize.height, 1024)
    }

    func testNormalizedPageSize_enforcesMinimumSide() {
        // 极小尺寸应至少收到 100
        let size = Note.normalizedPageSize(CGSize(width: 1, height: 1))
        XCTAssertGreaterThanOrEqual(size.width, 100)
        XCTAssertGreaterThanOrEqual(size.height, 100)
    }

    // MARK: - 宽松解码（老版本数据缺字段时用默认值补齐）

    func testNoteDecoding_missingNewFieldsUsesDefaults() throws {
        // 模拟老版本索引：只有 title，没有 inkStamps / images / pdfFileName 等新字段
        let json = """
        {"id":"\(UUID().uuidString)","title":"老笔记","createdAt":"2026-01-01T00:00:00Z"}
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(Note.self, from: data)

        XCTAssertEqual(note.title, "老笔记")
        XCTAssertEqual(note.pages.count, 1, "缺 pages 时应回落到一页默认页")
        XCTAssertTrue(note.markers.isEmpty)
        XCTAssertTrue(note.inkStamps.isEmpty)
        XCTAssertNil(note.pdfFileName)
        XCTAssertEqual(note.paperTemplate, .ruled)
    }

    func testNoteDecoding_clampsOversizedStoredPageSize() throws {
        // 老数据存着超大 mediaBox，解码时应被 normalizedPageSize 收进合法区间
        let json = """
        {"id":"\(UUID().uuidString)","title":"大页笔记","pageWidth":3000,"pageHeight":4000}
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(Note.self, from: data)

        let longest = max(note.pageWidth, note.pageHeight)
        XCTAssertLessThanOrEqual(longest, Double(Note.maxPageSide))
    }
}
