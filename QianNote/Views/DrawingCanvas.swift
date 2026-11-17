import SwiftUI
import PencilKit
import UIKit
import Combine

// MARK: - 画布控制器（撤销 / 重做 / 恢复）

final class CanvasController: NSObject, ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var currentDrawing = PKDrawing()
    weak var canvas: PKCanvasView?
    var onDrawingRestored: ((PKDrawing) -> Void)?

    /// 系统 UndoManager（由 Pool 在切页时注入）。
    /// 让三指滑动 / 摇一摇 / 外接键盘 ⌘Z 与工具栏按钮走同一套自研撤销栈。
    weak var systemUndoManager: UndoManager?

    private var undoStack: [PKDrawing] = []
    private var redoStack: [PKDrawing] = []
    private let limit = 60

    /// 当前可撤销的步数：多点手势开始时记下，手势结束后把误触产生的撤销步丢掉
    var historyDepth: Int { undoStack.count }

    func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        systemUndoManager?.removeAllActions()
        updateFlags()
    }

    /// 清空当前页：把画布墨迹真正抹掉，但把「清空前的内容」记为一步可撤销的操作，
    /// 用户误点清空后仍可三指 / ⌘Z / 工具栏撤销恢复。
    /// 通过 onDrawingRestored 回调走 Coordinator 的 applyProgrammatic，
    /// 由它把空 drawing 应用到 PKCanvasView 并落盘。
    func clearCanvas() {
        let previous = currentDrawing
        // 已经是空页就没有可清的内容，也不该多出一条无意义的撤销步
        guard !isSame(previous, PKDrawing()) else { return }
        record(previous: previous, current: PKDrawing())
        onDrawingRestored?(PKDrawing())
    }

    /// 丢弃 depth 之后的撤销步（用于「两指点击」时手指误落在画布上留下的笔迹）
    func truncateHistory(to depth: Int) {
        guard depth >= 0, depth < undoStack.count else { return }
        undoStack.removeLast(undoStack.count - depth)
        updateFlags()
        rebuildSystemUndo()
    }

    func record(previous: PKDrawing, current: PKDrawing) {
        guard !isSame(previous, current) else {
            currentDrawing = current
            return
        }
        undoStack.append(previous)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
        currentDrawing = current
        updateFlags()
        registerSystemUndo()
    }

    /// 撤销：有系统 undoManager 时经由它触发（统一三指 / ⌘Z / 工具栏入口），
    /// 否则直接走自研栈（单元测试、未注入 undoManager 的场景）。
    func undo() {
        if let um = systemUndoManager, um.canUndo {
            um.undo()
        } else {
            rawUndo()
        }
    }

    func redo() {
        if let um = systemUndoManager, um.canRedo {
            um.redo()
        } else {
            rawRedo()
        }
    }

    /// 外部（套索改色 / 删除 / 复制）修改笔迹：记为一步撤销并同步回画布
    func applyEdit(_ updated: PKDrawing) {
        let previous = currentDrawing
        record(previous: previous, current: updated)
        onDrawingRestored?(updated)
    }

    // MARK: - 自研栈的原始操作（不碰系统 undoManager）

    private func rawUndo() {
        guard let target = undoStack.popLast() else { return }
        redoStack.append(currentDrawing)
        restore(target)
    }

    private func rawRedo() {
        guard let target = redoStack.popLast() else { return }
        undoStack.append(currentDrawing)
        restore(target)
    }

    private func restore(_ drawing: PKDrawing) {
        currentDrawing = drawing
        onDrawingRestored?(drawing)
        updateFlags()
    }

    private func updateFlags() {
        let undoAvailable = !undoStack.isEmpty
        let redoAvailable = !redoStack.isEmpty
        if canUndo != undoAvailable { canUndo = undoAvailable }
        if canRedo != redoAvailable { canRedo = redoAvailable }
    }

    // MARK: - 系统 UndoManager 桥接

    /// 每写一笔，向系统 undoManager 追加一个「撤销」动作。
    /// 系统 undo/redo 与自研栈通过「反向注册」互相衔接，天然自平衡，无需手动重建。
    private func registerSystemUndo() {
        guard let um = systemUndoManager else { return }
        um.registerUndo(withTarget: self) { [weak self] target in
            target.undoFromSystem()
        }
        um.setActionName("写字")
    }

    /// 切页 / 截断历史后，按当前自研栈深度重建系统撤销动作列表。
    /// 只在非撤销进行中调用（`activate`、`truncateHistory` 都是用户主动操作），
    /// 所以可以安全地 `removeAllActions` 再逐层注册。
    /// 注意：UndoManager 会把同一个 runloop 事件里对同一 target 的多次 registerUndo
    /// 折叠成一层，所以这里把每一层放到独立的 runloop turn 里注册，保证层数与自研栈一致。
    func rebuildSystemUndo() {
        guard let um = systemUndoManager else { return }
        um.removeAllActions(withTarget: self)
        var remaining = undoStack.count
        func registerOneLevel() {
            guard remaining > 0 else { return }
            remaining -= 1
            um.registerUndo(withTarget: self) { [weak self] target in
                target.undoFromSystem()
            }
            DispatchQueue.main.async { registerOneLevel() }
        }
        registerOneLevel()
    }

    /// 系统（三指 / ⌘Z / 菜单）发起的撤销：
    /// 此刻 UndoManager 正在撤销，`registerUndo` 会落到 redo 栈，正好注册「重做」反向动作。
    @objc func undoFromSystem() {
        if let um = systemUndoManager {
            um.registerUndo(withTarget: self) { [weak self] target in
                target.redoFromSystem()
            }
        }
        rawUndo()
    }

    /// 系统发起的重做：反向注册「撤销」动作，再前进一步。
    @objc func redoFromSystem() {
        if let um = systemUndoManager {
            um.registerUndo(withTarget: self) { [weak self] target in
                target.undoFromSystem()
            }
        }
        rawRedo()
    }

    /// 便宜的相等判断：先比较笔画数量，再比较二进制数据
    private func isSame(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
        guard lhs.strokes.count == rhs.strokes.count else { return false }
        return lhs.dataRepresentation() == rhs.dataRepresentation()
    }
}

