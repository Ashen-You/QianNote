import XCTest
import PencilKit
@testable import QianNote

final class CanvasControllerTests: XCTestCase {

    /// 构造一个「非空」的 PKDrawing：一条从原点到指定点的直线笔迹。
    /// 用不同的终点坐标得到内容不同的 drawing，用来驱动撤销栈的入栈判断。
    private func makeDrawing(to point: CGPoint) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: point, timeOffset: 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        return PKDrawing(strokes: [stroke])
    }

    // MARK: - record / undo / redo 基本流程

    func testUndoRedo_restoresPreviousDrawing() {
        let controller = CanvasController()
        let d0 = PKDrawing()          // 空
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        let d2 = makeDrawing(to: CGPoint(x: 200, y: 200))

        controller.record(previous: d0, current: d1)
        controller.record(previous: d1, current: d2)

        XCTAssertTrue(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        XCTAssertEqual(controller.historyDepth, 2)

        controller.undo()
        XCTAssertEqual(controller.currentDrawing.strokes.count, d1.strokes.count)
        XCTAssertTrue(controller.canRedo)

        controller.redo()
        XCTAssertEqual(controller.currentDrawing.strokes.count, d2.strokes.count)
        XCTAssertFalse(controller.canRedo)
    }

    func testRecord_ignoresNoOpChange() {
        let controller = CanvasController()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))

        // 前后相同的 drawing 不应入栈
        controller.record(previous: d1, current: d1)
        XCTAssertFalse(controller.canUndo)
        XCTAssertEqual(controller.historyDepth, 0)
    }

    func testNewEdit_clearsRedoStack() {
        let controller = CanvasController()
        let d0 = PKDrawing()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        let d2 = makeDrawing(to: CGPoint(x: 200, y: 200))
        let d3 = makeDrawing(to: CGPoint(x: 300, y: 300))

        controller.record(previous: d0, current: d1)
        controller.record(previous: d1, current: d2)
        controller.undo()   // 现在 redo 栈有 d2

        XCTAssertTrue(controller.canRedo)

        // 撤销后再写新笔画，redo 栈应被清空
        controller.record(previous: controller.currentDrawing, current: d3)
        XCTAssertFalse(controller.canRedo, "写入新内容后重做栈应被清空")
    }

    // MARK: - 撤销步数上限

    func testUndoLimit_is60() {
        let controller = CanvasController()
        // 连续记录超过 limit 步，验证栈被截断到 60
        var previous = PKDrawing()
        for i in 0..<80 {
            let current = makeDrawing(to: CGPoint(x: CGFloat(i + 1), y: 100))
            controller.record(previous: previous, current: current)
            previous = current
        }
        XCTAssertLessThanOrEqual(controller.historyDepth, 60, "撤销栈不应超过 60 步")
    }

    // MARK: - truncateHistory / resetHistory

    func testTruncateHistory_discardsStrayDots() {
        let controller = CanvasController()
        let d0 = PKDrawing()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        let d2 = makeDrawing(to: CGPoint(x: 200, y: 200))
        controller.record(previous: d0, current: d1)
        controller.record(previous: d1, current: d2)
        XCTAssertEqual(controller.historyDepth, 2)

        // 多点手势误触产生的撤销步：丢掉 depth=1 之后的那一步
        controller.truncateHistory(to: 1)
        XCTAssertEqual(controller.historyDepth, 1)
    }

    func testResetHistory_clearsBothStacks() {
        let controller = CanvasController()
        let d0 = PKDrawing()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        controller.record(previous: d0, current: d1)
        XCTAssertTrue(controller.canUndo)

        controller.resetHistory()
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        XCTAssertEqual(controller.historyDepth, 0)
    }

    // MARK: - applyEdit（套索改色 / 删除 / 复制）

    func testApplyEdit_recordsOneUndoStep() {
        let controller = CanvasController()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        let d2 = makeDrawing(to: CGPoint(x: 200, y: 200))

        controller.applyEdit(d1)
        controller.applyEdit(d2)

        XCTAssertTrue(controller.canUndo)
        // 撤销一次应回到上一次 applyEdit 的内容（d1，1 条笔迹）
        controller.undo()
        XCTAssertEqual(controller.currentDrawing.strokes.count, 1)
        // 再撤销一次回到最初的空画布
        controller.undo()
        XCTAssertEqual(controller.currentDrawing.strokes.count, 0)
    }
}

final class CanvasControllerPoolTests: XCTestCase {

    private func makeDrawing(to point: CGPoint) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: point, timeOffset: 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        return PKDrawing(strokes: [stroke])
    }

    // MARK: - 每页独立的撤销栈（连续滚动模式下多页共存）

    func testPool_isolatesUndoStacksPerPage() {
        let pool = CanvasControllerPool()
        let pageA = UUID()
        let pageB = UUID()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))

        // 页 A 记一步
        let controllerA = pool.controller(for: pageA)
        controllerA.record(previous: PKDrawing(), current: d1)

        // 页 B 是空栈
        pool.activate(pageA)
        XCTAssertTrue(pool.canUndo, "页 A 有可撤销内容")

        pool.activate(pageB)
        XCTAssertFalse(pool.canUndo, "切到页 B 后应无撤销内容")

        pool.activate(pageA)
        XCTAssertTrue(pool.canUndo, "切回页 A 撤销内容应仍在")
    }

    func testPool_undoTargetsActivePage() {
        let pool = CanvasControllerPool()
        let pageA = UUID()
        let pageB = UUID()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))

        pool.controller(for: pageA).record(previous: PKDrawing(), current: d1)
        pool.controller(for: pageB).record(previous: PKDrawing(), current: d1)

        pool.activate(pageA)
        XCTAssertTrue(pool.undo(pageID: pageA), "撤销页 A 应成功")
        XCTAssertTrue(pool.controller(for: pageB).canUndo, "页 B 的栈不受页 A 撤销影响")
    }
}

