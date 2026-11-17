import SwiftUI
import PencilKit
import UIKit

/// 连续滚动模式的书写层：**整本笔记共用一块画布**。
///
/// 结构（只有一个滚动权威）：
/// ```
/// UIScrollView            ← 唯一负责滚动 + 缩放（原生 pinch / viewForZooming）
/// └─ contentView          ← 逻辑尺寸（页宽 × 页高×页数），随 scroll.zoomScale 整体缩放
///    ├─ host.view         ← 所有页无缝拼接的背景（纸张 / PDF / 图片 / 文字框）
///    └─ PKCanvasView      ← 整本笔记唯一的画布，逻辑尺寸，zoomScale 恒为 1
/// ```
///
/// 三个关键决定，都是为了消灭「频闪 / 滚动偏移 / 笔迹断层」：
///
/// 1. **画布和背景在同一个坐标系里**。两者都是逻辑尺寸、都是 contentView 的直接子视图，
///    由同一个 `zoomScale` 一起放大。不再需要把 `scroll.contentOffset` 抄给 `canvas.contentOffset`，
///    也就不存在两套坐标系半帧不同步导致的背景与墨迹错位、笔迹被切成两段。
/// 2. **画布的 `zoomScale` 恒为 1**。PencilKit 自身的缩放和外部 scroll 的缩放叠加时，
///    墨迹会被渲染两遍（分块重采样），在页内留下接缝。让画布永远是 1:1，缩放交给上层唯一一处。
/// 3. **不往 SwiftUI 回写缩放比例**。上一版把 `displayScale` 回传给背景做 `scaleEffect`，
///    每帧写 @State 都会重建整个 body（几十个 NotePageView），这就是频闪和卡顿的根源。
///    现在背景按逻辑尺寸排版，缩放完全由 UIKit 侧承担，SwiftUI 一次都不用刷新。
///
/// 因为只有一块画布，笔从页 A 底部划到页 B 顶部时是一条连续的笔画，
/// 抬笔后再由 `InkComposer.split` 按页边界归页落盘。
struct ContinuousInkCanvas<Background: View>: UIViewRepresentable {

    let pageSize: CGSize
    let pageCount: Int
    /// 全局坐标的墨迹（第 i 页原点在 y = i * pageHeight）
    let globalDrawing: PKDrawing
    let tool: PKTool
    /// 工具的稳定标识（PKTool 不支持相等比较，用它判断是否需要重设）
    let toolKey: String
    /// 是否允许书写（拖动模式 / 只读时关掉）
    let isDrawingEnabled: Bool
    /// 手指能否书写（关闭时 canvas 让手指穿透，交给 scroll 滚动）
    let fingerDrawing: Bool
    let shapeRecognition: Bool
    let isSourceEligibleForSnap: Bool

    /// 用户缩放倍率（1 = 适应宽度）
    @Binding var zoom: CGFloat
    /// 当前页（由滚动位置驱动）
    @Binding var currentPage: Int
    /// 墨迹变化（抬笔时上报一次）
    let onDrawingChange: (PKDrawing) -> Void

