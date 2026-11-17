import XCTest
import PencilKit
@testable import QianNote

/// 共享画布的墨迹搬运：各页 ↔ 全局坐标。
/// 跨页书写的正确性完全依赖这层，所以这里覆盖得细一些。
final class InkComposerTests: XCTestCase {

    private let pageHeight: CGFloat = 1000

    // MARK: - 合并

    func testMerge_offsetsEachPageByIndex() {
        let first = drawingWithVerticalStroke(fromY: 100, toY: 200)
        let second = drawingWithVerticalStroke(fromY: 100, toY: 200)

        let merged = InkComposer.merge(pageDrawings: [first, second], pageHeight: pageHeight)

        XCTAssertEqual(merged.strokes.count, 2)
        // 第一页保持原样
        XCTAssertEqual(merged.strokes[0].path.first!.location.y, 100, accuracy: 0.01)
        // 第二页整体下移一页高
        XCTAssertEqual(merged.strokes[1].path.first!.location.y, 1100, accuracy: 0.01)
        XCTAssertEqual(merged.strokes[1].path.last!.location.y, 1200, accuracy: 0.01)
    }

    func testMerge_skipsEmptyPages() {
        let merged = InkComposer.merge(pageDrawings: [PKDrawing(), drawingWithVerticalStroke(fromY: 0, toY: 10), PKDrawing()],
                                       pageHeight: pageHeight)
        XCTAssertEqual(merged.strokes.count, 1)
        XCTAssertEqual(merged.strokes[0].path.first!.location.y, 1000, accuracy: 0.01)
    }

    // MARK: - 切分

    func testSplit_keepsInPageStrokesTogether() {
        let global = drawingWithVerticalStroke(fromY: 100, toY: 200)
        let parts = InkComposer.split(global: global, pageHeight: pageHeight, pageCount: 3)

        XCTAssertEqual(parts[0]?.strokes.count, 1)
        XCTAssertEqual(parts[1]?.strokes.count, 0)
        XCTAssertEqual(parts[2]?.strokes.count, 0)
        XCTAssertEqual(parts[0]!.strokes[0].path.first!.location.y, 100, accuracy: 0.01)
    }

    /// 一笔从第 0 页底部划到第 1 页顶部：整笔留在起笔页，绝不切开
    /// （切开后两段各自收笔，渲染出来中间会有缝，就是用户看到的「断层」）
    func testSplit_keepsCrossPageStrokeWholeInStartingPage() {
        let global = drawingWithVerticalStroke(fromY: 950, toY: 1050)
        let parts = InkComposer.split(global: global, pageHeight: pageHeight, pageCount: 2)

        guard let firstPage = parts[0], let secondPage = parts[1] else {
            return XCTFail("两页都应该有结果")
        }
        XCTAssertEqual(firstPage.strokes.count, 1, "整笔归到第 0 页")
        XCTAssertEqual(secondPage.strokes.count, 0, "第 1 页不应有被切下来的碎片")

        // 坐标仍是起笔页内的原坐标，允许超出页底（渲染时由画布自然延伸）
        let stroke = firstPage.strokes[0]
        XCTAssertEqual(stroke.path.first!.location.y, 950, accuracy: 0.01)
        XCTAssertEqual(stroke.path.last!.location.y, 1050, accuracy: 0.01)
    }

    /// 一笔横跨三页：仍然只出现在起笔页
    func testSplit_crossPageStrokeStaysInFirstPage() {
        let global = drawingWithVerticalStroke(fromY: 500, toY: 2500)
        let parts = InkComposer.split(global: global, pageHeight: pageHeight, pageCount: 4)

        XCTAssertEqual(parts[0]?.strokes.count, 1)
        XCTAssertEqual(parts[1]?.strokes.count, 0)
        XCTAssertEqual(parts[2]?.strokes.count, 0)
        XCTAssertEqual(parts[3]?.strokes.count, 0)
    }