// MARK: - 每页一个撤销栈（连续滚动模式下多页同时存在）

final class CanvasControllerPool: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var activePageID: UUID?

    /// 系统 UndoManager（由 EditorView 从环境注入）。
    /// 三指滑动 / 摇一摇 / ⌘Z 都作用在这一个 undoManager 上，
    /// 切页时它跟着切换绑定到「当前页」的撤销栈。
    var systemUndoManager: UndoManager?

    private var controllers: [UUID: CanvasController] = [:]
    private var observers: [UUID: AnyCancellable] = [:]

    func controller(for pageID: UUID) -> CanvasController {
        if let existing = controllers[pageID] { return existing }

        let controller = CanvasController()
        controllers[pageID] = controller
        observers[pageID] = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.activePageID == pageID else { return }
                DispatchQueue.main.async { self.refreshFlags() }
            }
        return controller
    }

    func activate(_ pageID: UUID) {
        guard activePageID != pageID else {
            refreshFlags()
            return
        }
        activePageID = pageID
        // 切页：把系统 undoManager 重新绑定到新页的撤销栈，
        // 并清掉旧页残留的系统撤销动作，避免 ⌘Z 串页。
        let controller = controller(for: pageID)   // 确保该页的撤销栈已存在
        bindSystemUndo(controller)
        refreshFlags()
    }

    /// 把系统 undoManager 绑定到某一页的撤销栈。
    /// 系统 undo 历史是线性的，跨页不能混用，所以每次切页都清空重建。
    private func bindSystemUndo(_ controller: CanvasController) {
        controller.systemUndoManager = systemUndoManager
        // 旧页的撤销动作挂在旧页 controller 上，`removeAllActions(withTarget:)` 清不掉，
        // 必须先全局清空，再按新页自研栈重建。
        systemUndoManager?.removeAllActions()
        controller.rebuildSystemUndo()
    }

    @discardableResult
    func undo(pageID: UUID? = nil) -> Bool {
        guard let id = pageID ?? activePageID else { return false }
        // 手势可能在「非当前页」上触发（连续滚动），先切到该页让顶栏按钮状态跟着变
        activate(id)
        guard let controller = controllers[id], controller.canUndo else {
            refreshFlags()
            return false
        }
        controller.undo()
        refreshFlags()
        return true
    }

    @discardableResult
    func redo(pageID: UUID? = nil) -> Bool {
        guard let id = pageID ?? activePageID else { return false }
        activate(id)
        guard let controller = controllers[id], controller.canRedo else {
            refreshFlags()
            return false
        }
        controller.redo()
        refreshFlags()
        return true
    }

    private func refreshFlags() {
        guard let id = activePageID, let controller = controllers[id] else {
            if canUndo { canUndo = false }
            if canRedo { canRedo = false }
            return
        }
        if canUndo != controller.canUndo { canUndo = controller.canUndo }
        if canRedo != controller.canRedo { canRedo = controller.canRedo }
    }
}

// MARK: - 会汇报触点的画布

/// PKCanvasView 本身不暴露触点位置，这里子类化后再交给父类处理，
/// 用于「放大书写时页面跟随笔尖自动平移」，以及记录多点手势的起点。
final class TrackingCanvasView: PKCanvasView {
    var onTouch: ((CGPoint) -> Void)?
    /// 第二根手指落下的瞬间回调（此时画布还没被 PencilKit 写入任何东西）
    var onMultiTouchDown: (() -> Void)?

    private var didReportMultiTouch = false

    /// 首帧尺寸还没量出来时暂存的墨迹。
    /// PencilKit 拿到 drawing 就会按当前 bounds 建帧缓冲，0×0 的画布会让它在
    /// `MTLTextureDescriptorInternal validateWithDevice:` 上断言崩溃
    ///（崩溃栈在 com.apple.pencilkit.renderer），所以尺寸合法之前先不交给它。
    private var pendingDrawing: PKDrawing?

    override func layoutSubviews() {
        super.layoutSubviews()
        pinViewport()
        applyPendingDrawingIfPossible()
    }

    /// 尺寸合法时才写入墨迹；不合法就留到下一次 layout 再试
    func setDrawingWhenReady(_ drawing: PKDrawing) {
        pendingDrawing = drawing
        applyPendingDrawingIfPossible()
    }

    private func applyPendingDrawingIfPossible() {
        guard let pending = pendingDrawing,
              bounds.width >= 1, bounds.height >= 1,
              bounds.width.isFinite, bounds.height.isFinite else { return }
        pendingDrawing = nil
        self.drawing = pending
    }

