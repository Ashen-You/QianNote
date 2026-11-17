import XCTest
import PencilKit
import UIKit
import SwiftUI
@testable import QianNote

/// 连续滚动共享画布的**几何不变量**测试。
///
/// 用户报的两个问题——「滚动时背景和墨迹错位 / 页面被强行拽走」和「跨页笔迹断层」——
/// 本质都是「墨迹画布」和「纸张背景」两套坐标系在某一帧不再重合。
/// 这里不去截图比对，而是直接断言坐标映射：
///
/// 1. 同一个逻辑坐标点，在画布坐标系和背景坐标系里必须落到**同一个屏幕位置**（误差 < 0.01pt）。
///    只要这条成立，笔迹就永远贴着纸张，不可能断层或错位。
/// 2. 滚动 / 缩放 / 跳页之后，画布的 `zoomScale` 必须恒为 1（缩放只允许有一处权威）。
/// 3. 内容尺寸必须恒等于「逻辑尺寸 × 当前缩放」，否则滚动范围会漂。
/// 4. 用户滚动到位后，再来多少次 SwiftUI 刷新（`syncFromSwiftUI`）都不许改变 `contentOffset`
///    —— 这就是「滚动被拽走」的直接回归测试。
final class ContinuousCanvasChaosTests: XCTestCase {

    private typealias Canvas = ContinuousInkCanvas<EmptyView>

    private let pageSize = CGSize(width: 768, height: 1024)
    private let pageCount = 12
    private let viewport = CGSize(width: 1248, height: 826)

    // MARK: - 夹具

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private struct Harness {
        let container: Canvas.ContainerView
        let coordinator: Canvas.Coordinator
        let zoom: Box<CGFloat>
        let page: Box<Int>
        let ink: Box<PKDrawing>
        let pageCount: Box<Int>
        /// 重建 Canvas 结构体并交给 coordinator（等价于 SwiftUI 再算一次 body）
        let rebuild: () -> Void

        var scroll: UIScrollView { container.scroll }
        var canvas: Canvas.InkCanvasView { container.canvas }

        /// 背景层（UIHostingController 的视图）
        var host: UIView? {
            container.contentView.subviews.first { $0 !== container.canvas }
        }
    }

    private var logicalSizeFor: (Int) -> CGSize {
        { count in CGSize(width: self.pageSize.width, height: self.pageSize.height * CGFloat(max(count, 1))) }
    }

    private func makeHarness(zoomLevel: CGFloat = 1, initialPageCount: Int? = nil) -> Harness {
        let zoom = Box<CGFloat>(zoomLevel)
        let page = Box<Int>(0)
        let ink = Box<PKDrawing>(PKDrawing())
        let count = Box<Int>(initialPageCount ?? pageCount)

        let build: () -> Canvas = { [pageSize] in
            Canvas(
                pageSize: pageSize,
                pageCount: count.value,
                globalDrawing: ink.value,
                tool: PKInkingTool(.pen, color: .black, width: 4),
                toolKey: "pen",
                isDrawingEnabled: true,
                fingerDrawing: false,
                shapeRecognition: false,
                isSourceEligibleForSnap: false,
                zoom: Binding(get: { zoom.value }, set: { zoom.value = $0 }),
                currentPage: Binding(get: { page.value }, set: { page.value = $0 }),
                onDrawingChange: { ink.value = $0 },
                background: EmptyView()
            )
        }

        let coordinator = build().makeCoordinator()
        let container = Canvas.ContainerView()
        container.frame = CGRect(origin: .zero, size: viewport)
        coordinator.attach(to: container, background: AnyView(EmptyView()))
        container.layoutIfNeeded()
        return Harness(container: container, coordinator: coordinator,
                       zoom: zoom, page: page, ink: ink, pageCount: count,
                       rebuild: { coordinator.parent = build() })
    }

