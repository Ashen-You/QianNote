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
///    └─ PKCanvasView      ← 整本笔记唯一的画布，滑动窗口（可视区域附近约 3 屏），zoomScale 恒为 1
/// ```
///
/// 关键决定，都是为了消灭「频闪 / 实时笔迹不可见 / 滚动偏移 / 笔迹断层」：
///
/// 1. **画布和背景在同一个坐标系里**。两者都是 contentView 的直接子视图，
///    由同一个 `zoomScale` 一起放大；画布用 `frame.origin.y == contentOffset.y` 的滑动窗口
///    截取这段坐标系（见第 4 点），墨迹屏幕位置恒等于背景上的逻辑位置。
/// 2. **画布的 `zoomScale` 恒为 1**。PencilKit 自身的缩放和外部 scroll 的缩放叠加时，
///    墨迹会被渲染两遍（分块重采样），在页内留下接缝。让画布永远是 1:1，缩放交给上层唯一一处。
/// 3. **不往 SwiftUI 回写缩放比例**。上一版把 `displayScale` 回传给背景做 `scaleEffect`，
///    每帧写 @State 都会重建整个 body（几十个 NotePageView），这就是频闪和卡顿的根源。
///    现在背景按逻辑尺寸排版，缩放完全由 UIKit 侧承担，SwiftUI 一次都不用刷新。
/// 4. **画布 bounds 是滑动的窗口，不是整本高度**。12 页笔记整本高 12288pt（@2x = 24576px），
///    超过 Metal 单张纹理 16384px 上限；PencilKit 按 bounds 分配帧缓冲，分配失败后
///    实时笔迹层不存在（写字时看不到墨）、瓦片渲染错乱（旧笔迹闪没、点一下整块变白）。
///    窗口高度封顶 3072pt（@2x = 6144px），只在可视区域离开窗口时整体滑动。
///    contentSize 仍是整本尺寸，墨迹仍是全局坐标，跨页连续笔画与归页逻辑都不受影响。
///
/// 因为只有一块画布，笔从页 A 底部划到页 B 顶部时是一条连续的笔画，
/// 抬笔后再由 `InkComposer.split` 按页边界归页落盘。
struct ContinuousInkCanvas<Background: View>: UIViewRepresentable {

    let pageSize: CGSize
    let pageCount: Int
    /// 全局坐标的墨迹（第 i 页原点在 y = i * pageHeight）
    let globalDrawing: PKDrawing
    /// 外部替换整本墨迹的版本号（加载 / 页数变化时自增）。
    /// 用它判断是否要回写画布；每次刷新都序列化整本 drawing 做字节比较，
    /// 在长笔记里是实打实的主线程开销。
    let drawingRevision: Int
    let tool: PKTool
    /// 工具的稳定标识（PKTool 不支持相等比较，用它判断是否需要重设）
    let toolKey: String
    /// 是否允许书写（拖动模式 / 只读时关掉）
    let isDrawingEnabled: Bool
    /// 手指能否书写（true 时 drawingPolicy 为 .anyInput，单指也能落墨）
    let fingerDrawing: Bool
    /// 触摸是否整体穿透给下层（拖动 / 文字工具需要点背景）。
    /// 书写工具下必须由画布接手所有触摸，不能靠事件里的触摸类型去猜——
    /// 真机上 Pencil 事件到达 hitTest 时并不总是带着触摸信息，
    /// 一旦猜错，Pencil 就被当成手指放走，表现为「选了笔却既写不出也拖不动」。
    let passesFingersThrough: Bool
    let shapeRecognition: Bool
    let isSourceEligibleForSnap: Bool

    /// 用户缩放倍率（1 = 适应宽度）
    @Binding var zoom: CGFloat
    /// 当前页（由滚动位置驱动）
    @Binding var currentPage: Int
    /// 墨迹变化（抬笔时上报一次）
    let onDrawingChange: (PKDrawing) -> Void