    let background: Background

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.backgroundColor = .clear
        context.coordinator.attach(to: view, background: AnyView(background))
        return view
    }

    func updateUIView(_ view: ContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncFromSwiftUI()
    }

    static func dismantleUIView(_ view: ContainerView, coordinator: Coordinator) {
        coordinator.flushNow()
    }

    // MARK: - 容器

    final class ContainerView: UIView {
        let scroll = UIScrollView()
        /// 缩放载体：背景和画布都挂在这里，随 scroll.zoomScale 一起变
        let contentView = UIView()
        let canvas = InkCanvasView()
        /// 首帧 bounds 还是 0，fit 会算成 0（内容被缩到看不见），必须等真实尺寸出来再补一次
        var onLayout: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true

            scroll.clipsToBounds = true
            scroll.showsVerticalScrollIndicator = true
            scroll.showsHorizontalScrollIndicator = false
            scroll.alwaysBounceVertical = true
            scroll.alwaysBounceHorizontal = false
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.backgroundColor = .clear
            // 缩放全部交给它自己，绝不叠加画布的 zoom
            scroll.bouncesZoom = false
            scroll.decelerationRate = .normal

            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.alwaysBounceVertical = false
            canvas.alwaysBounceHorizontal = false
            canvas.bounces = false
            // 画布永远 1:1，缩放由上层 contentView 承担
            canvas.minimumZoomScale = 1
            canvas.maximumZoomScale = 1
            canvas.zoomScale = 1

            addSubview(scroll)
            scroll.addSubview(contentView)
            contentView.addSubview(canvas)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 1, bounds.height > 1 else { return }
            if scroll.frame != bounds { scroll.frame = bounds }
            onLayout?()
        }
    }

    // MARK: - 画布（手指穿透）

    /// 只对 Apple Pencil 响应命中测试，手指事件穿透给下面的 scroll（滚动）
    /// 和背景层（点文字框 / 拖图片）。手指书写模式下则全部接收。
    final class InkCanvasView: PKCanvasView {
        var fingerDraws = false

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if !fingerDraws, let event {
                let hasPencil = event.allTouches?.contains { $0.type == .pencil } ?? false
                if !hasPencil { return nil }
            }
            return super.hitTest(point, with: event)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, PKCanvasViewDelegate {
        var parent: ContinuousInkCanvas
        private weak var container: ContainerView?
        private var host: UIHostingController<AnyView>?

        private var appliedToolKey: String = ""
        private var appliedPageSize: CGSize = .zero
        private var appliedPageCount: Int = 0
        /// 最近一次由我们写入的缩放倍率（1 = 适应宽度），避免回环
        private var appliedZoomLevel: CGFloat = 0
        /// 最近一次由代码驱动滚动（跳页），期间不要把偏移反算成页码
        private var isSyncing = false
        private var isPinching = false
        private var isApplyingDrawing = false
        private var pendingSave: DispatchWorkItem?
        /// 由滚动位置上报的页码（区分「用户滚动」与「外部跳页」）
        private var syncedPage: Int = 0

        init(_ parent: ContinuousInkCanvas) {
            self.parent = parent
        }

        func attach(to view: ContainerView, background: AnyView) {
            container = view
            let host = UIHostingController(rootView: background)
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            host.safeAreaRegions = []
            // UIHostingController 的视图默认走 Auto Layout，直接设 frame 会被约束系统改回去，
            // 背景就按 intrinsic size 渲染（页面宽度对不上）。改成手动 frame 布局。
            host.view.translatesAutoresizingMaskIntoConstraints = true
            host.view.autoresizingMask = []
            self.host = host
            view.contentView.insertSubview(host.view, at: 0)

            view.scroll.delegate = self
            view.canvas.delegate = self
            view.canvas.drawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
            view.canvas.tool = parent.tool
            view.canvas.fingerDraws = parent.fingerDrawing
            view.canvas.drawing = parent.globalDrawing
            view.canvas.drawingGestureRecognizer.isEnabled = parent.isDrawingEnabled
            applyFingerScrollRule(in: view)

            view.onLayout = { [weak self] in self?.handleLayout() }

            applyLogicalSize(view)
        }

        /// 手指书写模式下，单指要留给画布，滚动改由双指完成（与原生 App Store 一致）
        private func applyFingerScrollRule(in view: ContainerView) {
            view.scroll.panGestureRecognizer.minimumNumberOfTouches = parent.fingerDrawing ? 2 : 1
        }

        /// 视口尺寸确定（或发生变化）后重算缩放
        private func handleLayout() {
            guard let view = container, view.bounds.width > 1 else { return }
            applyLogicalSize(view)
            applyZoom(in: view, force: false)
        }


        // MARK: SwiftUI → UIKit

        func syncFromSwiftUI() {
            guard let view = container else { return }

            // 工具 / 可写状态
            if appliedToolKey != parent.toolKey {
                appliedToolKey = parent.toolKey
                view.canvas.tool = parent.tool
            }
            let canDraw = parent.isDrawingEnabled
            if view.canvas.drawingGestureRecognizer.isEnabled != canDraw {
                view.canvas.drawingGestureRecognizer.isEnabled = canDraw
            }
            if view.canvas.fingerDraws != parent.fingerDrawing {
                view.canvas.fingerDraws = parent.fingerDrawing
                view.canvas.drawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
                applyFingerScrollRule(in: view)
            }

            // 背景内容
            if let host { host.rootView = AnyView(parent.background) }

            applyLogicalSize(view)

            // 墨迹（只在外部主动替换时写回，避免打断正在写的这一笔）
            if !isWriting, view.canvas.drawing.dataRepresentation() != parent.globalDrawing.dataRepresentation() {
                isApplyingDrawing = true
                view.canvas.drawing = parent.globalDrawing
                isApplyingDrawing = false
            }

            // 缩放（外部档位变化时才动）
            applyZoom(in: view, force: false)

            // 外部改了当前页（点缩略图 / 翻页按钮）→ 滚过去
            if parent.currentPage != syncedPage {
                scrollToPage(parent.currentPage, in: view)
            }
        }

        // MARK: 尺寸

        private var pageHeight: CGFloat { max(parent.pageSize.height, 1) }
        private var pageWidth: CGFloat { max(parent.pageSize.width, 1) }

        private var logicalSize: CGSize {
            CGSize(width: pageWidth, height: pageHeight * CGFloat(max(parent.pageCount, 1)))
        }

        private func fitScale(in view: ContainerView) -> CGFloat {
            view.bounds.width / pageWidth
        }

        /// 页面逻辑尺寸 → 屏幕点 的实际比例
        private var currentScale: CGFloat {
            container.map { fitScale(in: $0) * min(max(parent.zoom, 1), 6) } ?? 1
        }

        private func clampZoomLevel(_ level: CGFloat) -> CGFloat {
            min(max(level, 1), 6)
        }

        private func applyLogicalSize(_ view: ContainerView) {
            let logical = logicalSize
            guard logical != appliedPageSize || parent.pageCount != appliedPageCount else { return }
            appliedPageSize = logical
            appliedPageCount = parent.pageCount

            // 关键：UIScrollView 是用 **transform** 放大 zoom 视图的。
            // 在带 transform 的视图上写 frame，UIKit 会反推出 bounds = frame / scale，
            // 内容尺寸就被莫名缩掉了（背景变小、墨迹错位、滚动范围乱跳）。
            // 所以改尺寸必须先摘掉 transform，写完再装回去。
            let transform = view.contentView.transform
            if transform != .identity { view.contentView.transform = .identity }
            view.contentView.bounds = CGRect(origin: .zero, size: logical)
            view.contentView.frame = CGRect(origin: .zero, size: logical)
            if transform != .identity { view.contentView.transform = transform }

            // 背景与画布是 contentView 的子视图，frame 在它的坐标空间里，不受 transform 影响
            host?.view.frame = CGRect(origin: .zero, size: logical)
            host?.view.setNeedsLayout()

            view.canvas.frame = CGRect(origin: .zero, size: logical)
            view.canvas.contentSize = logical
            view.canvas.contentOffset = .zero

            // UIScrollView 不会因为我们手改了 zoom 视图的尺寸就重算 contentSize，
            // 内容尺寸变了它仍然用旧值 —— 滚动范围会不对（滚不到底 / 滚过头）。这里显式同步。
            let scale = max(view.scroll.zoomScale, 0.0001)
            view.scroll.contentSize = CGSize(width: logical.width * scale, height: logical.height * scale)

            // 尺寸变了缩放比例也要重算（fit 依赖视口宽度，内容高度依赖页数）
            applyZoom(in: view, force: true)
        }

        /// 唯一的缩放入口：设置 scroll 的 zoomScale，背景与墨迹一起变。
        ///
        /// `force = false` 时只在外部档位真的变了才动手，
        /// 否则 layout 每帧回调都会重设 zoomScale，把 setContentOffset 打回原位（这就是「滚动被拽走」）。
        private func applyZoom(in view: ContainerView, force: Bool) {
            guard view.bounds.width > 1 else { return }
            let fit = fitScale(in: view)
            let level = clampZoomLevel(parent.zoom)
            let target = fit * level

            // 必须先放开区间再设 zoomScale，否则 1...1 的默认区间会把它夹回 1
            view.scroll.minimumZoomScale = fit
            view.scroll.maximumZoomScale = fit * 6

            // 正在双指捏合时不要去改 zoomScale，会跟原生缩放打架（手感变抖、跳帧）
            guard !isPinching || force else { return }

            // 视口变了 fit 就变，target 会跟着变；所以比的是最终的 zoomScale（夹到合法区间后），
            // 而不是只比档位 —— 否则旋转 / 分屏后缩放不会重新贴合宽度。
            let clamped = min(max(target, fit), fit * 6)
            guard force || abs(clamped - view.scroll.zoomScale) > 0.001 else { return }

            // 首次（appliedZoomLevel == 0）不做中心锚点还原：
            // 那时内容还在 (0,0)，一还原就会把页面顶部顶出视口，看起来像「一打开就自己滚了一下」
            let isFirstApply = appliedZoomLevel == 0
            let anchor = view.scroll.contentOffset
            let oldScale = view.scroll.zoomScale
            appliedZoomLevel = level

            view.scroll.zoomScale = clamped

            guard !isFirstApply, oldScale > 0.0001, view.scroll.zoomScale > 0.0001 else { return }
            // 用户缩放：保持视口中心对应的内容点不动，避免一下跳到左上角
            let ratio = view.scroll.zoomScale / oldScale
            let centered = CGPoint(x: (anchor.x + view.bounds.width / 2) * ratio - view.bounds.width / 2,
                                   y: (anchor.y + view.bounds.height / 2) * ratio - view.bounds.height / 2)
            view.scroll.contentOffset = clampOffset(centered, in: view)
        }

        private func clampOffset(_ offset: CGPoint, in view: ContainerView) -> CGPoint {
            let maxX = max(view.scroll.contentSize.width - view.bounds.width, 0)
            let maxY = max(view.scroll.contentSize.height - view.bounds.height, 0)
            return CGPoint(x: min(max(offset.x, 0), maxX), y: min(max(offset.y, 0), maxY))
        }

        private func scrollToPage(_ page: Int, in view: ContainerView, animated: Bool = true) {
            let targetY = CGFloat(page) * pageHeight * view.scroll.zoomScale
            let offset = clampOffset(CGPoint(x: view.scroll.contentOffset.x, y: targetY), in: view)
            syncedPage = page
            guard animated else {
                isSyncing = true
                view.scroll.setContentOffset(offset, animated: false)
                isSyncing = false
                reportPage(page)
                return
            }
            isSyncing = true
            view.scroll.setContentOffset(offset, animated: true)
            reportPage(page)
            // setContentOffset(animated:) 的滚动回调是异步的，等它落定再恢复页码上报
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.isSyncing = false
            }
        }

        /// 程序化跳页后把页码回写给 SwiftUI（底栏页码 / 缩略图高亮要跟着变）。
        /// 跳页期间 didScroll 被 isSyncing 挡住，不主动回写的话页码会停在旧值。
        private func reportPage(_ page: Int) {
            guard parent.currentPage != page else { return }
            DispatchQueue.main.async { [parent] in
                if parent.currentPage != page { parent.currentPage = page }
            }
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            container?.contentView
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isPinching = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isSyncing else { return }
            let unit = pageHeight * max(scrollView.zoomScale, 0.001)
            let raw = scrollView.contentOffset.y / unit
            let page = min(max(Int(raw.rounded()), 0), max(parent.pageCount - 1, 0))
            guard page != syncedPage else { return }
            syncedPage = page
            // 只在跨页时回写一次，避免每帧刷新整个 SwiftUI body（频闪的主要来源）
            if page != parent.currentPage {
                parent.currentPage = page
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isPinching = false
            guard let container else { return }
            let fit = fitScale(in: container)
            guard fit > 0.0001 else { return }
            let level = clampZoomLevel(scrollView.zoomScale / fit)
            appliedZoomLevel = level
            if abs(parent.zoom - level) > 0.005 {
                parent.zoom = level
            }
        }

        // MARK: PKCanvasViewDelegate

        private var isWriting = false

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isWriting = true
            // 笔落下的瞬间如果页面还在惯性滑行，笔迹会被「拉花」（纸在动、笔尖位置在变）。
            // 落笔即刹停，和纸笔的直觉一致。
            if let scroll = container?.scroll, scroll.isDecelerating {
                scroll.setContentOffset(scroll.contentOffset, animated: false)
            }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isWriting = false
            scheduleSave(canvasView.drawing)
        }

        /// 选中过程不落盘：整本笔记的墨迹切分一次要重建几百条笔迹，
        /// 每 0.2 秒跑一次会拖慢书写。抬笔（EndUsingTool）时保存一次就够，
        /// 中间丢失的也只是「还没抬笔的那一笔」，与 PencilKit 自身的语义一致。
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingDrawing else { return }
        }

        private func scheduleSave(_ drawing: PKDrawing) {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.parent.onDrawingChange(drawing)
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func flushNow() {
            pendingSave?.cancel()
            pendingSave = nil
            guard let container else { return }
            parent.onDrawingChange(container.canvas.drawing)
        }
    }
}
