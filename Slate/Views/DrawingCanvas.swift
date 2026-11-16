import SwiftUI
import PencilKit
import UIKit
import Combine

// MARK: - 画布控制器（撤销 / 重做 / 恢复）

final class CanvasController: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var currentDrawing = PKDrawing()
    weak var canvas: PKCanvasView?
    var onDrawingRestored: ((PKDrawing) -> Void)?

    private var undoStack: [PKDrawing] = []
    private var redoStack: [PKDrawing] = []
    private let limit = 60

    func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateFlags()
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
    }

    func undo() {
        guard let target = undoStack.popLast() else { return }
        redoStack.append(currentDrawing)
        restore(target)
    }

    func redo() {
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
        refreshFlags()
    }

    func undo() {
        guard let id = activePageID else { return }
        controllers[id]?.undo()
        refreshFlags()
    }

    func redo() {
        guard let id = activePageID else { return }
        controllers[id]?.redo()
        refreshFlags()
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
/// 用于「放大书写时页面跟随笔尖自动平移」。
final class TrackingCanvasView: PKCanvasView {
    var onTouch: ((CGPoint) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if let point = touches.first?.location(in: self) { onTouch?(point) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if let point = touches.first?.location(in: self) { onTouch?(point) }
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
        canvas.tool = tool
        canvas.drawing = initialDrawing

        let coordinator = context.coordinator
        coordinator.canvas = canvas
        coordinator.currentPageID = pageID
        coordinator.toolKey = toolKey

        controller.canvas = canvas
        controller.currentDrawing = initialDrawing
        controller.onDrawingRestored = { [weak coordinator] drawing in
            coordinator?.applyProgrammatic(drawing)
        }

        coordinator.installGestures(on: canvas)
        coordinator.trackingCanvas = canvas as? TrackingCanvasView
        coordinator.trackingCanvas?.onTouch = { [weak coordinator] point in
            guard let coordinator, let canvas = coordinator.trackingCanvas else { return }
            coordinator.parent.onPenMove?(coordinator.normalize(point, in: canvas))
        }

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.canvas = canvas

        if coordinator.currentPageID != pageID {
            coordinator.currentPageID = pageID
            coordinator.toolKey = toolKey
            coordinator.cancelPendingSnap()
            controller.currentDrawing = initialDrawing
            controller.resetHistory()
            coordinator.applyProgrammatic(initialDrawing, notify: false)
        }

        if coordinator.toolKey != toolKey {
            coordinator.toolKey = toolKey
            canvas.tool = tool
        }

        let policy: PKCanvasViewDrawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if coordinator.drawingPolicy != policy {
            coordinator.drawingPolicy = policy
            canvas.drawingPolicy = policy
        }

        if coordinator.isEnabled != isEnabled {
            coordinator.isEnabled = isEnabled
            canvas.isUserInteractionEnabled = isEnabled
        }

        // 手写模式（单指书写）下双击会被误判，只保留双指手势
        coordinator.doubleTap?.isEnabled = !fingerDrawing
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: DrawingCanvas
        weak var canvas: PKCanvasView?
        var currentPageID: UUID?
        var toolKey: String = ""
        var drawingPolicy: PKCanvasViewDrawingPolicy = .default
        var isEnabled: Bool = true
        private var isProgrammatic = false

        private var lastScale: CGFloat = 1
        private var lastTranslation: CGPoint = .zero
        private var pendingSnap: DispatchWorkItem?
        var doubleTap: UITapGestureRecognizer?
        weak var trackingCanvas: TrackingCanvasView?

        init(_ parent: DrawingCanvas) {
            self.parent = parent
            self.drawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
            self.isEnabled = parent.isEnabled
        }

        func cancelPendingSnap() {
            pendingSnap?.cancel()
            pendingSnap = nil
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

        func applyProgrammatic(_ drawing: PKDrawing, notify: Bool = true) {
            guard let canvas else { return }
            isProgrammatic = true
            canvas.drawing = drawing
            parent.controller.currentDrawing = drawing
            if notify {
                parent.onChange(drawing)
            }
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammatic = false
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isProgrammatic else { return }
            let drawing = canvasView.drawing
            parent.controller.record(previous: parent.controller.currentDrawing, current: drawing)
            parent.onChange(drawing)
            scheduleShapeSnap(in: canvasView)
        }

        // MARK: 形状识别

        private func scheduleShapeSnap(in canvasView: PKCanvasView) {
            pendingSnap?.cancel()
            guard parent.shapeRecognition, parent.isShapeEligible else { return }

            let work = DispatchWorkItem { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.snapLastStroke(in: canvasView)
            }
            pendingSnap = work
            // 停笔 0.7 秒后才判定，避免书写过程中被替换
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }

        private func snapLastStroke(in canvasView: PKCanvasView) {
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

        // 路径长度太短说明不是有意的图形
        guard pathLength(points) > diagonal * 1.1 else { return nil }

        let start = points.first!
        let end = points.last!
        let isClosed = hypot(end.x - start.x, end.y - start.y) < diagonal * 0.22

        var corners = simplify(points, epsilon: diagonal * 0.032)
        if isClosed, corners.count >= 3,
           hypot(corners.first!.x - corners.last!.x,
                 corners.first!.y - corners.last!.y) < diagonal * 0.22 {
            corners.removeLast()
        }

        // 直线
        if !isClosed, corners.count <= 2 {
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
