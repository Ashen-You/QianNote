import XCTest

/// 真实触摸驱动的交互测试：点击、书写、滚动、边界。
///
/// 单元测试能验几何（`ContinuousCanvasChaosTests`），但验不了「笔尖落下到底有没有墨」——
/// 那需要真的往屏幕上按。这里用 XCUITest 注入触摸，再用截图数墨迹像素做断言，
/// 全程黑盒，不给 App 加任何测试后门。
final class CanvasInteractionTests: NoteUITestCase {

    // MARK: - 1. 手指书写

    func test01_fingerDraw_leavesInk_andSurvivesReentry() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        let before = inkPixels(region: paperRegion)
        let gained = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.34),
                                    to: CGVector(dx: 0.78, dy: 0.46))

        let after = inkPixels(region: paperRegion)
        XCTAssertGreaterThan(gained, 250,
                             "手指在纸上拖过，却没有留下墨迹（before=\(before) after=\(after)）。"
                             + "说明画布没有接受触摸，或 drawingPolicy 仍为 pencilOnly。")

        // 退出再进入：验证墨迹已落盘并能重新合并回共享画布
        app.buttons["返回笔记列表"].tap()
        let card = app.staticTexts["未命名笔记"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "返回列表后找不到这本笔记")
        card.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15))
        usleep(900_000)

        let reentered = inkPixels(region: paperRegion)
        XCTAssertGreaterThan(reentered - before, 250,
                             "重新进入笔记后墨迹不见了（before=\(before) reentered=\(reentered)），"
                             + "说明切分 / 回写链路把笔迹丢了。")
    }

    // MARK: - 2. 手指滚动不能留下墨迹

    func test02_fingerDrag_scrollsWithoutInk() {
        let app = launch(fingerDraws: false)
        openNewNote(app)
        insertPages(3, in: app)
        goToFirstPage(app, pageCount: 4)
        let before = inkPixels(region: paperRegion)

        // 手指上滑 = 向下翻。一屏大约就是一页，单次短滑动跨不过半页，
        // 所以连划两次（真实用户也是这么翻的）
        for _ in 0..<2 {
            stroke(app, from: CGVector(dx: 0.55, dy: 0.78), to: CGVector(dx: 0.55, dy: 0.18), hold: 0.04)
            usleep(700_000)
        }
        usleep(800_000)

        let after = inkPixels(region: paperRegion)
        XCTAssertLessThan(abs(after - before), 200,
                          "手拖模式下滚动却在纸上留下了墨迹（before=\(before) after=\(after)）")
        XCTAssertNotEqual(pageIndicator(app), "1 / 4", "手指滑动没有翻页，滚动范围可能不对")
    }

    // MARK: - 3. 工具切换 / 橡皮

    func test03_toolSwitch_andEraser() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        let gained = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.34),
                                    to: CGVector(dx: 0.78, dy: 0.44))
        XCTAssertGreaterThan(gained, 250, "第一笔就没画上")
        let drawn = inkPixels(region: paperRegion)

        // 换个笔再画：墨迹必须继续增加（荧光笔是半透明的，深色像素统计不到，用铅笔）
        let pencil = app.buttons["铅笔"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 5), "找不到铅笔按钮")
        pencil.tap()
        usleep(400_000)
        stroke(app, from: CGVector(dx: 0.28, dy: 0.52), to: CGVector(dx: 0.78, dy: 0.56))
        usleep(1_000_000)
        XCTAssertGreaterThan(inkPixels(region: paperRegion), drawn, "换笔之后画不出东西")

        // 换成橡皮，来回擦刚才那笔
        let eraser = app.buttons["橡皮"]
        XCTAssertTrue(eraser.waitForExistence(timeout: 5), "找不到橡皮按钮")
        eraser.tap()
        usleep(300_000)
        let wipedBefore = inkPixels(region: paperRegion)
        stroke(app, from: CGVector(dx: 0.26, dy: 0.40), to: CGVector(dx: 0.80, dy: 0.40), hold: 0.05)
        usleep(1_000_000)
        XCTAssertLessThan(inkPixels(region: paperRegion), wipedBefore,
                          "橡皮擦过之后墨迹没有减少")
    }

    // MARK: - 4. 边界：纸面上边缘 / 下边缘 / 贯穿一笔

    func test04_boundaries_topBottomAndLongStroke() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(1, in: app)

        // 纸面最上沿（紧贴顶栏下方）
        let topRegion = CGRect(x: 0.20, y: 0.10, width: 0.70, height: 0.12)
        let topBefore = inkPixels(region: topRegion)
        stroke(app, from: CGVector(dx: 0.30, dy: 0.13), to: CGVector(dx: 0.75, dy: 0.15))
        usleep(900_000)
        XCTAssertGreaterThan(inkPixels(region: topRegion) - topBefore, 120,
                             "纸面上边缘画不出墨（贴边被裁掉了？）")

        // 一次性从纸面顶部画到底部：中间任何一段空白都说明笔迹被打断
        stroke(app, from: CGVector(dx: 0.5, dy: 0.20), to: CGVector(dx: 0.52, dy: 0.88), hold: 0.1)
        usleep(1_200_000)

        var gaps: [CGFloat] = []
        for i in 0..<8 {
            let y = 0.22 + CGFloat(i) * 0.08
            let band = CGRect(x: 0.44, y: y, width: 0.14, height: 0.06)
            if inkPixels(region: band) < 30 { gaps.append(y) }
        }
        XCTAssertTrue(gaps.isEmpty, "纵向长笔画中间出现空白（y=\(gaps)），笔迹被打断了")

        // 翻到最后一页，贴底边再画一笔
        let next = app.buttons["nextPage"]
        if next.exists, next.isEnabled {
            next.tap()
            usleep(1_200_000)
        }
        let bottomRegion = CGRect(x: 0.20, y: 0.80, width: 0.70, height: 0.12)
        let bottomBefore = inkPixels(region: bottomRegion)
        stroke(app, from: CGVector(dx: 0.30, dy: 0.86), to: CGVector(dx: 0.75, dy: 0.88))
        usleep(1_000_000)
        XCTAssertGreaterThan(inkPixels(region: bottomRegion) - bottomBefore, 120,
                             "靠底边画不出墨")
    }

    // MARK: - 5. 五轮混乱测试

    func test05_chaosFiveRounds() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(4, in: app)

        var rng = SeededRandom(seed: 20261118)
        let tools = ["钢笔", "荧光笔", "橡皮", "套索", "铅笔"]
        var lastInk = inkPixels(region: paperRegion)

        for round in 1...5 {
            // 随机点工具
            let name = tools[Int.random(in: 0..<tools.count, using: &rng)]
            let button = app.buttons[name]
            if button.exists {
                button.tap()
                usleep(200_000)
            }

            // 随机画 1~3 笔
            let strokes = Int.random(in: 1...3, using: &rng)
            for _ in 0..<strokes {
                let x1 = CGFloat.random(in: 0.24...0.42, using: &rng)
                let x2 = CGFloat.random(in: 0.55...0.82, using: &rng)
                let y1 = CGFloat.random(in: 0.30...0.70, using: &rng)
                let y2 = CGFloat.random(in: 0.30...0.70, using: &rng)
                stroke(app, from: CGVector(dx: x1, dy: y1),
                       to: CGVector(dx: x2, dy: y2), hold: 0.06)
                usleep(250_000)
            }
            usleep(800_000)

            // 随机翻页（页码按钮），走一遍边界
            let forward = app.buttons["nextPage"]
            if forward.exists, forward.isEnabled, Int.random(in: 0..<2, using: &rng) == 0 {
                forward.tap()
                usleep(700_000)
            }

            // 每轮都必须还活着、还能响应
            XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 8),
                          "第 \(round) 轮之后编辑器没响应了（可能崩了或卡死）")
            let now = inkPixels(region: paperRegion)
            XCTAssertGreaterThan(now, 0, "第 \(round) 轮后页面一片空白")
            if name != "橡皮" {
                XCTAssertGreaterThanOrEqual(now + 200, lastInk,
                                            "第 \(round) 轮：用 \(name) 画完墨迹反而少了（\(lastInk) → \(now)）")
            }
            lastInk = now
            print("[CHAOS] round \(round): tool=\(name) strokes=\(strokes) ink=\(now) page=\(pageIndicator(app))")
        }
    }

    // MARK: - 6. 拖动工具：与笔互斥，且永远不落墨

    func test06_handTool_isExclusiveWithPens_andNeverLeavesInk() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        // 先正常写一笔，确认书写链路本身是通的
        let first = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.34),
                                   to: CGVector(dx: 0.78, dy: 0.42))
        XCTAssertGreaterThan(first, 250, "选笔状态下写不出墨")
        let inked = inkPixels(region: paperRegion)

        // 选中拖动工具
        let hand = app.buttons["拖动工具"]
        XCTAssertTrue(hand.exists, "工具栏里没有拖动工具")
        hand.tap()
        usleep(500_000)
        XCTAssertEqual(hand.value as? String, "已选中", "点了拖动工具却没有选中")
        XCTAssertNotEqual(app.buttons["钢笔"].value as? String, "已选中",
                          "拖动工具和笔同时处于选中态（应是互斥的）")

        // 拖动状态下，笔划过去不该留下任何墨
        stroke(app, from: CGVector(dx: 0.30, dy: 0.30), to: CGVector(dx: 0.75, dy: 0.55), hold: 0.05)
        usleep(1_000_000)
        XCTAssertLessThan(inkPixels(region: paperRegion) - inked, 200,
                          "拖动工具下划动却留下了墨迹")

        // 点任意一支笔 → 立刻回到书写，拖动工具自动让位
        app.buttons["钢笔"].tap()
        usleep(500_000)
        XCTAssertEqual(hand.value as? String, "未选中", "换成笔之后拖动工具仍然选中")
        let resumed = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.58),
                                     to: CGVector(dx: 0.78, dy: 0.66))
        XCTAssertGreaterThan(resumed, 250, "从拖动工具切回笔之后写不出墨")
    }
}

/// 固定种子的随机数，保证混乱测试可复现
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
