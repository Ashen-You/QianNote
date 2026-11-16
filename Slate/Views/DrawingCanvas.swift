import SwiftUI
import PencilKit
import UIKit

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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
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

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.canvas = canvas

        if coordinator.currentPageID != pageID {
            coordinator.currentPageID = pageID
            coordinator.toolKey = toolKey
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
        var doubleTap: UITapGestureRecognizer?

        init(_ parent: DrawingCanvas) {
            self.parent = parent
            self.drawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
            self.isEnabled = parent.isEnabled
        }

        // MARK: 双指手势（不抢占单指书写）

        func installGestures(on canvas: PKCanvasView) {
            canvas.isScrollEnabled = false   // 交给外层变换层统一控制

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
        }
    }
}