// MARK: - 系统 UndoManager 桥接

final class CanvasControllerSystemUndoTests: XCTestCase {

    private func makeDrawing(to point: CGPoint) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: point, timeOffset: 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        return PKDrawing(strokes: [stroke])
    }

    /// 让同步到 runloop 末尾的重建任务先跑完，再断言系统 undoManager 状态
    private func drainMainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    /// 模拟真实书写：每笔落在一个独立的 runloop 事件里（一次 touchesEnded）。
    /// UndoManager 会把同一事件内对同一 target 的多次 registerUndo 折叠成一层，
    /// 所以测试里必须跨 runloop 记录，才能得到与真机一致的层数。
    private func recordStroke(_ controller: CanvasController,
                              previous: PKDrawing,
                              current: PKDrawing) {
        let exp = expectation(description: "record")
        DispatchQueue.main.async {
            controller.record(previous: previous, current: current)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testSystemUndo_managerReceivesUndoRegistration() {
        let controller = CanvasController()
        let undoManager = UndoManager()
        controller.systemUndoManager = undoManager

        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        recordStroke(controller, previous: PKDrawing(), current: d1)
        drainMainQueue()

        XCTAssertTrue(controller.canUndo)
        XCTAssertTrue(undoManager.canUndo, "系统 undoManager 应能撤销")
    }

    func testSystemUndo_threeFingerUndoDrivesSelfStack() {
        let controller = CanvasController()
        let undoManager = UndoManager()
        controller.systemUndoManager = undoManager

        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        let d2 = makeDrawing(to: CGPoint(x: 200, y: 200))
        recordStroke(controller, previous: PKDrawing(), current: d1)
        recordStroke(controller, previous: d1, current: d2)
        drainMainQueue()

        XCTAssertEqual(controller.historyDepth, 2)
        XCTAssertTrue(undoManager.canUndo)

        // 模拟系统撤销（三指滑动 / ⌘Z）——直接调用 undoManager.undo()
        undoManager.undo()
        drainMainQueue()

        XCTAssertEqual(controller.currentDrawing.strokes.count, d1.strokes.count,
                       "系统撤销后应回到 d1（1 条笔迹）")
        XCTAssertEqual(controller.historyDepth, 1, "撤销后自研栈应减一层")
    }

    func testSystemUndo_supportsRedoAfterUndo() {
        let controller = CanvasController()
        let undoManager = UndoManager()
        controller.systemUndoManager = undoManager

        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        let d2 = makeDrawing(to: CGPoint(x: 200, y: 200))
        recordStroke(controller, previous: PKDrawing(), current: d1)
        recordStroke(controller, previous: d1, current: d2)
        drainMainQueue()

        undoManager.undo()
        drainMainQueue()
        XCTAssertEqual(controller.currentDrawing.strokes.count, d1.strokes.count)
        XCTAssertTrue(undoManager.canRedo, "撤销后系统应可重做")

        undoManager.redo()
        drainMainQueue()
        XCTAssertEqual(controller.currentDrawing.strokes.count, d2.strokes.count,
                       "重做后应回到 d2（2 条笔迹）")
    }

    func testSystemUndo_resetHistoryClearsSystemManager() {
        let controller = CanvasController()
        let undoManager = UndoManager()
        controller.systemUndoManager = undoManager

        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))
        recordStroke(controller, previous: PKDrawing(), current: d1)
        drainMainQueue()
        XCTAssertTrue(undoManager.canUndo)

        controller.resetHistory()
        drainMainQueue()

        XCTAssertFalse(undoManager.canUndo, "清空历史后系统 undoManager 应无可撤销动作")
        XCTAssertFalse(controller.canUndo)
    }

    func testSystemUndo_poolSwitchesBindingPerPage() {
        let pool = CanvasControllerPool()
        let undoManager = UndoManager()
        pool.systemUndoManager = undoManager

        let pageA = UUID()
        let pageB = UUID()
        let d1 = makeDrawing(to: CGPoint(x: 100, y: 100))

        // 真实流程：先建 controller（LazyVStack 渲染），再 activate（onAppear），再落笔
        let controllerA = pool.controller(for: pageA)
        pool.activate(pageA)
        recordStroke(controllerA, previous: PKDrawing(), current: d1)
        drainMainQueue()
        XCTAssertTrue(undoManager.canUndo, "页 A 落笔后系统应可撤销")

        // 切到空页 B：系统 undo 历史应被清空
        pool.activate(pageB)
        drainMainQueue()
        XCTAssertFalse(undoManager.canUndo, "切到空页 B 后系统应无可撤销")
    }
}