    /// 模拟一次 SwiftUI 刷新（EditorView body 重算 → updateUIView）
    private func refresh(_ h: Harness) {
        h.rebuild()
        h.coordinator.syncFromSwiftUI()
        h.container.layoutIfNeeded()
    }

    // MARK: - 不变量

    private func assertInvariants(_ h: Harness,
                                 _ label: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let scroll = h.scroll
        // 视口可能被混沌改过，fit 要按当前视口算
        let fit = h.container.bounds.width / pageSize.width
        let logical = logicalSizeFor(h.pageCount.value)

        // 1. 画布与背景必须同尺寸同原点。
        //    UIScrollView 用 transform 放大 zoom 视图，所以：
        //    - bounds 是「逻辑尺寸」（永远不变）
        //    - frame 是「屏幕尺寸」（= 逻辑尺寸 × zoomScale），读 frame 当逻辑尺寸用会算错
        XCTAssertEqual(h.container.contentView.bounds.width, logical.width, accuracy: 0.5,
                       "\(label): contentView 逻辑宽度不对", file: file, line: line)
        XCTAssertEqual(h.container.contentView.bounds.height, logical.height, accuracy: 0.5,
                       "\(label): contentView 逻辑高度不对", file: file, line: line)
        XCTAssertEqual(h.container.contentView.frame.width, logical.width * scroll.zoomScale, accuracy: 1,
                       "\(label): contentView 屏幕宽度 != 逻辑宽度 × 缩放", file: file, line: line)
        XCTAssertEqual(h.container.contentView.frame.height, logical.height * scroll.zoomScale, accuracy: 2,
                       "\(label): contentView 屏幕高度 != 逻辑高度 × 缩放", file: file, line: line)
        XCTAssertEqual(h.canvas.frame, CGRect(origin: .zero, size: logical),
                       "\(label): 画布 frame 不等于逻辑尺寸（墨迹会被拉伸/压缩）", file: file, line: line)

        // 2. 画布永远 1:1
        XCTAssertEqual(h.canvas.zoomScale, 1, accuracy: 0.0001,
                       "\(label): 画布 zoomScale 不为 1（双缩放会导致墨迹错位）", file: file, line: line)

        // 3. 滚动范围 = 逻辑尺寸 × 缩放
        XCTAssertEqual(scroll.contentSize.width, logical.width * scroll.zoomScale, accuracy: 1,
                       "\(label): contentSize 宽度与缩放不匹配", file: file, line: line)
        XCTAssertEqual(scroll.contentSize.height, logical.height * scroll.zoomScale, accuracy: 1,
                       "\(label): contentSize 高度与缩放不匹配", file: file, line: line)

        // 4. 缩放落在合法区间
        XCTAssertGreaterThanOrEqual(scroll.zoomScale, fit - 0.001, "\(label): 低于最小缩放", file: file, line: line)
        XCTAssertLessThanOrEqual(scroll.zoomScale, fit * 6 + 0.001, "\(label): 超过最大缩放", file: file, line: line)

        // 5. 核心：墨迹坐标系与纸张坐标系必须完全重合
        guard let host = h.host else {
            XCTFail("\(label): 找不到背景层", file: file, line: line)
            return
        }
        let samples: [CGPoint] = [
            .zero,
            CGPoint(x: pageSize.width, y: 0),
            CGPoint(x: 0, y: pageSize.height),
            CGPoint(x: pageSize.width / 2, y: pageSize.height * 3.5),
            CGPoint(x: 123, y: logical.height - 1)
        ]
        for point in samples {
            let onCanvas = h.canvas.convert(point, to: h.container)
            let onPaper = host.convert(point, to: h.container)
            XCTAssertEqual(onCanvas.x, onPaper.x, accuracy: 0.01,
                           "\(label): 逻辑点 \(point) 的墨迹 x 与纸张 x 不重合", file: file, line: line)
            XCTAssertEqual(onCanvas.y, onPaper.y, accuracy: 0.01,
                           "\(label): 逻辑点 \(point) 的墨迹 y 与纸张 y 不重合", file: file, line: line)
        }

        // 6. 反向换算：屏幕上一点回到画布坐标，必须能还原出正确的页码
        let pageCenter = CGPoint(x: pageSize.width / 2, y: pageSize.height * 2.5)
        let screenPoint = h.canvas.convert(pageCenter, to: h.container)
        let back = h.canvas.convert(screenPoint, from: h.container)
        XCTAssertEqual(back.x, pageCenter.x, accuracy: 0.01, "\(label): 坐标往返失真", file: file, line: line)
        XCTAssertEqual(back.y, pageCenter.y, accuracy: 0.01, "\(label): 坐标往返失真", file: file, line: line)
    }

