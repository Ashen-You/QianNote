import XCTest

/// 真实触摸驱动的交互测试：点击、书写、滚动、边界。
///
/// 判定方式走 App 内的 `InkProbe`（`-uiTestProbe` 启动参数打开）：
/// 读 PencilKit 画布的真实状态（笔画数 / 墨迹总长度），而不是截屏数深色像素。
///
/// 为什么放弃像素法：
///   - 慢：一次断言抓一张全屏图转灰度，0.5~1.5s；改成读 a11y 只要几十毫秒
///   - 脆：读数绑死采样矩形，笔迹画在矩形外就报"一片空白"（连续滚动、贴边、
///     换工具后颜色变浅都会踩到）
///   - 盲：只知道屏幕某块黑没黑，说不清笔迹落在哪一页
///
/// 现在只有真正需要"看屏幕"的东西才截图（比如确认没有残留的界面元素）。
final class CanvasInteractionTests: NoteUITestCase {

    // MARK: - 1. 手指书写 + 落盘

    func test01_fingerDraw_leavesInk_andSurvivesReentry() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        XCTAssertEqual(inkState(app).length, 0, "新笔记一进来就有墨迹，起点不干净")

        let gained = drawStroke(app, from: CGVector(dx: 0.28, dy: 0.34),
                                to: CGVector(dx: 0.78, dy: 0.46))
        XCTAssertGreaterThan(gained, 80,
                             "手指在纸上拖过却没有墨（长度增量 \(gained)）。"
                             + "说明画布没接受触摸，或 drawingPolicy 仍是 pencilOnly。")

        let written = inkState(app).length