    /// PKCanvasView 是 UIScrollView：墨迹画出原本边界后它会自己撑大 contentSize，
    /// contentOffset 一旦不是 0，整个墨迹层就会相对页面平移——纸张是 SwiftUI 画的、
    /// 墨迹是 UIKit 画的，两者错位后看起来就是「笔迹被一条竖线切掉了」。
    /// 关掉滚动时把视口钉死在 bounds 上，保证墨迹坐标和页面坐标永远一致。
    func pinViewport() {
        guard !isScrollEnabled else { return }
        // bounds 还是 .zero 时不要动 contentSize：那等于告诉 PencilKit「画布是 0×0」
        guard bounds.width >= 1, bounds.height >= 1,
              bounds.width.isFinite, bounds.height.isFinite else { return }
        if contentSize != bounds.size { contentSize = bounds.size }
        if contentOffset != .zero { contentOffset = .zero }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 只数手指：拿 Pencil 写的时候手掌/手指常压在上面，
        // 把 Pencil 也数进去会误判成「两指手势」，进而在抬笔时误撤销。
        let directCount = max(touches.filter { $0.type == .direct }.count,
                              (event?.allTouches ?? []).filter { $0.type == .direct }.count)
        if directCount >= 2, !didReportMultiTouch {
            didReportMultiTouch = true
            onMultiTouchDown?()
        }
        super.touchesBegan(touches, with: event)
        if let point = touches.first?.location(in: self) { onTouch?(point) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if let point = touches.first?.location(in: self) { onTouch?(point) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        resetMultiTouchIfIdle(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        resetMultiTouchIfIdle(event)
    }

    private func resetMultiTouchIfIdle(_ event: UIEvent?) {
        let active = event?.allTouches?.filter {
            $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
        } ?? []
        if active.isEmpty { didReportMultiTouch = false }
    }
}

// MARK: - SwiftUI 包装

struct DrawingCanvas: UIViewRepresentable {
    let pageID: UUID
    let initialDrawing: PKDrawing
    let tool: PKTool
    let toolKey: String
    let fingerDrawing: Bool
    let isEnabled: Bool
    let controller: CanvasController
    let onChange: (PKDrawing) -> Void

    /// 双指捏合（增量倍率，归一化焦点 0...1）
    var onPinch: ((CGFloat, CGPoint) -> Void)? = nil
    /// 双指拖动（增量位移）
    var onPan: ((CGSize) -> Void)? = nil
    /// 双击（归一化位置）
    var onDoubleTap: ((CGPoint) -> Void)? = nil
    /// Apple Pencil 笔杆双击
    var onPencilDoubleTap: (() -> Void)? = nil
    /// 是否启用形状识别（画圆/方/三角/直线后自动规整）
    var shapeRecognition: Bool = false
    /// 当前工具是否适合形状识别（钢笔 / 铅笔）
    var isShapeEligible: Bool = false
    /// 书写中触点位置（归一化 0...1），用于放大书写时自动跟手
    var onPenMove: ((CGPoint) -> Void)? = nil
    /// 虚线笔：落笔结束后把整笔切成虚线段
    var isDashed: Bool = false
    var dashWidth: CGFloat = 3
    /// 一笔结束（参数为当前页笔画总数），用于录音时间轴
    var onStrokeCommitted: ((Int) -> Void)? = nil
    /// 两指点击 → 撤销（Notability 惯例，不拿笔也能用）
    var onUndoTap: (() -> Void)? = nil
    /// 三指点击 → 重做
    var onRedoTap: (() -> Void)? = nil
    /// 拖动模式（关闭「手指书写」后启用）：进入后是**纯导航**，
    /// 手指和 Apple Pencil 都只拖动页面，谁都不写字。
    /// 之前只把 drawingPolicy 设成 .pencilOnly，结果 Pencil 照样落笔，
    /// 用户以为进了拖动模式就写不了字，实际是「手指写不了、笔还在写」，两种输入行为不一致。
    var fingerPans: Bool = false
    var onFingerPan: ((CGSize) -> Void)? = nil
    var onFingerPanEnd: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = TrackingCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        // 拖动模式是纯导航：连 Pencil 的绘制手势都关掉，两种输入都只拖不写
        canvas.drawingGestureRecognizer.isEnabled = !fingerPans
        canvas.tool = tool
        // 首帧 bounds 还是 0，先寄存，等 layoutSubviews 量出尺寸再交给 PencilKit
        canvas.setDrawingWhenReady(initialDrawing)

        let coordinator = context.coordinator
        // 关键：没有 delegate 就不会有 canvasViewDrawingDidChange，
        // 撤销栈、自动保存、形状识别、虚线切分、录音笔迹打点全部不会触发
        canvas.delegate = coordinator
        coordinator.canvas = canvas
        coordinator.currentPageID = pageID
        coordinator.toolKey = toolKey
        coordinator.isDashed = isDashed

        controller.currentDrawing = initialDrawing
        coordinator.ownerSave = onChange
        coordinator.bind(controller: controller, to: canvas)

        coordinator.installGestures(on: canvas)
        coordinator.trackingCanvas = canvas
        coordinator.trackingCanvas?.onTouch = { [weak coordinator] point in
            guard let coordinator, let canvas = coordinator.trackingCanvas else { return }
            coordinator.parent.onPenMove?(coordinator.normalize(point, in: canvas))
        }
        coordinator.trackingCanvas?.onMultiTouchDown = { [weak coordinator] in
            coordinator?.beginMultiTouchGesture()
        }

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.canvas = canvas

        if coordinator.currentPageID != pageID {
            // 换页前先把当前墨迹落盘。之前这里直接换成新页的 drawing 且 notify=false，
            // 旧页最后 0.25 秒的笔迹既没保存、也没留在画布上，表现就是「写好的字少一截」。
            coordinator.flushCurrentDrawing()
            // 落盘之后才把「这份墨迹属于哪一页」改成新页。
            // 顺序反了的话，旧页的这一笔会被存进新页的文件里，两页开始互相串墨迹。
            coordinator.ownerSave = onChange
            coordinator.currentPageID = pageID
            coordinator.toolKey = toolKey
            coordinator.cancelPendingSnap()
            coordinator.bind(controller: controller, to: canvas)
            controller.currentDrawing = initialDrawing
            controller.resetHistory()
            coordinator.applyProgrammatic(initialDrawing, notify: false)
        }

        if coordinator.toolKey != toolKey {
            coordinator.toolKey = toolKey
            canvas.tool = tool
        }
        coordinator.isDashed = isDashed

        let policy: PKCanvasViewDrawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if coordinator.drawingPolicy != policy {
            coordinator.drawingPolicy = policy
            canvas.drawingPolicy = policy
        }

        // 拖动模式：把 PencilKit 的绘制手势整个停掉（Pencil 也不再落笔），
        // 只留下我们自己的平移手势。删掉这行的话，手拖模式里 Pencil 照样写字，
        // 手指拖、笔写，两种输入的行为就对不上了。
        if canvas.drawingGestureRecognizer.isEnabled == fingerPans {
            canvas.drawingGestureRecognizer.isEnabled = !fingerPans
        }

        if coordinator.isEnabled != isEnabled {
            coordinator.isEnabled = isEnabled
            canvas.isUserInteractionEnabled = isEnabled
        }

        // 手写模式（单指书写）下双击会被误判，只保留双指手势
        coordinator.doubleTap?.isEnabled = !fingerDrawing
        coordinator.fingerPan?.isEnabled = fingerPans
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        // 画布被回收（换页、切连续滚动、视图重建）时把最后一笔落盘，
        // 否则最后 0.25 秒的墨迹会凭空消失，看起来就像「写到一半被截断」
        coordinator.cancelPendingSnap()
        coordinator.flushCurrentDrawing()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: DrawingCanvas
        weak var canvas: PKCanvasView?
        var currentPageID: UUID?
        /// 画布上这份墨迹属于哪一页 —— 落盘该用的那个闭包。
        /// 换页时 `parent` 会先被换成新页，若直接用 `parent.onChange` 落盘，
        /// 旧页的最后一笔就会写进新页的文件，两页开始互相串墨迹。
        var ownerSave: ((PKDrawing) -> Void)?
        /// 当前和这块画布绑定的那一页的撤销栈，换页时要把旧的控制器的画布引用解绑
        private weak var boundController: CanvasController?
        var toolKey: String = ""
        var drawingPolicy: PKCanvasViewDrawingPolicy = .default
        var isEnabled: Bool = true
        var isDashed: Bool = false
        private var isProgrammatic = false
        private var strokesBeforeTool = 0
        private var drawingBeforeTool: PKDrawing?
        private var isUsingTool = false
        private var pendingSave: DispatchWorkItem?
        /// 书写途中被拦下的「替换整个 drawing」请求，抬笔后再执行
        private var pendingProgrammatic: (PKDrawing, Bool)?

        private var lastScale: CGFloat = 1
        private var lastTranslation: CGPoint = .zero
        private var pendingSnap: DispatchWorkItem?
        var doubleTap: UITapGestureRecognizer?
        var fingerPan: UIPanGestureRecognizer?
        weak var trackingCanvas: TrackingCanvasView?

        /// 多点手势开始时的撤销栈深度与笔画数，用于清掉手指误落在画布上的笔迹
        private var gestureMark: Int?
        private var gestureBaseline: Int?
        private var gestureStartedAt: Date?

        init(_ parent: DrawingCanvas) {
            self.parent = parent
            self.drawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
            self.isEnabled = parent.isEnabled
        }

        func cancelPendingSnap() {
            pendingSnap?.cancel()
            pendingSnap = nil
        }

        /// 把某一页的撤销栈绑到这块画布上。
        /// 旧页必须解绑，否则它的撤销 / 改色会把旧页的墨迹 `applyProgrammatic` 到当前页的画布上。
        func bind(controller newController: CanvasController, to canvas: PKCanvasView) {
            if let old = boundController, old !== newController {
                old.canvas = nil
                old.onDrawingRestored = nil
            }
            boundController = newController
            newController.canvas = canvas
            newController.onDrawingRestored = { [weak self] drawing in
                self?.applyProgrammatic(drawing)
            }
        }

        /// 落盘到「这份墨迹真正属于的那一页」，而不是当前正在显示的页
        private func saveToOwner(_ drawing: PKDrawing) {
            (ownerSave ?? parent.onChange)(drawing)
        }

        // MARK: 双指手势（不抢占单指书写）

        func installGestures(on canvas: PKCanvasView) {            canvas.isScrollEnabled = false   // 交给外层变换层统一控制

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            pinch.cancelsTouchesInView = true
            canvas.addGestureRecognizer(pinch)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            pan.cancelsTouchesInView = true
            canvas.addGestureRecognizer(pan)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            tap.numberOfTapsRequired = 2
            tap.delegate = self
            tap.cancelsTouchesInView = true
            tap.isEnabled = !parent.fingerDrawing
            canvas.addGestureRecognizer(tap)
            self.doubleTap = tap

            // 单指拖动页面：只在「手指=拖动」时启用，避免抢走指写。
            // 触摸类型带上 pencil —— 拖动模式里 Pencil 也是拖动，不然笔放上去既写不了也不动，整块画布像死了一样
            let fingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleFingerPan(_:)))
            fingerPan.minimumNumberOfTouches = 1
            fingerPan.maximumNumberOfTouches = 1
            fingerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                           NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            fingerPan.delegate = self
            fingerPan.cancelsTouchesInView = true
            fingerPan.isEnabled = parent.fingerPans
            canvas.addGestureRecognizer(fingerPan)
            self.fingerPan = fingerPan

            // 两指点击 = 撤销，三指点击 = 重做（照 Notability 的手势，不拿笔也能用）
            let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap(_:)))
            undoTap.numberOfTouchesRequired = 2
            undoTap.delegate = self
            undoTap.cancelsTouchesInView = true
            undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            canvas.addGestureRecognizer(undoTap)