    func testSplit_clampsOutOfRangeContentToFirstAndLastPage() {
        let above = drawingWithVerticalStroke(fromY: -50, toY: -10)
        let below = drawingWithVerticalStroke(fromY: 5000, toY: 5100)
        let parts = InkComposer.split(global: PKDrawing(strokes: above.strokes + below.strokes),
                                      pageHeight: pageHeight, pageCount: 2)

        XCTAssertEqual(parts[0]?.strokes.count, 1, "页顶以上夹到第 0 页")
        XCTAssertEqual(parts[1]?.strokes.count, 1, "页尾以下夹到最后一页")
    }

    // MARK: - 往返

    func testMergeSplitRoundTrip_preservesInk() {
        let page0 = drawingWithVerticalStroke(fromY: 50, toY: 150)
        let page1 = drawingWithVerticalStroke(fromY: 200, toY: 400)
        let page2 = drawingWithVerticalStroke(fromY: 10, toY: 20)

        let merged = InkComposer.merge(pageDrawings: [page0, page1, page2], pageHeight: pageHeight)
        let split = InkComposer.split(global: merged, pageHeight: pageHeight, pageCount: 3)

        XCTAssertEqual(split[0]?.strokes.count, 1)
        XCTAssertEqual(split[1]?.strokes.count, 1)
        XCTAssertEqual(split[2]?.strokes.count, 1)

        XCTAssertEqual(split[0]!.strokes[0].path.first!.location.y, 50, accuracy: 0.01)
        XCTAssertEqual(split[1]!.strokes[0].path.first!.location.y, 200, accuracy: 0.01)
        XCTAssertEqual(split[2]!.strokes[0].path.first!.location.y, 10, accuracy: 0.01)
    }

    /// 跨页笔迹往返后仍然是同一条笔迹（不会被拆成两条，也就不会有接缝）
    func testMergeSplitRoundTrip_keepsStrokeAsOnePiece() {
        let global = drawingWithVerticalStroke(fromY: 900, toY: 1100)
        let parts = InkComposer.split(global: global, pageHeight: pageHeight, pageCount: 2)
        let reMerged = InkComposer.merge(pageDrawings: [parts[0]!, parts[1]!], pageHeight: pageHeight)

        XCTAssertEqual(reMerged.strokes.count, 1, "整笔往返不应该变成两条")
        XCTAssertEqual(reMerged.strokes[0].path.first!.location.y, 900, accuracy: 0.01)
        XCTAssertEqual(reMerged.strokes[0].path.last!.location.y, 1100, accuracy: 0.01)
    }

    // MARK: - 页索引

    func testPageIndex_mapsAndClamps() {
        XCTAssertEqual(InkComposer.pageIndex(for: 0, pageHeight: pageHeight, pageCount: 3), 0)
        XCTAssertEqual(InkComposer.pageIndex(for: 999, pageHeight: pageHeight, pageCount: 3), 0)
        XCTAssertEqual(InkComposer.pageIndex(for: 1000, pageHeight: pageHeight, pageCount: 3), 1)
        XCTAssertEqual(InkComposer.pageIndex(for: 2500, pageHeight: pageHeight, pageCount: 3), 2)
        XCTAssertEqual(InkComposer.pageIndex(for: -100, pageHeight: pageHeight, pageCount: 3), 0)
        XCTAssertEqual(InkComposer.pageIndex(for: 9999, pageHeight: pageHeight, pageCount: 3), 2)
    }

    // MARK: - 辅助

    /// 一条竖直的笔迹（只有两个控制点，够表达位置和跨页关系）
    private func drawingWithVerticalStroke(fromY: CGFloat, toY: CGFloat) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let points: [PKStrokePoint] = [
            PKStrokePoint(location: CGPoint(x: 40, y: fromY),
                          timeOffset: 0,
                          size: CGSize(width: 3, height: 3),
                          opacity: 1,
                          force: 1,
                          azimuth: 0,
                          altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 40, y: toY),
                          timeOffset: 0.1,
                          size: CGSize(width: 3, height: 3),
                          opacity: 1,
                          force: 1,
                          azimuth: 0,
                          altitude: .pi / 2)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
    }
}