    private func scrollAndNotify(_ h: Harness, to y: CGFloat) {
        h.scroll.contentOffset = CGPoint(x: h.scroll.contentOffset.x, y: y)
        h.coordinator.scrollViewDidScroll(h.scroll)
    }

    // MARK: - 单点行为

    func testInitialLayout_isAlignedAndAtTop() {
        let h = makeHarness()
        assertInvariants(h, "初始布局")
        XCTAssertEqual(h.scroll.zoomScale, viewport.width / pageSize.width, accuracy: 0.001,
                       "初次布局不该有额外缩放")
        XCTAssertEqual(h.scroll.contentOffset.y, 0, accuracy: 0.5,
                       "初次布局不应该自己滚到中间（会看起来像被拽走）")
    }

    func testScrolling_doesNotDriftOnRepeatedSwiftUIRefresh() {
        let h = makeHarness()
        let target = pageSize.height * 4.3 * h.scroll.zoomScale
        scrollAndNotify(h, to: target)

        for round in 0..<20 {
            refresh(h)
            XCTAssertEqual(h.scroll.contentOffset.y, target, accuracy: 0.5,
                           "第 \(round) 次 SwiftUI 刷新后滚动位置被改动了")
            assertInvariants(h, "刷新第 \(round) 次")
        }
    }

    func testPinchZoom_keepsInkGluedToPaper() {
        let h = makeHarness()
        scrollAndNotify(h, to: pageSize.height * 2 * h.scroll.zoomScale)

        for level in stride(from: CGFloat(1.2), through: 6, by: 0.7) {
            h.zoom.value = level
            refresh(h)
            assertInvariants(h, "缩放 \(level)")
        }
        // 再缩回 1
        h.zoom.value = 1
        refresh(h)
        assertInvariants(h, "缩回 1")
    }

    func testPageJump_updatesOffsetAndReportsPage() {
        let h = makeHarness()
        for page in [3, 7, 11, 0, 5] {
            h.page.value = page
            refresh(h)
            assertInvariants(h, "跳到第 \(page) 页")
            let expected = min(CGFloat(page) * pageSize.height * h.scroll.zoomScale,
                               max(h.scroll.contentSize.height - viewport.height, 0))
            XCTAssertEqual(h.scroll.contentOffset.y, expected, accuracy: 1,
                           "跳到第 \(page) 页后偏移不对")
        }
    }

    func testBounceBeyondBounds_doesNotCorruptGeometry() {
        let h = makeHarness()
        for y in [CGFloat(-260), -80, 0, h.scroll.contentSize.height + 200] {
            scrollAndNotify(h, to: y)
            assertInvariants(h, "越界回弹 \(y)")
        }
    }