    let background: Background
    /// 背景内容的版本号（笔记内容 / 工具变化才变）。
    /// 滚动翻页、缩放会高频触发 SwiftUI 刷新，这些刷新不该把整条页面背景重建一遍。
    let backgroundKey: Int

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
        /// 只在上一次通知后尺寸真的变了才回调，避免 layout → 改缩放 → 再 layout 的反馈循环
        private var lastLayoutSize: CGSize = .zero

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
            guard bounds.size != lastLayoutSize else { return }
            lastLayoutSize = bounds.size
            onLayout?()
        }
    }

    // MARK: - 画布（触摸归属）

    /// 书写工具下接收所有触摸：Pencil 一定能落笔；手指被 drawingPolicy 挡住不落墨，
    /// 滚动由外层 scroll 的 pan 手势负责（祖先手势不依赖命中测试）。
    /// 只有拖动 / 文字工具才整体穿透，让手指点背景、拖页面。
    final class InkCanvasView: PKCanvasView {
        var passesFingersThrough = false

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if passesFingersThrough { return nil }
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
        /// 最近一次写进画布的墨迹版本 / 背景版本
        private var appliedDrawingRevision = -1
        private var appliedBackgroundKey: Int?
        /// 最近一次由代码驱动滚动（跳页），期间不要把偏移反算成页码
        private var isSyncing = false
        private var isPinching = false
        private var isApplyingDrawing = false
        private var pendingSave: DispatchWorkItem?
        /// 由滚动位置上报的页码（区分「用户滚动」与「外部跳页」）
        private var syncedPage: Int = 0
        /// 画布窗口（contentView 逻辑坐标）。见 updateCanvasWindow
        private var canvasWindow: CGRect = .zero
        /// 书写中窗口冻结，离开窗口时记下来，抬笔后再滑
        private var needsCanvasWindowUpdate = false
        /// 窗口高度上限（逻辑点）：@2x 屏 6144px，离 Metal 单张纹理 16384px 上限很远
        private let maxCanvasWindowHeight: CGFloat = 3072

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
            appliedBackgroundKey = parent.backgroundKey

            view.scroll.delegate = self
            view.canvas.delegate = self
            view.canvas.drawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
            view.canvas.tool = parent.tool
            view.canvas.passesFingersThrough = parent.passesFingersThrough
            view.canvas.drawing = parent.globalDrawing
            appliedDrawingRevision = parent.drawingRevision
            view.canvas.drawingGestureRecognizer.isEnabled = parent.isDrawingEnabled
            applyScrollTouchRules(in: view)

            view.onLayout = { [weak self] in self?.handleLayout() }

            applyLogicalSize(view)
        }

        /// 手指书写模式下，单指要留给画布，滚动改由双指完成（与原生 App Store 一致）。
        /// 笔可书写时（拖动工具之外）滚动只认手指：UIScrollView 的平移手势默认
        /// 也接受 Apple Pencil，不排除的话 Pencil 一落纸就被滚动抢走，
        /// 表现为「不管选哪支笔都只能拖动页面、写不出字」。
        private func applyScrollTouchRules(in view: ContainerView) {
            let pan = view.scroll.panGestureRecognizer
            let minTouches = parent.fingerDrawing ? 2 : 1
            if pan.minimumNumberOfTouches != minTouches {
                pan.minimumNumberOfTouches = minTouches
            }
            let touchTypes: [NSNumber] = parent.isDrawingEnabled
                ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [NSNumber(value: UITouch.TouchType.direct.rawValue),
                   NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            if pan.allowedTouchTypes != touchTypes {
                pan.allowedTouchTypes = touchTypes
            }
        }

        /// 视口尺寸确定（或发生变化）后重算缩放
        private func handleLayout() {
            guard let view = container, view.bounds.width > 1 else { return }
            applyLogicalSize(view)
            applyZoom(in: view, force: false)
            updateCanvasWindow(in: view, force: false)
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
            let policy: PKCanvasViewDrawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
            if view.canvas.drawingPolicy != policy {
                view.canvas.drawingPolicy = policy
            }
            view.canvas.passesFingersThrough = parent.passesFingersThrough
            // 工具切换会同时改变「能否书写」与手指/笔的滚动归属
            applyScrollTouchRules(in: view)

            // 背景内容
            if let host, appliedBackgroundKey != parent.backgroundKey {
                appliedBackgroundKey = parent.backgroundKey
                host.rootView = AnyView(parent.background)
            }

            applyLogicalSize(view)

            // 墨迹（只在外部主动替换时写回，避免打断正在写的这一笔）
            if !isWriting, appliedDrawingRevision != parent.drawingRevision {
                appliedDrawingRevision = parent.drawingRevision
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

            // 外部替换整本墨迹可能扰动画布的 contentOffset，这里兜底对齐
            applyCanvasWindow(in: view)
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

            // 这是由布局/外部状态驱动的尺寸同步，期间产生的 scroll 回调不能反过来
            // 写 currentPage，否则会在一次布局里触发 SwiftUI 重算，形成反馈循环。
            let wasSyncing = isSyncing
            isSyncing = true
            defer { isSyncing = wasSyncing }

            // 关键：UIScrollView 是用 **transform** 放大 zoom 视图的。
            // 在带 transform 的视图上写 frame，UIKit 会反推出 bounds = frame / scale，
            // 内容尺寸就被莫名缩掉了（背景变小、墨迹错位、滚动范围乱跳）。
            // 所以改尺寸必须先摘掉 transform，写完再装回去。
            let transform = view.contentView.transform
            if transform != .identity { view.contentView.transform = .identity }
            view.contentView.bounds = CGRect(origin: .zero, size: logical)
            view.contentView.frame = CGRect(origin: .zero, size: logical)
            if transform != .identity { view.contentView.transform = transform }

            // 背景与画布是 contentView 的子视图，frame 在它的坐标空间里，不受 transform 影响。
            // 改 frame 本身就会标脏布局，不要再手动 setNeedsLayout —— 那会在
            // layoutSubviews 内部又请求一次布局，形成 observation 反馈循环。
            host?.view.frame = CGRect(origin: .zero, size: logical)

            // 画布的 contentSize 仍是整本尺寸（墨迹用全局坐标），
            // 但 bounds 只是可视区域附近的滑动窗口（见 updateCanvasWindow）
            view.canvas.contentSize = logical

            // UIScrollView 不会因为我们手改了 zoom 视图的尺寸就重算 contentSize，
            // 内容尺寸变了它仍然用旧值 —— 滚动范围会不对（滚不到底 / 滚过头）。这里显式同步。
            let scale = max(view.scroll.zoomScale, 0.0001)
            view.scroll.contentSize = CGSize(width: logical.width * scale, height: logical.height * scale)

            // 尺寸变了缩放比例也要重算（fit 依赖视口宽度，内容高度依赖页数）
            applyZoom(in: view, force: true)
            updateCanvasWindow(in: view, force: true)
        }

        /// 把画布收窄成「可视区域附近的一段」，随滚动滑动。
        ///
        /// PencilKit 按画布 bounds 分配 Metal 帧缓冲。若 bounds 等于整本高度
        /// （12 页 × 1024pt = 12288pt，@2x = 24576px），超出单张纹理 16384px 上限，
        /// 帧缓冲分配失败 —— 实时笔迹层消失（写字时看不到笔迹）、瓦片渲染错乱
        /// （旧笔迹闪一下消失、点一下整块变白）。窗口高度封顶 3072pt 就永远不会触顶。
        ///
        /// 坐标系不变：contentSize 仍是整本，墨迹仍是全局坐标。只要
        /// `frame.origin.y == contentOffset.y == 窗口原点`，画布局部坐标 y 映射回内容坐标
        /// 恰好是 y（frame.origin + (y − contentOffset)），墨迹与背景始终严丝合缝。
        private func updateCanvasWindow(in view: ContainerView, force: Bool) {
            let logical = logicalSize
            let scale = max(view.scroll.zoomScale, 0.0001)
            let visibleHeight = min(view.bounds.height / scale, logical.height)
            guard visibleHeight > 0.5 else { return }
            let visibleTop = min(max(view.scroll.contentOffset.y / scale, 0),
                                 max(logical.height - visibleHeight, 0))
            let visible = CGRect(x: 0, y: visibleTop, width: logical.width, height: visibleHeight)

            // 高度与原点都取整点：PKCanvasView 会把非整数 contentOffset 取整，
            // 若 frame.origin 带小数，两者就会差零点几 pt —— 墨迹相对背景微移。
            let height = min(logical.height,
                             max(pageHeight, min(visibleHeight * 3, maxCanvasWindowHeight))).rounded()
            let contained = canvasWindow.height > 0
                && abs(canvasWindow.height - height) <= 0.5
                && canvasWindow.minY <= visible.minY + 0.5
                && canvasWindow.maxY >= visible.maxY - 0.5
            // 窗口还盖得住可视区域就不动：滑动会触发整块瓦片重绘
            if !force && contained { return }
            // 书写中不能挪画布，抬笔后再补（挪动本身不会丢墨，但会打断这一笔的渲染）
            if isWriting && !force {
                needsCanvasWindowUpdate = true
                return
            }
            needsCanvasWindowUpdate = false

            let centered = (visible.midY - height / 2).rounded()
            let maxOriginY = max((logical.height - height).rounded(.down), 0)
            let originY = min(max(centered, 0), maxOriginY)
            canvasWindow = CGRect(x: 0, y: originY, width: logical.width, height: height)
            applyCanvasWindow(in: view)
        }

        /// 把窗口写进画布。frame 和 contentOffset 必须是同一个值，
        /// 否则墨迹会相对背景错位（旧版闪动的来源就是两套坐标系不同步）。
        private func applyCanvasWindow(in view: ContainerView) {
            guard canvasWindow.height > 0 else { return }
            let logical = logicalSize
            if view.canvas.contentSize != logical { view.canvas.contentSize = logical }
            if view.canvas.frame != canvasWindow { view.canvas.frame = canvasWindow }
            if abs(view.canvas.contentOffset.y - canvasWindow.minY) > 0.01 {
                view.canvas.contentOffset = CGPoint(x: 0, y: canvasWindow.minY)
            }
        }

        /// 唯一的缩放入口：设置 scroll 的 zoomScale，背景与墨迹一起变。
        ///
        /// `force = false` 时只在外部档位真的变了才动手，
        /// 否则 layout 每帧回调都会重设 zoomScale，把 setContentOffset 打回原位（这就是「滚动被拽走」）。
        private func applyZoom(in view: ContainerView, force: Bool) {
            guard view.bounds.width > 1 else { return }
            // 缩放是程序化变更，期间不要从 scrollViewDidScroll 反写页码
            let wasSyncing = isSyncing
            isSyncing = true
            defer { isSyncing = wasSyncing }
            let fit = fitScale(in: view)
            let level = clampZoomLevel(parent.zoom)
            let target = fit * level

            // 必须先放开区间再设 zoomScale，否则 1...1 的默认区间会把它夹回 1。
            // 值没变就不要重复写，否则每次 SwiftUI 刷新都可能再触发一轮布局。
            if view.scroll.minimumZoomScale != fit { view.scroll.minimumZoomScale = fit }
            let maxScale = fit * 6
            if view.scroll.maximumZoomScale != maxScale { view.scroll.maximumZoomScale = maxScale }

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

            if !isFirstApply, oldScale > 0.0001, view.scroll.zoomScale > 0.0001 {
                // 用户缩放：保持视口中心对应的内容点不动，避免一下跳到左上角
                let ratio = view.scroll.zoomScale / oldScale
                let centered = CGPoint(x: (anchor.x + view.bounds.width / 2) * ratio - view.bounds.width / 2,
                                       y: (anchor.y + view.bounds.height / 2) * ratio - view.bounds.height / 2)
                view.scroll.contentOffset = clampOffset(centered, in: view)
            }
            // 缩放改变可视高度，窗口高度也要跟着变
            updateCanvasWindow(in: view, force: false)
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
            guard let container, scrollView === container.scroll else { return nil }
            return container.contentView
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            guard let container, scrollView === container.scroll else { return }
            isPinching = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 画布自己的 contentOffset 变化（窗口滑动）也会走到这里，不能混为一谈
            guard let container, scrollView === container.scroll else { return }
            // 可视区域挪出窗口就滑窗口（跳页的动画滚动也要跟），书写期间冻结
            if !isPinching {
                updateCanvasWindow(in: container, force: false)
            }
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
            guard let container, scrollView === container.scroll else { return }
            isPinching = false
            let fit = fitScale(in: container)
            guard fit > 0.0001 else { return }
            let level = clampZoomLevel(scrollView.zoomScale / fit)
            appliedZoomLevel = level
            if abs(parent.zoom - level) > 0.005 {
                parent.zoom = level
            }
            updateCanvasWindow(in: container, force: false)
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
            // 书写期间可视区域挪出了窗口，抬笔后补滑（否则墨迹可能落在窗口外看不到）
            if needsCanvasWindowUpdate, let container {
                updateCanvasWindow(in: container, force: true)
            }
            scheduleSave()
        }

        /// 选中过程不落盘：整本笔记的墨迹切分一次要重建几百条笔迹，
        /// 每 0.2 秒跑一次会拖慢书写。抬笔（EndUsingTool）时保存一次就够。
        ///
        /// 但 PencilKit 不是「抬笔即提交」：`DidEndUsingTool` 时 drawing 里往往还没有这一笔，
        /// 十毫秒后才通过 `DrawingDidChange` 补进来。所以除了抬笔，这里也要在
        /// 非书写状态下的变更里补一次保存——只靠抬笔那条路会把刚提交的笔画漏掉。
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingDrawing, !isWriting else { return }
            scheduleSave()
        }

        /// 防抖保存。**必须在此刻重新读画布**，不能捕获抬笔时的快照：
        /// 快照可能还是空画布，回写给 SwiftUI 后 `syncFromSwiftUI` 又会把它盖回画布，
        /// 刚写的那一笔就被自己擦掉了。
        private func scheduleSave() {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let canvas = self.container?.canvas else { return }
                // 防抖窗口里又落笔了：等这一笔抬完再统一保存
                if self.isWriting {
                    self.scheduleSave()
                    return
                }
                self.parent.onDrawingChange(canvas.drawing)
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
