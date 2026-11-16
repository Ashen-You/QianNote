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
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        weak var canvas: PKCanvasView?
        var currentPageID: UUID?
        var toolKey: String = ""
        var drawingPolicy: PKCanvasViewDrawingPolicy = .default
        var isEnabled: Bool = true
        private var isProgrammatic = false

        init(_ parent: DrawingCanvas) {
            self.parent = parent
            self.drawingPolicy = parent.fingerDrawing ? .anyInput : .pencilOnly
            self.isEnabled = parent.isEnabled
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
