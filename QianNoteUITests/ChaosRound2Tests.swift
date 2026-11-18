import XCTest

/// 第二轮新增的混乱 / 边界用例。
///
/// 第一轮守住了「单页内的正确性」和「工具状态」，这一轮压更外层的场景：
/// 多页逐页写入后的持久化、误清空的挽回、所有笔型都要能出墨、
/// 旋转设备重排布局、以及连续滚动模式下的随机组合。
final class ChaosRound2Tests: NoteUITestCase {

    // MARK: - 1. 四页逐页写，退出重进每页都在

    func test01_writeEveryPage_thenReenter_allKept() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(3, in: app)          // 4 页
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 4)

        // 每页写一笔，位置各不相同，便于回看时肉眼也能分辨
        var inks: [Int] = []
        for page in 1...4 {
            let y = 0.30 + CGFloat(page - 1) * 0.12
            let gained = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: y),
                                        to: CGVector(dx: 0.76, dy: y + 0.06))
            XCTAssertGreaterThan(gained, 150, "第 \(page) 页写不出墨")
            inks.append(inkPixels(region: paperRegion))
            if page < 4 {
                let next = app.buttons["nextPage"]
                XCTAssertTrue(next.exists && next.isEnabled, "第 \(page) 页时下一页不可用")
                next.tap()
                usleep(1_300_000)
            }
        }
        XCTAssertEqual(pageIndicator(app), "4 / 4", "没有走到第 4 页")

        // 退出再进：书签不一定回到第 1 页，先归位再逐页核对
        app.buttons["返回笔记列表"].tap()
        usleep(900_000)
        let card = noteCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "返回列表后找不到笔记")
        card.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15), "没能重新进入笔记")
        usleep(2_000_000)
        XCTAssertEqual(pageCount(app), 4, "重进之后页数不是 4")

        // 关掉连续滚动（重进可能又变回自动模式），保证一屏一页
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 4)

        for page in 1...4 {
            let ink = inkPixels(region: paperRegion)
            XCTAssertGreaterThanOrEqual(ink + 200, inks[page - 1],
                                        "重进之后第 \(page) 页的墨迹丢了"
                                        + "（写时=\(inks[page - 1]) 现在=\(ink)）")
            if page < 4 {
                let next = app.buttons["nextPage"]
                if next.exists && next.isEnabled {
                    next.tap()
                    usleep(1_300_000)
                }
            }
        }
    }

    // MARK: - 2. 误点「清空当前页」之后要能撤销回来

    func test02_clearPage_thenUndo_restoresInk() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)

        let drawn = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.34),
                                   to: CGVector(dx: 0.76, dy: 0.44))
        XCTAssertGreaterThan(drawn, 200, "一开始就写不出墨")
        let inked = inkPixels(region: paperRegion)

        tapMoreMenu("清空当前页", in: app)
        usleep(1_500_000)
        let cleared = inkPixels(region: paperRegion)
        XCTAssertLessThan(cleared, max(inked / 5, 150),
                          "清空当前页没生效（\(inked) → \(cleared)）")

        // 清空必须是一步可撤销的操作，否则用户误点就永久丢内容
        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 6), "找不到撤销按钮")
        XCTAssertTrue(undo.isEnabled, "清空之后撤销是灰的 —— 这一步没被记为可撤销")
        undo.tap()
        usleep(1_800_000)

        let restored = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(restored + 250, inked,
                                    "撤销清空之后墨迹没有回来（\(inked) → \(cleared) → \(restored)）")
    }

    // MARK: - 3. 每一种落墨的笔都要真的出墨

    func test03_everyInkToolLeavesInk() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)

        // 荧光笔 / 水彩是半透明浅色，深色像素统计对它们不成立，这里只压不透明的墨
        let pens = ["钢笔", "虚线笔", "铅笔", "毛笔", "单线笔", "蜡笔"]
        for (index, name) in pens.enumerated() {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 8), "工具栏里没有「\(name)」")
            button.tap()
            usleep(400_000)
            XCTAssertEqual(button.value as? String, "已选中", "点了「\(name)」却没选中")

            let y = 0.30 + CGFloat(index) * 0.09
            let before = inkPixels(region: paperRegion)
            stroke(app, from: CGVector(dx: 0.28, dy: y), to: CGVector(dx: 0.74, dy: y + 0.05))
            usleep(1_100_000)
            let after = inkPixels(region: paperRegion)

            XCTAssertGreaterThan(after - before, 120,
                                 "「\(name)」画不出墨（before=\(before) after=\(after)）")
        }
    }

    // MARK: - 4. 旋转设备之后墨迹还在、还能写

    func test04_rotate_keepsInk_andStillDraws() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        let drawn = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.34),
                                   to: CGVector(dx: 0.76, dy: 0.44))
        XCTAssertGreaterThan(drawn, 200, "旋转之前就写不出墨")
        let before = inkPixels(region: paperRegion)

        let original = XCUIDevice.shared.orientation
        // 转去竖屏：布局要整体重排（画布 bounds 变了），最容易在这里丢内容
        XCUIDevice.shared.orientation = original == .portrait ? .landscapeLeft : .portrait
        usleep(3_000_000)

        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15),
                      "旋转之后编辑器消失了（可能崩了）")
        XCTAssertTrue(waitForPageIndicator(app, timeout: 10), "旋转之后页码不见了，布局没恢复")

        let rotated = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(rotated + 300, before,
                                    "旋转之后纸上的墨迹少了（\(before) → \(rotated)）")

        // 旋转后的坐标系里仍然能写
        let gained = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.52),
                                    to: CGVector(dx: 0.72, dy: 0.60))
        XCTAssertGreaterThan(gained, 150, "旋转之后写不出墨")

        // 转回去，别把状态留给后面的用例
        XCUIDevice.shared.orientation = original
        usleep(2_000_000)
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15),
                      "转回原方向之后编辑器消失了")
    }

    // MARK: - 5. 连续滚动模式下的五轮随机组合

    func test05_continuousScroll_chaosRounds() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(3, in: app)              // 会自动进入连续滚动
        usleep(1_500_000)

        var rng = Round2Random(seed: 20261119)
        // 连续滚动下不再按屏幕坐标判断「有没有墨」——一屏不是一页，量到的是别的页。
        // 这里守的是：不出错、不崩、翻页状态自洽、每轮之后都还能响应。
        let tools = ["钢笔", "铅笔", "橡皮", "铅笔", "钢笔"]
        var lastPage = pageIndicator(app)

        for round in 1...5 {
            let name = tools[Int.random(in: 0..<tools.count, using: &rng)]
            if app.buttons[name].exists {
                app.buttons[name].tap()
                usleep(250_000)
            }

            // 随机画 1~3 笔（拖动工具不参与，避免把滚动和书写混在一起）
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let x1 = CGFloat.random(in: 0.26...0.40, using: &rng)
                let x2 = CGFloat.random(in: 0.58...0.80, using: &rng)
                let y1 = CGFloat.random(in: 0.28...0.68, using: &rng)
                let y2 = CGFloat.random(in: 0.28...0.68, using: &rng)
                stroke(app, from: CGVector(dx: x1, dy: y1),
                       to: CGVector(dx: x2, dy: y2), hold: 0.06)
                usleep(280_000)
            }
            usleep(700_000)

            // 随机上下滚
            let dir = Int.random(in: 0..<2, using: &rng)
            let from = dir == 0 ? CGVector(dx: 0.60, dy: 0.75) : CGVector(dx: 0.60, dy: 0.25)
            let to = dir == 0 ? CGVector(dx: 0.60, dy: 0.25) : CGVector(dx: 0.60, dy: 0.75)
            stroke(app, from: from, to: to, hold: 0.05)
            usleep(900_000)

            XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 8),
                          "第 \(round) 轮之后编辑器没响应了（崩了或卡死）")

            let page = pageIndicator(app)
            XCTAssertFalse(page.isEmpty, "第 \(round) 轮之后页码读不到了")
            // 页码必须是合法值，不能出现 "0 / 3" 或越界
            if let total = pageCount(app) {
                XCTAssertEqual(total, 4, "第 \(round) 轮之后总页数变了（\(page)）")
                let current = Int(page.split(separator: "/").first?
                    .trimmingCharacters(in: .whitespaces) ?? "")
                if let current {
                    XCTAssertTrue((1...total).contains(current),
                                  "第 \(round) 轮之后页码越界：\(page)")
                }
            }
            print("[CHAOS-R2] round \(round): tool=\(name) page=\(lastPage) → \(page)")
            lastPage = page
        }

        // 混乱完还能正常书写
        goToFirstPage(app, pageCount: 4)
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 4)
        app.buttons["钢笔"].tap()
        usleep(400_000)
        let gained = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.36),
                                    to: CGVector(dx: 0.72, dy: 0.46))
        XCTAssertGreaterThan(gained, 200, "连续滚动混乱测试之后写不出墨")
    }
}

/// 固定种子的随机数（与第一轮分开播种，保证两轮的实际序列不同）
private struct Round2Random: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> UInt64 {
        state = state &* 2862933555777941757 &+ 3037000493
        var z = state
        z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
        z = (z ^ (z >> 33)) &* 0xc4ceb9fe1a85ec53
        return z ^ (z >> 33)
    }
}