        // 退出再进入：验证墨迹已落盘并能重新合并回共享画布
        app.buttons["返回笔记列表"].tap()
        let card = noteCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "返回列表后找不到这本笔记")
        card.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15))

        let reentered = waitForInk(app) { $0.length > 0 }
        XCTAssertEqual(reentered.length, written, accuracy: max(8, written / 20),
                       "重新进入后墨迹长度变了（\(written) → \(reentered.length)），"
                       + "说明切分 / 回写链路改写了笔迹")
    }

    // MARK: - 2. 手指滚动不能留下墨迹

    func test02_fingerDrag_scrollsWithoutInk() {
        let app = launch(fingerDraws: false)
        openNewNote(app, rename: false)
        insertPages(3, in: app)
        goToFirstPage(app, pageCount: 4)
        XCTAssertEqual(inkState(app).length, 0, "滚动前就不该有墨")

        // 手指上滑 = 向下翻。一屏大约就是一页，单次短滑动跨不过半页，
        // 所以连划两次（真实用户也是这么翻的）
        for _ in 0..<2 {
            stroke(app, from: CGVector(dx: 0.55, dy: 0.78), to: CGVector(dx: 0.55, dy: 0.18), hold: 0.04)
            usleep(500_000)
        }

        let after = waitForInk(app, timeout: 3) { _ in true }
        XCTAssertEqual(after.length, 0,
                       "手指书写关闭时，滚动却在纸上留了墨（\(after.summary)）")
        XCTAssertNotEqual(pageIndicator(app), "1 / 4", "手指滑动没有翻页，滚动范围可能不对")
    }

    // MARK: - 3. 换笔 / 橡皮

    func test03_toolSwitch_andEraser() {
        let app = launch(fingerDraws: true)
        openNewNote(app, rename: false)

        let first = drawStroke(app, from: CGVector(dx: 0.28, dy: 0.34),
                               to: CGVector(dx: 0.78, dy: 0.44))
        XCTAssertGreaterThan(first, 80, "第一笔就没画上")
        let penInk = inkState(app).length

        // 换铅笔再画：长度必须继续增加
        app.buttons["铅笔"].tap()
        XCTAssertEqual(app.buttons["铅笔"].value as? String, "已选中", "铅笔没被选中")
        let second = drawStroke(app, from: CGVector(dx: 0.28, dy: 0.50),
                                to: CGVector(dx: 0.78, dy: 0.54))
        XCTAssertGreaterThan(second, 80, "换笔之后画不出东西（增量 \(second)）")
        let bothInk = inkState(app).length
        XCTAssertGreaterThan(bothInk, penInk, "换笔后墨迹没有累加")

        // 换成橡皮，横着擦过两笔：长度必须减少
        app.buttons["橡皮"].tap()
        XCTAssertEqual(app.buttons["橡皮"].value as? String, "已选中", "橡皮没被选中")
        stroke(app, from: CGVector(dx: 0.26, dy: 0.40), to: CGVector(dx: 0.80, dy: 0.40), hold: 0.05)
        let erased = waitForInk(app, timeout: 5) { $0.length < bothInk }
        XCTAssertLessThan(erased.length, bothInk,
                          "橡皮擦过之后墨迹长度没减少（\(bothInk) → \(erased.length)）")
    }

    // MARK: - 4. 边界：纸面上沿 / 贯穿一笔 / 靠底边

    func test04_boundaries_topBottomAndLongStroke() {
        let app = launch(fingerDraws: true)
        openNewNote(app, rename: false)

        // 纸面靠上沿（顶栏浮层下方）
        let top = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.13),
                             to: CGVector(dx: 0.75, dy: 0.15))
        XCTAssertGreaterThan(top, 60, "纸面上沿画不出墨（贴边被裁掉了？）")

        // 一次性从纸面上部画到下部：笔迹必须是一条连续的线，
        // 用长度判断比"分段数空白"稳——长度接近直线距离才说明没被打断
        let before = inkState(app).length
        stroke(app, from: CGVector(dx: 0.5, dy: 0.20), to: CGVector(dx: 0.52, dy: 0.82), hold: 0.1)
        let after = waitForInk(app, timeout: 5) { $0.length > before + 200 }
        let longStroke = after.length - before
        XCTAssertGreaterThan(longStroke, 300,
                             "纵向长笔画只落了 \(longStroke) 点长度，笔迹被打断了")

        // 靠底边再画一笔（偏左，避开底部居中的页码胶囊）
        let bottom = drawStroke(app, from: CGVector(dx: 0.26, dy: 0.84),
                                to: CGVector(dx: 0.55, dy: 0.86))
        XCTAssertGreaterThan(bottom, 60, "靠底边画不出墨")
    }

    // MARK: - 5. 五轮混乱测试

    func test05_chaosFiveRounds() {
        let app = launch(fingerDraws: true)
        openNewNote(app, rename: false)
        insertPages(4, in: app)
        // 插页会自动进连续滚动；这里退回单页翻页模式，让页码断言有意义
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 5)

        var rng = SeededRandom(seed: 20261118)
        let tools = ["钢笔", "荧光笔", "橡皮", "套索", "铅笔"]
        var lastLength = 0
        // 探针只反映「当前页」的墨迹；翻页之后和上一轮的数字没有可比性
        var lastPage = pageIndicator(app)

        for round in 1...5 {
            let name = tools[Int.random(in: 0..<tools.count, using: &rng)]
            let button = app.buttons[name]
            if button.exists {
                button.tap()
                usleep(150_000)
            }

            // 随机画 1~3 笔。用探针读长度，画在纸面哪个位置都不影响判定
            let beforeLen = inkState(app).length
            let count = Int.random(in: 1...3, using: &rng)
            for _ in 0..<count {
                let x1 = CGFloat.random(in: 0.26...0.40, using: &rng)
                let x2 = CGFloat.random(in: 0.56...0.80, using: &rng)
                let y1 = CGFloat.random(in: 0.32...0.42, using: &rng)
                let y2 = CGFloat.random(in: 0.46...0.55, using: &rng)
                stroke(app, from: CGVector(dx: x1, dy: y1),
                       to: CGVector(dx: x2, dy: y2), hold: 0.06)
                usleep(150_000)
            }
            // 探针在抬笔 / 落盘后才更新，最后一次抬笔可能晚于固定 300ms；
            // 深色笔用「长度真的变长」当条件，其他工具只等画布响应一下。
            let now: InkState
            if name == "钢笔" || name == "铅笔" {
                now = waitForInk(app, timeout: 3) { $0.length > beforeLen + 20 }
            } else {
                now = waitForInk(app, timeout: 1) { _ in true }
            }
            // 页码必须跟着读数一起取：下面可能随机翻页，翻页后探针读数仍属于旧页，
            // 用翻页后的页码去比较就会拿 A 页的总长要求 B 页
            let pageNow = pageIndicator(app)

            // 随机翻页，走一遍边界
            let forward = app.buttons["nextPage"]
            if forward.exists, forward.isEnabled, Int.random(in: 0..<2, using: &rng) == 0 {
                forward.tap()
                usleep(400_000)
            }

            // 每轮都必须还活着、还能响应
            XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 8),
                          "第 \(round) 轮之后编辑器没响应了（可能崩了或卡死）")

            // 只有深色笔能保证"写了一定变长"：荧光笔太浅但也会记账、
            // 橡皮会变短、套索只是框选。所以只对钢笔/铅笔做单调断言。
            // 同页才比较长度；翻到别的页后重建基线，否则会拿 A 页的总长去要求 B 页。
            if name == "钢笔" || name == "铅笔" {
                XCTAssertGreaterThan(now.length, 0,
                                     "第 \(round) 轮：用 \(name) 画完，画布上一笔都没有")
                if pageNow == lastPage {
                    XCTAssertGreaterThanOrEqual(now.length + 50, lastLength,
                                                "第 \(round) 轮：用 \(name) 画完墨迹反而变少了"
                                                + "（\(lastLength) → \(now.length)，\(pageNow)）")
                }
                lastLength = now.length
                lastPage = pageNow
            }
            print("[CHAOS] round \(round): tool=\(name) strokes=\(count) \(now.summary) page=\(pageIndicator(app))")
        }
    }

    // MARK: - 6. 拖动工具：与笔互斥，且永远不落墨

    func test06_handTool_isExclusiveWithPens_andNeverLeavesInk() {
        let app = launch(fingerDraws: true)
        openNewNote(app, rename: false)

        let first = drawStroke(app, from: CGVector(dx: 0.28, dy: 0.34),
                               to: CGVector(dx: 0.78, dy: 0.42))
        XCTAssertGreaterThan(first, 80, "选笔状态下写不出墨")
        let inked = inkState(app).length

        // 选中拖动工具
        let hand = app.buttons["拖动工具"]
        XCTAssertTrue(hand.exists, "工具栏里没有拖动工具")
        hand.tap()
        XCTAssertEqual(hand.value as? String, "已选中", "点了拖动工具却没有选中")
        XCTAssertNotEqual(app.buttons["钢笔"].value as? String, "已选中",
                          "拖动工具和笔同时处于选中态（应是互斥的）")

        // 拖动状态下，笔划过去不该留下任何墨
        stroke(app, from: CGVector(dx: 0.30, dy: 0.30), to: CGVector(dx: 0.75, dy: 0.55), hold: 0.05)
        usleep(600_000)
        XCTAssertEqual(inkState(app).length, inked,
                       "拖动工具下划动却写上了字（\(inked) → \(inkState(app).length)）")

        // 点任意一支笔 → 立刻回到书写，拖动工具自动让位
        app.buttons["钢笔"].tap()
        XCTAssertEqual(hand.value as? String, "未选中", "换成笔之后拖动工具仍然选中")
        let resumed = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.50),
                                 to: CGVector(dx: 0.72, dy: 0.56))
        XCTAssertGreaterThan(resumed, 80, "从拖动工具切回笔之后写不出墨")
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
