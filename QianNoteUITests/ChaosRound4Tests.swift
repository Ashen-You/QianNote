import XCTest

/// 第四轮混乱用例：持久化 / 生命周期 / 文档级操作。
///
/// 第三轮压的是编辑期状态机，这一轮压「内容离开屏幕之后还在不在」：
/// 清空只清当前页、切后台再回来、连续滚动开关反复横跳、复制副本后的墨迹、
/// 以及杀进程冷启动之后每一页的墨迹归位。
final class ChaosRound4Tests: NoteUITestCase {

    // MARK: - 1. 清空当前页只影响当前页，撤销后原样回来

    func test01_clearOnlyCurrentPage_undoRestores() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)
        insertPages(2, in: app)          // 3 页
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 3)

        let onPage1 = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.30),
                                     to: CGVector(dx: 0.76, dy: 0.38))
        XCTAssertGreaterThan(onPage1, 150, "第 1 页写不出墨")
        let inkPage1 = inkPixels(region: paperRegion)

        let next = app.buttons["nextPage"]
        XCTAssertTrue(next.exists && next.isEnabled, "第 1 页时下一页不可用")
        next.tap()
        XCTAssertTrue(waitForPage("2 / 3", in: app, timeout: 4), "没有翻到第 2 页")

        let onPage2 = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.52),
                                     to: CGVector(dx: 0.74, dy: 0.60))
        XCTAssertGreaterThan(onPage2, 150, "第 2 页写不出墨")
        let inkPage2 = inkPixels(region: paperRegion)

        tapMoreMenu("清空当前页", in: app)
        usleep(1_500_000)
        let cleared = inkPixels(region: paperRegion)
        XCTAssertLessThan(cleared, max(inkPage2 / 5, 150),
                          "清空第 2 页没生效（\(inkPage2) → \(cleared)）")

        // 撤销之后第 2 页恢复，第 1 页必须始终没被碰过
        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 6), "找不到撤销按钮")
        XCTAssertTrue(undo.isEnabled, "清空之后撤销是灰的")
        undo.tap()
        usleep(1_800_000)
        let restored = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(restored + 250, inkPage2,
                                    "撤销清空之后第 2 页的墨没有回来"
                                    + "（\(inkPage2) → \(cleared) → \(restored)）")

        let prev = app.buttons["prevPage"]
        XCTAssertTrue(prev.exists && prev.isEnabled, "第 2 页时上一页不可用")
        prev.tap()
        XCTAssertTrue(waitForPage("1 / 3", in: app, timeout: 4), "没有回到第 1 页")
        let page1Now = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(page1Now + 250, inkPage1,
                                    "清空第 2 页 / 撤销把第 1 页的墨也带走了"
                                    + "（\(inkPage1) → \(page1Now)）")
    }

    // MARK: - 2. 写一半切后台再回来，墨还在、还能写

    func test02_backgroundForeground_keepsInk() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)

        let gained = drawStroke(app, from: CGVector(dx: 0.28, dy: 0.34),
                                to: CGVector(dx: 0.74, dy: 0.44))
        XCTAssertGreaterThan(gained, 20, "切后台之前就写不出墨")
        let before = inkState(app).length

        XCUIDevice.shared.press(.home)
        usleep(2_500_000)
        app.activate()

        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15),
                      "回到前台之后编辑器没了")
        XCTAssertTrue(waitForPageIndicator(app, timeout: 10), "回到前台之后页码不见了")
        let resumed = waitForInk(app, timeout: 10) { $0.length >= before - 5 }
        XCTAssertGreaterThanOrEqual(resumed.length, before - 5,
                                    "切后台再回来之后墨迹少了"
                                    + "（\(before) → \(resumed.length)）")

        let after = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.54),
                               to: CGVector(dx: 0.72, dy: 0.62))
        XCTAssertGreaterThan(after, 20, "回到前台之后写不出墨")
    }

    // MARK: - 3. 连续滚动开关反复横跳，两种模式里都写，墨一次都不许丢

    func test03_rapidContinuousToggles_keepInk() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)
        insertPages(1, in: app)          // 2 页，自动进入连续滚动
        usleep(1_200_000)

        let base = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.32),
                              to: CGVector(dx: 0.72, dy: 0.40))
        XCTAssertGreaterThan(base, 20, "连续滚动下写不出墨")
        let afterContinuous = inkState(app).length
        XCTAssertGreaterThan(afterContinuous, 20, "连续滚动下探针读不到墨")

        // 关掉连续滚动，在单页模式里再写一笔
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 2)
        let onSingle1 = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.50),
                                       to: CGVector(dx: 0.72, dy: 0.58))
        XCTAssertGreaterThan(onSingle1, 120, "单页模式里写不出墨")

        // 切回连续滚动：两笔都得并进整本
        setContinuousScroll(true, in: app)
        let merged1 = waitForInk(app, timeout: 8) { $0.length > afterContinuous + 50 }
        XCTAssertGreaterThan(merged1.length, afterContinuous + 50,
                             "切回连续滚动后，单页里写的那一笔没并进来"
                             + "（连续=\(afterContinuous) 现在=\(merged1.length)）")

        // 再来一轮：单页写 → 连续读，长度只增不减
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 2)
        let onSingle2 = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.36),
                                       to: CGVector(dx: 0.72, dy: 0.44))
        XCTAssertGreaterThan(onSingle2, 120, "第二轮单页模式里写不出墨")

        setContinuousScroll(true, in: app)
        let merged2 = waitForInk(app, timeout: 8) { $0.length > merged1.length + 50 }
        XCTAssertGreaterThan(merged2.length, merged1.length + 50,
                             "第二轮切回连续滚动后墨迹没有继续增长"
                             + "（上一轮=\(merged1.length) 现在=\(merged2.length)）")

        XCTAssertTrue(app.buttons["返回笔记列表"].exists, "反复切换模式之后编辑器不见了")
        XCTAssertEqual(pageCount(app), 2, "反复切换模式之后页数变了")
    }

    // MARK: - 4. 列表：带墨复制副本 → 重命名副本 → 删掉原件，副本墨迹不丢

    func test04_duplicateRenameDeleteOriginal_inkSurvives() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)                 // 自动改成用例专属标题 noteTitle
        let original = noteTitle
        let copyName = "\(original)-Copy"

        let gained = drawStroke(app, from: CGVector(dx: 0.28, dy: 0.34),
                                to: CGVector(dx: 0.74, dy: 0.44))
        XCTAssertGreaterThan(gained, 20, "复制之前写不出墨")
        let inked = inkState(app).length
        XCTAssertGreaterThan(inked, 20, "复制之前探针读不到墨")
        usleep(800_000)

        app.buttons["返回笔记列表"].tap()
        let originalCard = app.staticTexts[original].firstMatch
        XCTAssertTrue(originalCard.waitForExistence(timeout: 15), "回列表找不到原件")

        openContextMenu(on: originalCard)
        let dup = app.buttons["menu-duplicate"]
        XCTAssertTrue(dup.waitForExistence(timeout: 8), "长按菜单里没有「复制副本」")
        dup.tap()
        let copyCard = app.staticTexts["\(original) 副本"].firstMatch
        XCTAssertTrue(copyCard.waitForExistence(timeout: 10), "列表里没出现副本")
        usleep(800_000)

        // 副本改名，避免「原件 副本」和原件在查询里缠在一起
        openContextMenu(on: copyCard)
        let rename = app.buttons["menu-rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 8), "副本菜单里没有「重命名」")
        rename.tap()
        let field = app.textFields["名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "重命名弹窗里没有输入框")
        field.tap()
        field.clearAndType(copyName)
        commitRenameAlert(in: app, field: field, expected: copyName)
        XCTAssertTrue(app.staticTexts[copyName].waitForExistence(timeout: 10),
                      "副本没有改成新名字")

        // 删掉原件，副本必须不受影响
        openContextMenu(on: app.staticTexts[original].firstMatch)
        let del = app.buttons["menu-delete"]
        XCTAssertTrue(del.waitForExistence(timeout: 8), "原件菜单里没有「删除」")
        del.tap()
        usleep(1_200_000)
        XCTAssertTrue(app.staticTexts[original].waitForNonExistence(timeout: 6),
                      "删除之后原件卡片还在")

        // 打开副本：墨迹要跟复制时一致，并且还能继续写
        let renamedCard = app.staticTexts[copyName].firstMatch
        XCTAssertTrue(renamedCard.waitForExistence(timeout: 10), "删除原件后副本不见了")
        renamedCard.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15), "没能进入副本")
        XCTAssertTrue(waitForPageIndicator(app, timeout: 15), "副本里页码没出现")
        let copyInk = waitForInk(app, timeout: 8) { $0.length >= inked - 5 }
        XCTAssertGreaterThanOrEqual(copyInk.length, inked - 5,
                                    "副本里的墨迹和原件对不上"
                                    + "（原件=\(inked) 副本=\(copyInk.length)）")
        let added = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.54),
                               to: CGVector(dx: 0.72, dy: 0.62))
        XCTAssertGreaterThan(added, 20, "副本里接着写写不出墨")
    }

    // MARK: - 5. 杀进程冷启动：四页里写过的页原样恢复，没写过的仍是空白

    func test05_coldRestart_keepsPagesAndInk() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)
        let title = noteTitle
        insertPages(3, in: app)          // 4 页
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 4)

        // 第 1 页和第 3 页写字，第 2 页故意留白
        let page1 = drawStroke(app, from: CGVector(dx: 0.28, dy: 0.30),
                               to: CGVector(dx: 0.74, dy: 0.38))
        XCTAssertGreaterThan(page1, 20, "第 1 页写不出墨")
        let len1 = inkState(app).length

        let next = app.buttons["nextPage"]
        next.tap()
        XCTAssertTrue(waitForPage("2 / 4", in: app, timeout: 4), "没有翻到第 2 页")
        next.tap()
        usleep(1_200_000)
        let page3 = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.46),
                               to: CGVector(dx: 0.72, dy: 0.56))
        XCTAssertGreaterThan(page3, 20, "第 3 页写不出墨")
        let len3 = inkState(app).length
        usleep(1_500_000)                // 等自动保存落盘

        // 真正杀掉进程再冷启动（不能再带 -uiTestResetData，否则存储会被清空）
        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestResetData" }
        app.launch()
        app.skipQuiescenceWaits()

        let card = app.staticTexts[title].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "冷启动之后列表里找不到笔记")
        card.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 20),
                      "冷启动之后进不了笔记")
        XCTAssertTrue(waitForPageIndicator(app, timeout: 15), "冷启动之后页码没出现")
        XCTAssertEqual(pageCount(app), 4, "冷启动之后页数不是 4")

        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 4)

        let kept1 = waitForInk(app, timeout: 8) { $0.length >= len1 - 5 }
        XCTAssertGreaterThanOrEqual(kept1.length, len1 - 5,
                                    "冷启动之后第 1 页的墨丢了"
                                    + "（写时=\(len1) 现在=\(kept1.length)）")

        let next2 = app.buttons["nextPage"]
        next2.tap()
        usleep(1_200_000)
        XCTAssertEqual(pageIndicator(app), "2 / 4", "没有翻到第 2 页")
        let blank = waitForInk(app, timeout: 4) { $0.length < 20 }
        XCTAssertLessThan(blank.length, 20,
                          "第 2 页本来是空白，冷启动后冒出了墨（\(blank.length)）")

        next2.tap()
        usleep(1_200_000)
        XCTAssertEqual(pageIndicator(app), "3 / 4", "没有翻到第 3 页")
        let kept3 = waitForInk(app, timeout: 8) { $0.length >= len3 - 5 }
        XCTAssertGreaterThanOrEqual(kept3.length, len3 - 5,
                                    "冷启动之后第 3 页的墨丢了"
                                    + "（写时=\(len3) 现在=\(kept3.length)）")
        let added = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.62),
                               to: CGVector(dx: 0.72, dy: 0.70))
        XCTAssertGreaterThan(added, 20, "冷启动恢复之后写不出墨")
    }

    // MARK: - 小工具

    private func waitForPage(_ expected: String, in app: XCUIApplication,
                             timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pageIndicator(app) == expected { return true }
            usleep(80_000)
        }
        return pageIndicator(app) == expected
    }

    private func openContextMenu(on card: XCUIElement) {
        card.press(forDuration: 1.3)
        usleep(600_000)
    }
}