            let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap(_:)))
            redoTap.numberOfTouchesRequired = 3
            redoTap.delegate = self
            redoTap.cancelsTouchesInView = true
            redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            canvas.addGestureRecognizer(redoTap)

            let pencil = UIPencilInteraction()
            pencil.delegate = self
            canvas.addInteraction(pencil)
        }

        // MARK: Apple Pencil 双击

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            parent.onPencilDoubleTap?()
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let canvas, let onPinch = parent.onPinch else { return }
            switch gesture.state {
            case .began:
                lastScale = 1
            case .changed:
                let delta = gesture.scale / max(lastScale, 0.0001)
                lastScale = gesture.scale
                onPinch(delta, normalizedLocation(gesture.location(in: canvas), in: canvas))
            default:
                lastScale = 1
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let canvas, let onPan = parent.onPan else { return }
            switch gesture.state {
            case .began:
                lastTranslation = .zero
            case .changed:
                let current = gesture.translation(in: canvas)
                let delta = CGSize(width: current.x - lastTranslation.x,
                                   height: current.y - lastTranslation.y)
                lastTranslation = current
                onPan(delta)
            default:
                lastTranslation = .zero
            }
        }

        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let canvas, let onDoubleTap = parent.onDoubleTap else { return }
            onDoubleTap(normalizedLocation(gesture.location(in: canvas), in: canvas))
        }

        // MARK: 单指拖动页面

        @objc private func handleFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let canvas else { return }
            switch gesture.state {
            case .began:
                lastTranslation = .zero
            case .changed:
                let current = gesture.translation(in: canvas)
                let delta = CGSize(width: current.x - lastTranslation.x,
                                   height: current.y - lastTranslation.y)
                lastTranslation = current
                parent.onFingerPan?(delta)
            default:
                lastTranslation = .zero
                parent.onFingerPanEnd?()
            }
        }

        // MARK: 两指撤销 / 三指重做

        /// 第二根手指落下时记下「手势前」的状态
        func beginMultiTouchGesture() {
            guard let canvas else { return }
            gestureMark = parent.controller.historyDepth
            gestureBaseline = canvas.drawing.strokes.count
            gestureStartedAt = Date()
        }

        @objc private func handleUndoTap(_ gesture: UITapGestureRecognizer) {
            // 笔还没离纸时不要动画布，否则正在写的这一笔会被整段替换
            guard gesture.state == .ended, !isUsingTool else { return }
            discardStrayDots()
            parent.onUndoTap?()
        }

        @objc private func handleRedoTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, !isUsingTool else { return }
            discardStrayDots()
            parent.onRedoTap?()
        }

        /// 指写模式（fingerDrawing）下，两根手指落下可能先在画布上留下两个点。
        /// 这里只清理「全是点状笔迹」的情况，并且要求刚落下就识别成手势，
        /// 避免把真正画出来的笔迹当成误触删掉。
        private func discardStrayDots() {
            defer {
                gestureMark = nil
                gestureBaseline = nil
                gestureStartedAt = nil
            }
            guard let canvas,
                  let mark = gestureMark,
                  let baseline = gestureBaseline,
                  let startedAt = gestureStartedAt,
                  Date().timeIntervalSince(startedAt) < 2.0 else { return }

            let strokes = canvas.drawing.strokes
            guard strokes.count > baseline else { return }

            let added = strokes[baseline...]
            guard added.allSatisfy(isStrayDot) else { return }

            parent.controller.truncateHistory(to: mark)
            applyProgrammatic(PKDrawing(strokes: Array(strokes.prefix(baseline))))
        }

        private func isStrayDot(_ stroke: PKStroke) -> Bool {
            let box = stroke.renderBounds
            return max(box.width, box.height) < 14
        }

        private func normalizedLocation(_ point: CGPoint, in canvas: PKCanvasView) -> CGPoint {
            normalize(point, in: canvas)
        }

        func normalize(_ point: CGPoint, in canvas: PKCanvasView) -> CGPoint {
            let w = max(canvas.bounds.width, 1)
            let h = max(canvas.bounds.height, 1)
            return CGPoint(x: min(max(point.x / w, 0), 1),
                           y: min(max(point.y / h, 0), 1))
        }

        /// 允许多手势并存：双指捏合与双指拖动可同时进行
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// 单指拖动只在「手指=拖动」时生效，其余手势照旧
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === fingerPan {
                return parent.fingerPans && parent.onFingerPan != nil
            }
            return true
        }

        func applyProgrammatic(_ drawing: PKDrawing, notify: Bool = true) {
            guard let canvas else { return }
            // 正在落笔时替换 drawing，PencilKit 手上这一笔会被整段抹掉
            //（撤销、换页、外部改色都可能撞上这个时机），先存着，抬笔后再应用。
            guard !isUsingTool else {
                pendingProgrammatic = (drawing, notify)
                return
            }
            isProgrammatic = true
            // 同上：尺寸没量出来之前交给 PencilKit 会按 0×0 建帧缓冲
            if let tracking = canvas as? TrackingCanvasView {
                tracking.setDrawingWhenReady(drawing)
            } else {
                canvas.drawing = drawing
            }
            (canvas as? TrackingCanvasView)?.pinViewport()
            (boundController ?? parent.controller).currentDrawing = drawing
            if notify {
                saveToOwner(drawing)
            }
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammatic = false
            }
        }

        private func applyPendingProgrammatic() {
            guard let pending = pendingProgrammatic else { return }
            pendingProgrammatic = nil
            applyProgrammatic(pending.0, notify: pending.1)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isProgrammatic else { return }
            // 书写过程中这个回调会连续触发，每次都 dataRepresentation + 落盘会卡住主线程，
            // 表现为「盯着手指写，笔迹写到一半就断了」。这里合并成 0.25 秒写一次，
            // 撤销步骤则按「一笔 / 一次擦除」在抬笔时记录。
            scheduleSave(canvasView)
            scheduleShapeSnap(in: canvasView)
        }

        // MARK: 一笔结束（虚线切分 / 录音时间轴 / 逐笔回放）

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            strokesBeforeTool = canvasView.drawing.strokes.count
            drawingBeforeTool = canvasView.drawing
            isUsingTool = true
            cancelPendingSnap()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = false
            let before = drawingBeforeTool ?? canvasView.drawing
            drawingBeforeTool = nil

            var result = canvasView.drawing
            if isDashed, let dashed = makeDashed(canvasView) {
                result = dashed
                parent.controller.record(previous: before, current: result)
                applyProgrammatic(result, notify: false)
            } else {
                parent.controller.record(previous: before, current: result)
            }

            flushSave(result)
            parent.onStrokeCommitted?(result.strokes.count)
            scheduleShapeSnap(in: canvasView)
            // 抬笔了，把书写期间被拦下的撤销/换页/改色补上
            applyPendingProgrammatic()
        }

        /// 虚线笔：PencilKit 没有原生虚线 ink，落笔后把这一笔按弧长切成若干短段
        private func makeDashed(_ canvasView: PKCanvasView) -> PKDrawing? {
            let strokes = canvasView.drawing.strokes
            guard strokes.count > strokesBeforeTool else { return nil }

            let width = max(parent.dashWidth, 1)
            let updated = DashRenderer.apply(to: canvasView.drawing,
                                             range: strokesBeforeTool..<strokes.count,
                                             dash: width * 2.6,
                                             gap: width * 1.9)
            guard updated.strokes.count != strokes.count else { return nil }
            return updated
        }

        // MARK: 落盘（合并写入）

        private func scheduleSave(_ canvasView: PKCanvasView) {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.saveToOwner(canvasView.drawing)
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        private func flushSave(_ drawing: PKDrawing) {
            pendingSave?.cancel()
            pendingSave = nil
            saveToOwner(drawing)
        }

        func cancelPendingSave() {
            pendingSave?.cancel()
            pendingSave = nil
        }

        /// 立刻把画布当前墨迹写进存储（换页 / 画布回收前调用）
        func flushCurrentDrawing() {
            guard let canvas else { return }
            flushSave(canvas.drawing)
        }

        // MARK: 形状识别

        private func scheduleShapeSnap(in canvasView: PKCanvasView) {
            pendingSnap?.cancel()
            // 正在书写时不判形状：回填 drawing 会把当前这一笔打断
            guard parent.shapeRecognition, parent.isShapeEligible, !isUsingTool else { return }

            let work = DispatchWorkItem { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.snapLastStroke(in: canvasView)
            }
            pendingSnap = work
            // 停笔 0.7 秒后才判定，避免书写过程中被替换
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }

        private func snapLastStroke(in canvasView: PKCanvasView) {
            // 万一定时器正好在书写中途触发：千万不要回填 drawing，
            // 否则 PencilKit 正在画的那一笔会被整段替换，表现为「抬笔瞬间左边一半没了」
            guard !isUsingTool else {
                scheduleShapeSnap(in: canvasView)
                return
            }

            let strokes = canvasView.drawing.strokes
            guard let last = strokes.last else { return }

            var locations: [CGPoint] = []
            for point in last.path {
                locations.append(point.location)
            }
            guard let snapped = ShapeSnapper.snap(locations) else { return }

            let size = last.path.first?.size ?? CGSize(width: 3, height: 3)
            var strokePoints: [PKStrokePoint] = []
            strokePoints.reserveCapacity(snapped.count)
            for (index, location) in snapped.enumerated() {
                strokePoints.append(PKStrokePoint(location: location,
                                                  timeOffset: Double(index) * 0.004,
                                                  size: size,
                                                  opacity: 1,
                                                  force: 0.7,
                                                  azimuth: 0,
                                                  altitude: .pi / 2))
            }
            let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
            let stroke = PKStroke(ink: last.ink, path: path, transform: last.transform, mask: nil)

            var newStrokes = strokes
            newStrokes.removeLast()
            newStrokes.append(stroke)
            let updated = PKDrawing(strokes: newStrokes)

            // 记为一步可撤销的修改
            parent.controller.record(previous: canvasView.drawing, current: updated)
            applyProgrammatic(updated)
        }
    }
}

