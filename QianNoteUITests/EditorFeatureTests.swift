import XCTest

/// 编辑器内的功能与边界用例：撤销重做、清空、页管理、重命名、全屏、工具栏收起、
/// 激光笔不落盘、连续滚动跨页长笔画、缩放后仍可书写、快速切工具。
///
/// 全部走真实触摸 + 截图断言，不碰 App 内部状态。
final class EditorFeatureTests: NoteUITestCase {

    // MARK: - 1. 撤销 / 重做

    func test01_undoRedo_restoresInk() {
        // 关掉形状识别：否则一笔会被规整成直线，多出一步「取消规整」的撤销，
        // 这里只想验证「一笔 = 一步撤销」这件事
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)

        // 分两笔画，才能看清一次撤销到底退了几步
        let first = drawAndConfirm(app, from: CGVector(dx: 0.26, dy: 0.30),
                                   to: CGVector(dx: 0.80, dy: 0.36))
        XCTAssertGreaterThan(first, 200, "第一笔就没画上")
        let ink1 = inkPixels(region: paperRegion)

        let second = drawAndConfirm(app, from: CGVector(dx: 0.26, dy: 0.50),
                                    to: CGVector(dx: 0.80, dy: 0.56))
        XCTAssertGreaterThan(second, 200, "第二笔没画上")
        let ink2 = inkPixels(region: paperRegion)

        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.exists, "找不到撤销按钮")
        XCTAssertTrue(undo.isEnabled, "画了两笔，撤销却是灰的")
        undo.tap()
        usleep(1_500_000)
        let afterUndo = inkPixels(region: paperRegion)
        print("[UNDO] ink1=\(ink1) ink2=\(ink2) afterUndo=\(afterUndo) undoEnabled=\(undo.isEnabled) redoEnabled=\(app.buttons["重做"].isEnabled)")

        // 撤一次应当至少退掉一笔（墨迹明显变少）
        XCTAssertLessThan(afterUndo, ink2 - 250,
                          "撤销后墨迹没有明显减少（ink1=\(ink1) ink2=\(ink2) now=\(afterUndo)）")

        let redo = app.buttons["重做"]
        XCTAssertTrue(redo.exists, "找不到重做按钮")
        XCTAssertTrue(redo.isEnabled, "撤销之后重做是灰的")
        redo.tap()
        usleep(1_500_000)
        let afterRedo = inkPixels(region: paperRegion)
        print("[UNDO] afterRedo=\(afterRedo)")
        XCTAssertGreaterThan(afterRedo, afterUndo + 250,
                             "重做后墨迹没有回来（undo=\(afterUndo) redo=\(afterRedo)）")
    }

    // MARK: - 2. 清空当前页

    func test02_clearPage_wipesAllInk() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        drawAndConfirm(app, from: CGVector(dx: 0.26, dy: 0.30),
                       to: CGVector(dx: 0.80, dy: 0.38))
        drawAndConfirm(app, from: CGVector(dx: 0.26, dy: 0.50),
                       to: CGVector(dx: 0.80, dy: 0.58))
        let inked = inkPixels(region: paperRegion)

        tapMoreMenu("清空当前页", in: app)
        usleep(1_200_000)

        let cleared = inkPixels(region: paperRegion)
        XCTAssertLessThan(cleared, max(inked / 5, 150),
                          "清空当前页之后纸上还有大量墨迹（\(inked) → \(cleared)）")

        // 清空后必须还能继续写
        let resumed = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.34),
                                     to: CGVector(dx: 0.75, dy: 0.44))
        XCTAssertGreaterThan(resumed, 200, "清空之后写不出墨")
    }

    // MARK: - 3. 插入页面

    func test03_insertPages_growsCount_andKeepsInk() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        XCTAssertEqual(pageCount(app), 1, "新笔记应该只有 1 页")

        drawAndConfirm(app, from: CGVector(dx: 0.26, dy: 0.30),
                       to: CGVector(dx: 0.80, dy: 0.40))
        let inkOnFirst = inkPixels(region: paperRegion)
        XCTAssertGreaterThan(inkOnFirst, 400, "第一笔就没画上")

        insertPages(3, in: app)
        XCTAssertEqual(pageCount(app), 4, "插了 3 页之后页数不是 4")

        // 插页会把编辑器从单页切换成连续滚动，此时一屏不等于一页，
        // 靠屏幕坐标量墨迹不可靠；改为退出重进——重新进入必定停在第 1 页顶部，
        // 正好验证「插页之后原有墨迹还在」。这才是这条用例要守的东西。
        app.buttons["返回笔记列表"].tap()
        usleep(800_000)
        let card = app.staticTexts["未命名笔记"]
        XCTAssertTrue(card.waitForExistence(timeout: 12), "返回列表后找不到笔记")
        card.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15), "没能重新进入笔记")
        usleep(2_500_000)

        let inkBack = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(inkBack + 200, inkOnFirst,
                                    "插页之后再进来，第一页的墨迹丢了（\(inkOnFirst) → \(inkBack)）")
        XCTAssertEqual(pageCount(app), 4, "重进之后页数不对")
    }

    // MARK: - 4. 重命名

    func test04_renameNote_fromTitleButton() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        // 点标题打开重命名
        let title = app.buttons["未命名笔记"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "找不到笔记标题按钮")
        title.tap()

        let field = app.textFields["标题"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "重命名弹窗里没有输入框")
        field.tap()
        field.clearAndType("UITestNote42")
        app.buttons["保存"].tap()
        usleep(900_000)

        XCTAssertTrue(app.buttons["UITestNote42"].waitForExistence(timeout: 8),
                      "标题没有更新成新名字")

        // 返回列表，卡片标题也应该是新名字
        app.buttons["返回笔记列表"].tap()
        XCTAssertTrue(app.staticTexts["UITestNote42"].waitForExistence(timeout: 12),
                      "列表里的卡片标题没有同步更新")
    }

    // MARK: - 5. 全屏阅读

    func test05_fullScreen_enterAndExit() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        let enter = app.buttons["全屏阅读"]
        XCTAssertTrue(enter.waitForExistence(timeout: 8), "找不到全屏阅读按钮")
        enter.tap()

        let exit = app.buttons["退出全屏"]
        XCTAssertTrue(exit.waitForExistence(timeout: 8), "进入全屏后没有退出入口")
        // 全屏时顶栏是 opacity(0) + 禁止点击，元素仍在层级里，所以查 isHittable
        XCTAssertFalse(app.buttons["返回笔记列表"].isHittable, "全屏状态下顶栏还能点")

        exit.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 8),
                      "退出全屏后没有回到编辑器")
    }

    // MARK: - 6. 收起 / 展开工具栏

    func test06_toolbarCollapse_andRestore() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        let collapse = app.buttons["收起工具栏"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 8), "找不到收起工具栏按钮")
        collapse.tap()
        usleep(500_000)

        XCTAssertFalse(app.buttons["钢笔"].exists, "收起后工具栏还在")
        let restore = app.buttons["显示工具栏"]
        XCTAssertTrue(restore.waitForExistence(timeout: 6), "收起后没有展开入口")
        restore.tap()
        usleep(500_000)

        XCTAssertTrue(app.buttons["钢笔"].waitForExistence(timeout: 6), "展开后工具栏没回来")
        // 收起再展开之后必须还能写
        let gained = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.34),
                                    to: CGVector(dx: 0.76, dy: 0.44))
        XCTAssertGreaterThan(gained, 200, "收起再展开工具栏之后写不出墨")
    }

    // MARK: - 7. 激光笔不落盘

    func test07_laserTool_leavesNoPersistentInk() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        let blank = inkPixels(region: paperRegion)

        let laser = app.buttons["激光笔"]
        XCTAssertTrue(laser.waitForExistence(timeout: 8), "找不到激光笔")
        laser.tap()
        usleep(300_000)

        // 画一笔，立刻看（此时应该有红色轨迹）
        stroke(app, from: CGVector(dx: 0.26, dy: 0.34), to: CGVector(dx: 0.80, dy: 0.44), hold: 0.2)
        usleep(200_000)
        let during = inkPixels(region: paperRegion)

        // 轨迹会自己淡出，几秒后应当回到接近空白
        usleep(4_000_000)
        let after = inkPixels(region: paperRegion)
        XCTAssertLessThan(after - blank, 250,
                          "激光笔画完留下了持久墨迹（blank=\(blank) during=\(during) after=\(after)）")

        // 换回钢笔必须还能正常写
        app.buttons["钢笔"].tap()
        usleep(300_000)
        let gained = drawAndConfirm(app, from: CGVector(dx: 0.26, dy: 0.50),
                                    to: CGVector(dx: 0.80, dy: 0.58))
        XCTAssertGreaterThan(gained, 200, "从激光笔切回钢笔后写不出墨")
    }

    // MARK: - 8. 连续滚动模式下的书写

    func test08_continuousScroll_stillDraws() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(2, in: app)

        // 插页后编辑器会自动切到连续滚动（共享画布），这里确认它仍然能写
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let toggle = app.buttons["连续滚动"].exists
            ? app.buttons["连续滚动"]
            : app.switches["连续滚动"]
        if toggle.waitForExistence(timeout: 4) {
            // 已经是开的状态就不动它，免得关掉
            if (toggle.value as? String) == "0" { toggle.tap() }
            else { app.tap() }
        } else {
            app.tap()
        }
        usleep(1_500_000)

        let gained = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.34),
                                    to: CGVector(dx: 0.72, dy: 0.44))
        XCTAssertGreaterThan(gained, 200, "连续滚动模式下画不出墨")

        // 再写一笔，确认共享画布没有被反复重建打断
        let second = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.52),
                                    to: CGVector(dx: 0.72, dy: 0.60))
        XCTAssertGreaterThan(second, 150, "连续滚动模式下第二笔画不上")
    }

    // MARK: - 9. 缩放之后仍能书写

    func test09_pinchZoom_stillDraws() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        app.pinch(withScale: 2.0, velocity: 1.5)
        usleep(1_200_000)

        let zoomed = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.40),
                                    to: CGVector(dx: 0.70, dy: 0.50))
        XCTAssertGreaterThan(zoomed, 200, "放大之后写不出墨")

        app.pinch(withScale: 0.5, velocity: -1.5)
        usleep(1_200_000)

        let back = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.60),
                                  to: CGVector(dx: 0.70, dy: 0.70))
        XCTAssertGreaterThan(back, 200, "缩回去之后写不出墨")
    }

    // MARK: - 10. 快速切工具

    func test10_rapidToolSwitching_staysResponsive() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        let names = ["钢笔", "铅笔", "荧光笔", "橡皮", "套索", "钢笔"]
        for i in 0..<18 {
            let name = names[i % names.count]
            let b = app.buttons[name]
            if b.exists { b.tap() }
        }
        usleep(600_000)

        XCTAssertTrue(app.buttons["返回笔记列表"].exists, "快速切工具之后编辑器消失了（可能崩了）")
        app.buttons["钢笔"].tap()
        usleep(300_000)
        let gained = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.36),
                                    to: CGVector(dx: 0.78, dy: 0.46))
        XCTAssertGreaterThan(gained, 200, "快速切工具之后写不出墨")
    }

    // MARK: - 11. 末页「下一页」应当禁用

    func test11_lastPage_disablesNextButton() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(2, in: app)

        // 插页后编辑器会自动停在末页，先回到第一页，才能验证「非末页时下一页可用」
        goToFirstPage(app, pageCount: 3)

        let next = app.buttons["nextPage"]
        XCTAssertTrue(next.exists, "找不到下一页按钮")
        XCTAssertTrue(next.isEnabled, "非末页时下一页却是灰的")

        // 走到底
        for _ in 0..<5 where next.exists && next.isEnabled {
            next.tap()
            usleep(500_000)
        }
        XCTAssertEqual(pageIndicator(app), "3 / 3", "没能停在末页")
        XCTAssertFalse(next.isEnabled, "末页的下一页按钮居然还能点")

        // 回第一页，上一页应当禁用
        let prev = app.buttons["prevPage"]
        for _ in 0..<5 where prev.exists && prev.isEnabled {
            prev.tap()
            usleep(500_000)
        }
        XCTAssertEqual(pageIndicator(app), "1 / 3", "没能回到首页")
        XCTAssertFalse(prev.isEnabled, "首页的上一页按钮居然还能点")
    }
}

// MARK: - 输入框便捷操作

extension XCUIElement {
    /// 清空再输入。typeText 是追加，所以先按退格删掉已有内容。
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