    // MARK: - 混沌

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// 随机滚动 / 缩放 / 跳页 / 回弹，300 步一轮，每一步都验几何不变量。
    func testChaos_randomOperationsKeepGeometrySound() {
        for seed in 1...5 {
            var rng = SeededRNG(seed: UInt64(seed) * 7919)
            let h = makeHarness()
            assertInvariants(h, "seed\(seed) 起始")

            for step in 0..<300 {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0:
                    // 自由滚动（含越界回弹）
                    let maxY = h.scroll.contentSize.height - viewport.height
                    let y = CGFloat.random(in: -200...(maxY + 200), using: &rng)
                    scrollAndNotify(h, to: y)
                case 1:
                    // 捏合缩放
                    h.zoom.value = CGFloat.random(in: 1...6, using: &rng)
                    refresh(h)
                case 2:
                    // 点缩略图跳页
                    h.page.value = Int.random(in: 0..<h.pageCount.value, using: &rng)
                    refresh(h)
                case 3:
                    if Int.random(in: 0..<2, using: &rng) == 0 {
                        // 增删页：逻辑尺寸变了，而缩放还停在放大状态（最容易踩 transform 的坑）
                        h.pageCount.value = Int.random(in: 1...40, using: &rng)
                        h.page.value = min(h.page.value, h.pageCount.value - 1)
                        refresh(h)
                    } else {
                        // 旋转 / 分屏：视口尺寸变化，fit 要重算
                        let w = CGFloat.random(in: 500...900, using: &rng)
                        let hgt = CGFloat.random(in: 500...1100, using: &rng)
                        h.container.frame = CGRect(origin: .zero, size: CGSize(width: w, height: hgt))
                        h.container.layoutIfNeeded()
                        refresh(h)
                    }
                    // 视口变了 fit 也变了，断言里用的视口要跟着换
                    break
                case 4:
                    // 滚动到位后连续刷新（模拟 SwiftUI 反复更新）
                    let maxY = h.scroll.contentSize.height - viewport.height
                    let y = CGFloat.random(in: 0...maxY, using: &rng)
                    scrollAndNotify(h, to: y)
                    let before = h.scroll.contentOffset
                    for _ in 0..<3 { refresh(h) }
                    XCTAssertEqual(h.scroll.contentOffset.y, before.y, accuracy: 1,
                                   "seed\(seed) step\(step): 刷新把滚动位置改了（\(before.y) → \(h.scroll.contentOffset.y)）")
                default:
                    // 缩放 + 跳页连招
                    h.zoom.value = CGFloat.random(in: 1...4, using: &rng)
                    h.page.value = Int.random(in: 0..<h.pageCount.value, using: &rng)
                    refresh(h)
                }
                assertInvariants(h, "seed\(seed) step\(step)")
            }
        }
    }

    // MARK: - 跨页墨迹

    func testCrossPageStroke_landsOnStartPageAndMergesBackIntact() {
        let h = makeHarness()

        // 一笔从第 0 页底部画进第 1 页
        let start = CGPoint(x: 120, y: pageSize.height - 120)
        let end = CGPoint(x: 640, y: pageSize.height + 120)
        var points: [PKStrokePoint] = []
        for i in 0...1 {
            let t = CGFloat(i)
            points.append(PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t,
                                                          y: start.y + (end.y - start.y) * t),
                                        timeOffset: Double(i) * 0.01,
                                        size: CGSize(width: 4, height: 4),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let global = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                                                  path: PKStrokePath(controlPoints: points, creationDate: Date()))])

        let split = InkComposer.split(global: global, pageHeight: pageSize.height, pageCount: pageCount)
        XCTAssertEqual(split[0]?.strokes.count, 1, "整笔应归属起笔页")
        XCTAssertEqual(split[1]?.strokes.count ?? 0, 0, "跨页笔迹不应被拆到下一页")

        // 归页后重新合并，必须回到原来那一笔（位置一致）
        var pageDrawings = [PKDrawing](repeating: PKDrawing(), count: pageCount)
        for (index, drawing) in split { pageDrawings[index] = drawing }
        let merged = InkComposer.merge(pageDrawings: pageDrawings, pageHeight: pageSize.height)
        XCTAssertEqual(merged.strokes.count, 1)
        XCTAssertEqual(merged.strokes.first?.path.first?.location.y ?? 0, start.y, accuracy: 0.5)
    }
}