// MARK: - 形状识别

/// 把一笔手绘轨迹规整成直线 / 三角形 / 矩形 / 椭圆。
/// 只做"高置信度"替换：认不出来就返回 nil，保持原笔迹。
enum ShapeSnapper {

    /// 返回规整后的折线点（首尾相接的闭合形状会首尾重合）
    static func snap(_ raw: [CGPoint]) -> [CGPoint]? {
        let points = dedupe(raw, minimumDistance: 1.2)
        guard points.count >= 6 else { return nil }

        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 42 else { return nil }

        let start = points.first!
        let end = points.last!
        let chord = hypot(end.x - start.x, end.y - start.y)
        let isClosed = chord < diagonal * 0.22

        var corners = simplify(points, epsilon: diagonal * 0.032)
        if isClosed, corners.count >= 3,
           hypot(corners.first!.x - corners.last!.x,
                 corners.first!.y - corners.last!.y) < diagonal * 0.22 {
            corners.removeLast()
        }

        // 直线：只认「基本笔直」的笔画。
        // 写字时的撇、钩、弧线也是两头一尾，如果只看首尾就会把整笔压成一条直线，
        // 看起来像「左边的部分消失了」。这里加一道弯曲度闸门：路径长度必须接近首尾距离。
        if !isClosed, corners.count <= 2 {
            guard chord > 1, pathLength(points) / chord < 1.08 else { return nil }
            return [start, end]
        }

        guard isClosed else { return nil }

        // 矩形：4 个角且内角接近直角 → 吸附成轴对齐矩形
        if corners.count == 4, isRectangular(corners) {
            let r = box.insetBy(dx: -1, dy: -1)
            return [CGPoint(x: r.minX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.minY)]
        }

        // 三角形：3 个角
        if corners.count == 3 {
            return [corners[0], corners[1], corners[2], corners[0]]
        }

        // 圆 / 椭圆：角点较多且形状接近椭圆
        if corners.count >= 6 || isElliptical(points, box: box) {
            return ellipsePoints(in: box)
        }

        return nil
    }

