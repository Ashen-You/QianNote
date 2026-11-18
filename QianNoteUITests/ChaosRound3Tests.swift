import XCTest

/// 第三轮混乱用例：触摸归属 / 工具切换 / 撤销栈 / 连续滚动。
///
/// 上一轮已经覆盖了「每页写完再进都在」，这一轮专攻交互状态机：
/// 笔和拖动工具来回切、pencilOnly 下手指绝不能落墨、连续撤销重做、
/// 多页随机跳转后每页仍只认自己的墨，以及连续滚动里反复「滚 + 写」的收敛性。
final class ChaosRound3Tests: NoteUITestCase {

    // MARK: - 1. 连续滚动下笔 / 拖动工具交替，墨只在笔的那几轮涨

    func test01_handPenAlternation_continuous() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(1, in: app)          // 2 页，自动进入连续滚动

        let mode = app.staticTexts["modeProbe"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "找不到模式探针")
        XCTAssertEqual(mode.label, "continuous=1", "两页笔记没有进入连续滚动")

        var rng = Round3Random(seed: 301)
        var penStrokes = 0

        for round in 1...6 {
            if round % 2 == 1 {
                // 笔的回合：必须出墨，且全局墨迹只增不减
                let pen = app.buttons["钢笔"]
                XCTAssertTrue(pen.waitForExistence(timeout: 8), "找不到钢笔")
                pen.tap()
                usleep(400_000)
                XCTAssertEqual(pen.value as? String, "已选中", "第 \(round) 轮钢笔没选中")

                let before = inkState(app).length
                let y = CGFloat.random(in: 0.30...0.52, using: &rng)
                let gained = drawStroke(app, from: CGVector(dx: 0.28, dy: y),
                                        to: CGVector(dx: 0.72, dy: y + 0.08))
                XCTAssertGreaterThan(gained, 20, "第 \(round) 轮（笔）写不出墨")
                let after = inkState(app)
                XCTAssertGreaterThan(after.length, before,
                                     "第 \(round) 轮（笔）之后全局墨迹没有增加")
                penStrokes += 1
            } else {
                // 拖动的回合：手指划过只许滚动，不许落墨
                let hand = app.buttons["拖动工具"]
                XCTAssertTrue(hand.waitForExistence(timeout: 8), "找不到拖动工具")
                hand.tap()
                usleep(500_000)
                XCTAssertEqual(hand.value as? String, "已选中", "第 \(round) 轮拖动工具没选中")

                let before = inkState(app).length
                let upward = Bool.random(using: &rng)
                stroke(app, from: CGVector(dx: 0.60, dy: upward ? 0.72 : 0.30),
                       to: CGVector(dx: 0.60, dy: upward ? 0.30 : 0.72), hold: 0.05)
                usleep(1_000_000)
                let after = inkState(app).length
                XCTAssertLessThanOrEqual(after, before + 5,
                                         "第 \(round) 轮（拖动工具）手指划过却留下了墨"
                                         + "（\(before) → \(after)）")
            }
            print("[CHAOS-R3-1] round \(round): \(inkState(app).summary) page=\(pageIndicator(app))")
        }

        XCTAssertEqual(penStrokes, 3, "笔的回合数不对")
        XCTAssertTrue(app.buttons["返回笔记列表"].exists, "六轮交替之后编辑器不见了")
        XCTAssertGreaterThan(inkState(app).length, 0, "六轮交替之后墨迹归零")