    // MARK: 几何工具

    private static func dedupe(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result: [CGPoint] = [first]
        for point in points.dropFirst() {
            let last = result[result.count - 1]
            if hypot(point.x - last.x, point.y - last.y) >= minimumDistance {
                result.append(point)
            }
        }
        return result
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x,
                           points[index].y - points[index - 1].y)
        }
        return total
    }

    /// Ramer–Douglas–Peucker 抽稀
    private static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }

        func recurse(_ range: Range<Int>) -> [CGPoint] {
            guard range.count > 2,
                  let first = points[safe: range.lowerBound],
                  let last = points[safe: range.upperBound - 1] else {
                return range.compactMap { points[safe: $0] }
            }

            var maxDistance: CGFloat = 0
            var index = range.lowerBound
            for i in (range.lowerBound + 1)..<(range.upperBound - 1) {
                let d = perpendicularDistance(points[i], lineStart: first, lineEnd: last)
                if d > maxDistance {
                    maxDistance = d
                    index = i
                }
            }

            if maxDistance > epsilon {
                let left = recurse(range.lowerBound..<(index + 1))
                let right = recurse(index..<range.upperBound)
                return left + right.dropFirst()
            } else {
                return [first, last]
            }
        }

        return recurse(0..<points.count)
    }

    private static func perpendicularDistance(_ point: CGPoint,
                                              lineStart: CGPoint,
                                              lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-6 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }
        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared))
        let projX = lineStart.x + t * dx
        let projY = lineStart.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }

    private static func isRectangular(_ corners: [CGPoint]) -> Bool {
        guard corners.count == 4 else { return false }
        for i in 0..<4 {
            let previous = corners[(i + 3) % 4]
            let current = corners[i]
            let next = corners[(i + 1) % 4]
            let v1 = CGPoint(x: previous.x - current.x, y: previous.y - current.y)
            let v2 = CGPoint(x: next.x - current.x, y: next.y - current.y)
            let n1 = hypot(v1.x, v1.y), n2 = hypot(v2.x, v2.y)
            guard n1 > 1, n2 > 1 else { return false }
            let cosine = (v1.x * v2.x + v1.y * v2.y) / (n1 * n2)
            if abs(cosine) > 0.32 { return false }   // 偏离 90° 超过约 19°
        }
        return true
    }

    private static func isElliptical(_ points: [CGPoint], box: CGRect) -> Bool {
        guard points.count >= 10 else { return false }
        let center = CGPoint(x: box.midX, y: box.midY)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        guard radiusX > 6, radiusY > 6 else { return false }

        var errorSum: CGFloat = 0
        var counted = 0
        for point in points {
            let nx = (point.x - center.x) / radiusX
            let ny = (point.y - center.y) / radiusY
            let radius = sqrt(nx * nx + ny * ny)
            errorSum += abs(radius - 1)
            counted += 1
        }
        guard counted > 0 else { return false }
        return errorSum / CGFloat(counted) < 0.13
    }

    private static func ellipsePoints(in box: CGRect) -> [CGPoint] {
        let center = CGPoint(x: box.midX, y: box.midY)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        let steps = 64
        var result: [CGPoint] = []
        result.reserveCapacity(steps + 1)
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            result.append(CGPoint(x: center.x + radiusX * CGFloat(cos(angle)),
                                  y: center.y + radiusY * CGFloat(sin(angle))))
        }
        return result
    }
}

// MARK: - 虚线笔

/// PencilKit 没有原生虚线，这里把一笔按弧长切成一段段短笔迹来模拟。
enum DashRenderer {

    static func apply(to drawing: PKDrawing,
                      range: Range<Int>,
                      dash: CGFloat,
                      gap: CGFloat) -> PKDrawing {
        let strokes = drawing.strokes
        guard range.lowerBound >= 0, range.upperBound <= strokes.count else { return drawing }

        var output: [PKStroke] = []
        output.reserveCapacity(strokes.count + 8)
        for (index, stroke) in strokes.enumerated() {
            guard range.contains(index) else {
                output.append(stroke)
                continue
            }
            let pieces = segments(for: stroke, dash: max(dash, 2), gap: max(gap, 2))
            if pieces.count > 1 {
                output.append(contentsOf: pieces)
            } else {
                output.append(stroke)
            }
        }
        return PKDrawing(strokes: output)
    }

    /// 按 1.5pt 步长重采样，然后按「划线 / 空档」相位切段
    static func segments(for stroke: PKStroke, dash: CGFloat, gap: CGFloat) -> [PKStroke] {
        let source = Array(stroke.path)
        guard source.count >= 2 else { return [] }

        var samples: [(point: CGPoint, distance: CGFloat)] = []
        var total: CGFloat = 0
        var previous = source[0].location
        samples.append((previous, 0))

        let step: CGFloat = 1.5
        for element in source.dropFirst() {
            let target = element.location
            let segmentLength = hypot(target.x - previous.x, target.y - previous.y)
            if segmentLength <= 0.001 {
                previous = target
                continue
            }
            var travelled: CGFloat = 0
            while travelled + step <= segmentLength {
                travelled += step
                let ratio = travelled / segmentLength
                let point = CGPoint(x: previous.x + (target.x - previous.x) * ratio,
                                    y: previous.y + (target.y - previous.y) * ratio)
                total += step
                samples.append((point, total))
            }
            total += segmentLength - travelled
            previous = target
        }
        samples.append((previous, total))

        let period = dash + gap
        guard period > 0.5 else { return [] }

        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        for sample in samples {
            let phase = sample.distance.truncatingRemainder(dividingBy: period)
            if phase < dash {
                run.append(sample.point)
            } else if !run.isEmpty {
                runs.append(run)
                run = []
            }
        }
        if !run.isEmpty { runs.append(run) }

        let reference = source[0]
        var output: [PKStroke] = []
        for points in runs {
            guard points.count >= 2 else { continue }
            var strokePoints: [PKStrokePoint] = []
            strokePoints.reserveCapacity(points.count)
            for (index, point) in points.enumerated() {
                strokePoints.append(PKStrokePoint(location: point,
                                                  timeOffset: Double(index) * 0.004,
                                                  size: reference.size,
                                                  opacity: reference.opacity,
                                                  force: max(reference.force, 0.5),
                                                  azimuth: reference.azimuth,
                                                  altitude: reference.altitude))
            }
            let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
            output.append(PKStroke(ink: stroke.ink,
                                   path: path,
                                   transform: stroke.transform,
                                   mask: stroke.mask))
        }
        return output
    }
}