        // 切回笔还能继续写（状态机没有卡在拖动工具上）
        app.buttons["钢笔"].tap()
        usleep(400_000)
        let tail = drawStroke(app, from: CGVector(dx: 0.30, dy: 0.58),
                              to: CGVector(dx: 0.70, dy: 0.64))
        XCTAssertGreaterThan(tail, 20, "交替测试结束时切回钢笔写不出墨")
    }

    // MARK: - 2. 关掉手指书写（pencilOnly）：手指怎么划都不许出墨

    func test02_pencilOnly_fingersNeverInk() {
        // 关闭手指书写后，测试注入的直接触（手指）在任何工具下都不该落墨。
        // 这条守的是触摸归属：画布可以接住触摸，但 drawingPolicy 必须把手指挡住。
        let app = launch(fingerDraws: false)
        openNewNote(app)
        insertPages(1, in: app)

        // 笔模式下手指划三次：一次墨都不能有
        for round in 1...3 {
            stroke(app, from: CGVector(dx: 0.30, dy: 0.32 + CGFloat(round) * 0.08),
                   to: CGVector(dx: 0.72, dy: 0.38 + CGFloat(round) * 0.08), hold: 0.05)
            usleep(700_000)
            XCTAssertEqual(inkState(app).length, 0,
                           "pencilOnly 下第 \(round) 次手指书写却出了墨")
        }

        // 拖动工具下同样不许出墨
        let hand = app.buttons["拖动工具"]
        XCTAssertTrue(hand.waitForExistence(timeout: 8), "找不到拖动工具")
        hand.tap()
        usleep(500_000)
        stroke(app, from: CGVector(dx: 0.60, dy: 0.70), to: CGVector(dx: 0.60, dy: 0.30), hold: 0.05)
        usleep(800_000)
        XCTAssertEqual(inkState(app).length, 0, "pencilOnly + 拖动工具下手指划出了墨")

        // 回到笔模式，手指依然不能写（这一步曾把 Pencil 误判成手指放走）
        app.buttons["钢笔"].tap()
        usleep(500_000)
        stroke(app, from: CGVector(dx: 0.32, dy: 0.46), to: CGVector(dx: 0.70, dy: 0.54), hold: 0.05)
        usleep(800_000)
        XCTAssertEqual(inkState(app).length, 0, "pencilOnly 下切回钢笔后手指仍然出了墨")

        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 8),
                      "三次划动之后编辑器没响应了")
        XCTAssertFalse(pageIndicator(app).isEmpty, "页码读不到了")
    }

    // MARK: - 3. 连写三笔后连续撤销两次、再重做两次

    func test03_undoRedoWalk() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)

        var lengths: [Int] = []
        for index in 0..<3 {
            let y = 0.30 + CGFloat(index) * 0.12
            let gained = drawStroke(app, from: CGVector(dx: 0.28, dy: y),
                                    to: CGVector(dx: 0.74, dy: y + 0.07))
            XCTAssertGreaterThan(gained, 20, "第 \(index + 1) 笔没写出来")
            lengths.append(inkState(app).length)
        }
        let full = lengths[2]
        XCTAssertGreaterThan(full, lengths[0], "三笔之后墨迹长度没有累计增长")

        let undo = app.buttons["撤销"]
        let redo = app.buttons["重做"]
        XCTAssertTrue(undo.waitForExistence(timeout: 6), "找不到撤销按钮")
        XCTAssertTrue(undo.isEnabled, "写完三笔之后撤销是灰的")

        // 撤销两次：长度必须单调回落，但第一笔要留着。
        // 撤销会让画布重绘，落定前再点一次可能被吞（实测第二次点击就这么丢过），
        // 没生效就用同一入口补点一次，再断言。
        var shrinking = full
        for step in 1...2 {
            var after = inkState(app)
            for _ in 0..<2 {
                undo.tap()
                after = waitForInk(app, timeout: 4) { $0.length < shrinking - 10 }
                if after.length < shrinking - 10 { break }
                usleep(800_000)
            }
            XCTAssertLessThan(after.length, shrinking,
                              "第 \(step) 次撤销之后墨迹没有减少（\(shrinking) → \(after.length)）")
            shrinking = after.length
            usleep(900_000)
        }
        XCTAssertGreaterThan(shrinking, 0, "撤销两次把三笔全撤没了（第一笔不该动）")

        // 重做两次：回到三笔的完整长度（同样允许一次点击被动画吞掉）
        XCTAssertTrue(redo.waitForExistence(timeout: 6), "找不到重做按钮")
        let tolerance = max(15, full / 10)
        for _ in 0..<4 {
            if abs(inkState(app).length - full) <= tolerance { break }
            if redo.isEnabled { redo.tap() }
            usleep(1_000_000)
        }
        let restored = waitForInk(app, timeout: 4) {
            abs($0.length - full) <= tolerance
        }
        XCTAssertLessThanOrEqual(abs(restored.length - full), tolerance,
                                 "重做两次之后没有回到撤销前的墨迹"
                                 + "（完整=\(full) 现在=\(restored.length)）")
    }

    // MARK: - 4. 三页随机跳转，每页只认自己的墨

    func test04_randomPageHopping_keepsPageInk() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)
        insertPages(2, in: app)          // 3 页
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 3)

        // 每页写一笔，y 各不相同：落错页时探针长度会对不上
        var expected: [Int: Int] = [:]
        for page in 1...3 {
            let y = 0.30 + CGFloat(page - 1) * 0.12
            let gained = drawStroke(app, from: CGVector(dx: 0.30, dy: y),
                                    to: CGVector(dx: 0.72, dy: y + 0.06))
            XCTAssertGreaterThan(gained, 20, "第 \(page) 页写不出墨")
            let len = inkState(app).length
            XCTAssertGreaterThan(len, 20, "第 \(page) 页探针读不到墨")
            expected[page] = len
            if page < 3 {
                let next = app.buttons["nextPage"]
                XCTAssertTrue(next.exists && next.isEnabled, "第 \(page) 页时下一页不可用")
                next.tap()
                usleep(1_200_000)
                XCTAssertEqual(pageIndicator(app), "\(page + 1) / 3", "没有翻到第 \(page + 1) 页")
            }
        }

        var rng = Round3Random(seed: 302)
        var page = 3
        for round in 1...6 {
            let target = Int.random(in: 1...3, using: &rng)
            guard target != page else { continue }
            let button = app.buttons[target > page ? "nextPage" : "prevPage"]
            XCTAssertTrue(button.exists && button.isEnabled,
                          "第 \(round) 轮：\(page) → \(target) 的翻页按钮不可用")
            button.tap()
            usleep(1_200_000)
            XCTAssertEqual(pageIndicator(app), "\(target) / 3",
                           "第 \(round) 轮实际页与目标页不符")
            page = target

            let want = expected[target] ?? -1
            let got = waitForInk(app, timeout: 4) {
                abs($0.length - want) <= max(10, want / 10)
            }
            XCTAssertLessThanOrEqual(abs(got.length - want), max(10, want / 10),
                                     "第 \(round) 轮回到第 \(target) 页，墨迹对不上"
                                     + "（应有=\(want) 实际=\(got.length)）")
            print("[CHAOS-R3-4] round \(round): page=\(pageIndicator(app)) \(got.summary)")
        }

        XCTAssertTrue(app.buttons["返回笔记列表"].exists, "随机跳页之后编辑器不见了")
    }

    // MARK: - 5. 连续滚动里六轮「滚一下 + 写一笔」，墨迹只增不减

    func test05_continuous_scrollAndDraw_monotonic() {
        let app = launch(fingerDraws: true, extra: ["-tool.shapeRecognition", "NO"])
        openNewNote(app)
        insertPages(3, in: app)          // 4 页，自动进入连续滚动
        usleep(1_200_000)

        var rng = Round3Random(seed: 303)
        var total = inkState(app).length

        for round in 1...6 {
            // 随机上下滚一段（手指书写开着，笔模式下手指会落墨——所以先切拖动工具滚）
            let hand = app.buttons["拖动工具"]
            XCTAssertTrue(hand.waitForExistence(timeout: 8), "找不到拖动工具")
            hand.tap()
            usleep(350_000)
            let upward = Bool.random(using: &rng)
            stroke(app, from: CGVector(dx: 0.60, dy: upward ? 0.74 : 0.26),
                   to: CGVector(dx: 0.60, dy: upward ? 0.26 : 0.74), hold: 0.05)
            usleep(800_000)

            // 切回钢笔写一笔，全局墨迹必须增加
            let pen = app.buttons["钢笔"]
            pen.tap()
            usleep(350_000)
            let before = inkState(app).length
            let x1 = CGFloat.random(in: 0.26...0.40, using: &rng)
            let x2 = CGFloat.random(in: 0.58...0.80, using: &rng)
            let y = CGFloat.random(in: 0.30...0.62, using: &rng)
            let gained = drawStroke(app, from: CGVector(dx: x1, dy: y),
                                    to: CGVector(dx: x2, dy: y + 0.05))
            XCTAssertGreaterThan(gained, 20, "第 \(round) 轮滚动之后写不出墨")
            let now = inkState(app).length
            XCTAssertGreaterThan(now, before, "第 \(round) 轮之后全局墨迹没有增加")
            XCTAssertGreaterThanOrEqual(now, total, "第 \(round) 轮之后全局墨迹反而减少了")
            total = now

            // 页码必须合法（连续滚动下页数固定 4）
            XCTAssertTrue(app.buttons["返回笔记列表"].exists,
                          "第 \(round) 轮之后编辑器没响应了")
            XCTAssertEqual(pageCount(app), 4, "第 \(round) 轮之后总页数变了")
            if let current = currentPageNumber(app) {
                XCTAssertTrue((1...4).contains(current),
                              "第 \(round) 轮之后页码越界：\(pageIndicator(app))")
            } else {
                XCTFail("第 \(round) 轮之后页码读不到")
            }
            print("[CHAOS-R3-5] round \(round): \(inkState(app).summary) page=\(pageIndicator(app))")
        }

        // 退出重进：整本墨迹还在
        app.buttons["返回笔记列表"].tap()
        usleep(900_000)
        let card = noteCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "回列表找不到笔记")
        card.tap()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 15), "没能重新进入笔记")
        usleep(2_000_000)
        setContinuousScroll(true, in: app)
        let kept = waitForInk(app, timeout: 10) { $0.length >= total - 20 }
        XCTAssertGreaterThanOrEqual(kept.length, total - 20,
                                    "重进之后连续滚动的整本墨迹丢了"
                                    + "（退出前=\(total) 现在=\(kept.length)）")
    }

    // MARK: - 小工具

    private func currentPageNumber(_ app: XCUIApplication) -> Int? {
        Int(pageIndicator(app).split(separator: "/").first?
            .trimmingCharacters(in: .whitespaces) ?? "")
    }
}

/// 固定种子的随机数（与第一、二轮分开播种）
private struct Round3Random: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
        z = (z ^ (z >> 33)) &* 0xc4ceb9fe1a85ec53
        return z ^ (z >> 33)
    }
}