// MARK: - 套索选择

struct InkSelectionResult {
    var indices: Set<Int>
    var bounds: CGRect
    var isEmpty: Bool { indices.isEmpty }
}

/// 自建套索：PencilKit 没有暴露选区 API，只能自己算命中、自己改笔迹。
enum InkSelectionEngine {

    /// 落在多边形里的笔画（按采样点比例判定，容忍手抖）
    static func select(in drawing: PKDrawing, polygon: [CGPoint]) -> InkSelectionResult {
        guard polygon.count >= 3 else { return InkSelectionResult(indices: [], bounds: .zero) }

        var hits: Set<Int> = []
        var box = CGRect.null

        for (index, stroke) in drawing.strokes.enumerated() {
            let points = Array(stroke.path).map { $0.location.applying(stroke.transform) }
            guard points.count >= 2 else { continue }

            let sampleStep = max(1, points.count / 16)
            var inside = 0
            var counted = 0
            var cursor = 0
            while cursor < points.count {
                if contains(polygon, points[cursor]) { inside += 1 }
                counted += 1
                cursor += sampleStep
            }
            guard counted > 0 else { continue }
            let ratio = Double(inside) / Double(counted)
            if ratio >= 0.55 {
                hits.insert(index)
                let bounds = stroke.renderBounds
                box = box.isNull ? bounds : box.union(bounds)
            }
        }

        return InkSelectionResult(indices: hits, bounds: box.isNull ? .zero : box)
    }

    static func recolor(_ drawing: PKDrawing, indices: Set<Int>, color: UIColor) -> PKDrawing {
        let strokes = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
            guard indices.contains(index) else { return stroke }
            let ink = PKInk(stroke.ink.inkType, color: color)
            return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask)
        }
        return PKDrawing(strokes: strokes)
    }

    static func remove(_ drawing: PKDrawing, indices: Set<Int>) -> PKDrawing {
        let strokes = drawing.strokes.enumerated().compactMap { index, stroke -> PKStroke? in
            indices.contains(index) ? nil : stroke
        }
        return PKDrawing(strokes: strokes)
    }

    static func duplicate(_ drawing: PKDrawing, indices: Set<Int>, offset: CGSize) -> PKDrawing {
        var strokes = drawing.strokes
        let copies = indices.sorted().compactMap { index -> PKStroke? in
            guard indices.contains(index), drawing.strokes.indices.contains(index) else { return nil }
            return translated(drawing.strokes[index], by: offset)
        }
        strokes.append(contentsOf: copies)
        return PKDrawing(strokes: strokes)
    }

    static func translate(_ drawing: PKDrawing, indices: Set<Int>, offset: CGSize) -> PKDrawing {
        let strokes = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
            indices.contains(index) ? translated(stroke, by: offset) : stroke
        }
        return PKDrawing(strokes: strokes)
    }

    static func translated(_ stroke: PKStroke, by offset: CGSize) -> PKStroke {
        let transform = stroke.transform
            .concatenating(CGAffineTransform(translationX: offset.width, y: offset.height))
        return PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask)
    }

    // MARK: 几何

    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                let x = a.x + (b.x - a.x) * t
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
