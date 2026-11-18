import XCTest

/// 第一轮新增的混乱 / 边界用例。
///
/// 与已有的 `CanvasInteractionTests`、`EditorFeatureTests` 不重叠，专打这些还没人守的缝：
/// 拖动工具当导航用、跨页墨迹隔离、连续滚动开关往返、切后台再回来、
/// 每页都写过之后快速来回翻页。
final class ChaosRound1Tests: NoteUITestCase {

    // MARK: - 1. 拖动工具：手指划过不留墨，切回笔立刻能写

    func test01_handToolNeverInks_thenPenResumes() {
        // 手指书写必须开着：拖动工具本身就会把手指拦成「只拖不写」，
        // 不需要靠关掉手指书写来制造这个效果——之前那样写，
        // 切回钢笔后手指当然画不出字，等于自己给自己挖坑。
        //
        // 至于「拖动工具能不能翻页」不在这里测：连续滚动下手指滑动是像素级滚动，
        // 划 60% 屏不一定跨页，靠页码判断会假失败。滚动翻页由
        // CanvasInteractionTests.test02 专门覆盖（那条是单页翻页模式）。
        let app = launch(fingerDraws: true)
        openNewNote(app)

        // 先正常写一笔，确认书写链路是通的
        let first = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.32),
                                   to: CGVector(dx: 0.74, dy: 0.40))
        XCTAssertGreaterThan(first, 200, "选笔状态下就写不出墨")
        let inked = inkPixels(region: paperRegion)

        // 切到拖动工具
        let hand = app.buttons["拖动工具"]
        XCTAssertTrue(hand.waitForExistence(timeout: 8), "工具栏里没有拖动工具")
        hand.tap()
        usleep(600_000)
        XCTAssertEqual(hand.value as? String, "已选中", "点了拖动工具却没选中")

        // 手指在纸上划过：一个墨点都不能留
        let beforeDrag = inkPixels(region: wideRegion)
        stroke(app, from: CGVector(dx: 0.30, dy: 0.30), to: CGVector(dx: 0.74, dy: 0.55), hold: 0.05)
        usleep(1_000_000)
        let afterDrag = inkPixels(region: wideRegion)
        XCTAssertLessThan(abs(afterDrag - beforeDrag), 700,
                          "拖动工具下手指划过却留下了墨迹"
                          + "（\(beforeDrag) → \(afterDrag)）")
        // 页面本身也没被写花
        XCTAssertLessThan(inkPixels(region: paperRegion) - inked, 300,
                          "拖动工具下纸上多出了墨迹")

        // 切回钢笔，立刻能写（这一步是「拖动工具卡住书写」的回归防线）
        app.buttons["钢笔"].tap()
        usleep(600_000)
        XCTAssertEqual(hand.value as? String, "未选中", "切换回钢笔后拖动工具仍然选中")

        let gained = drawAndConfirm(app, from: CGVector(dx: 0.30, dy: 0.46),
                                    to: CGVector(dx: 0.74, dy: 0.56))
        XCTAssertGreaterThan(gained, 200, "从拖动工具切回钢笔后写不出墨")
    }

    // MARK: - 2. 每一页只认自己那页的墨

    func test02_inkStaysOnItsOwnPage() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(1, in: app)
        // 关掉连续滚动，回到「一屏就是一页」，这样按屏幕取样才准
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 2)

        let blankOnPage2 = inkPixels(region: paperRegion)

        // 第 1 页写一笔
        let onPage1 = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.32),
                                     to: CGVector(dx: 0.76, dy: 0.42))
        XCTAssertGreaterThan(onPage1, 200, "第 1 页写不出墨")
        let inkPage1 = inkPixels(region: paperRegion)

        // 翻到第 2 页：必须干净，第 1 页的字不能串过来
        let next = app.buttons["nextPage"]
        XCTAssertTrue(next.waitForExistence(timeout: 6), "找不到下一页按钮")
        next.tap()
        usleep(1_500_000)
        XCTAssertEqual(pageIndicator(app), "2 / 2", "没有翻到第 2 页")

        let inkPage2Before = inkPixels(region: paperRegion)
        XCTAssertLessThan(inkPage2Before, max(blankOnPage2 + 300, 450),
                          "翻到第 2 页，第 1 页的墨迹串过来了"
                          + "（newPage=\(inkPage2Before) blank=\(blankOnPage2)）")

        // 第 2 页也写一笔
        let onPage2 = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.50),
                                     to: CGVector(dx: 0.76, dy: 0.60))
        XCTAssertGreaterThan(onPage2, 200, "第 2 页写不出墨")

        // 翻回第 1 页：第 1 页那笔必须还在
        app.buttons["prevPage"].tap()
        usleep(1_500_000)
        XCTAssertEqual(pageIndicator(app), "1 / 2", "没有回到第 1 页")
        let inkBack = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(inkBack + 200, inkPage1,
                                    "翻回第 1 页，它的墨迹少了（\(inkPage1) → \(inkBack)）")
    }

    // MARK: - 3. 连续滚动开着关着来回切，字不能丢

    func test03_toggleContinuousScroll_keepsInk() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        // 单页上先写一笔，作为基准
        let drawn = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.34),
                                   to: CGVector(dx: 0.76, dy: 0.44))
        XCTAssertGreaterThan(drawn, 200, "一开始就写不出墨")
        let baseline = inkPixels(region: paperRegion)

        // 变成多页，才能动「连续滚动」这个开关
        insertPages(1, in: app)
        XCTAssertEqual(pageCount(app), 2, "插页后页数不是 2")

        // 插页会自动进连续滚动，这里显式来回切两轮
        setContinuousScroll(false, in: app)
        setContinuousScroll(true, in: app)
        setContinuousScroll(false, in: app)

        // 关掉连续滚动后回到第 1 页，墨迹应当还在
        goToFirstPage(app, pageCount: 2)
        let after = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(after + 200, baseline,
                                    "来回切连续滚动之后，第 1 页的墨迹丢了"
                                    + "（baseline=\(baseline) after=\(after)）")

        // 而且还能继续写
        let again = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.58),
                                   to: CGVector(dx: 0.76, dy: 0.66))
        XCTAssertGreaterThan(again, 200, "来回切连续滚动之后写不出墨")
    }

    // MARK: - 4. 切到后台再回来

    func test04_backgroundAndBack_keepsInk_andStillDraws() {
        let app = launch(fingerDraws: true)
        openNewNote(app)

        let drawn = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.34),
                                   to: CGVector(dx: 0.76, dy: 0.44))
        XCTAssertGreaterThan(drawn, 200, "切后台之前就写不出墨")
        let before = inkPixels(region: paperRegion)

        // 退到桌面，等几秒，再拉回前台
        XCUIDevice.shared.press(.home)
        usleep(2_500_000)
        app.activate()
        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 20),
                      "回到前台后不在编辑器里（被踢回列表或崩了）")
        usleep(2_000_000)

        let resumed = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(resumed + 250, before,
                                    "切后台再回来，纸上的墨迹少了（\(before) → \(resumed)）")

        // 回来之后画布必须还是可写的（keyboard / 手势状态没被 resume 弄乱）
        let gained = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.56),
                                    to: CGVector(dx: 0.76, dy: 0.64))
        XCTAssertGreaterThan(gained, 200, "从后台回来之后写不出墨")
    }

    // MARK: - 5. 每页都写过，然后来回快速翻

    func test05_rapidFlipAfterWritingEveryPage() {
        let app = launch(fingerDraws: true)
        openNewNote(app)
        insertPages(1, in: app)
        setContinuousScroll(false, in: app)
        goToFirstPage(app, pageCount: 2)

        // 第 1 页写
        let p1 = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.32),
                                to: CGVector(dx: 0.76, dy: 0.42))
        XCTAssertGreaterThan(p1, 200, "第 1 页写不出墨")
        let ink1 = inkPixels(region: paperRegion)

        // 第 2 页写
        app.buttons["nextPage"].tap()
        usleep(1_300_000)
        let p2 = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.52),
                                to: CGVector(dx: 0.76, dy: 0.62))
        XCTAssertGreaterThan(p2, 200, "第 2 页写不出墨")
        let ink2 = inkPixels(region: paperRegion)

        // 来回快速翻 3 轮，不加等待——重点是别把状态翻乱
        for _ in 0..<3 {
            app.buttons["prevPage"].tap()
            usleep(250_000)
            app.buttons["nextPage"].tap()
            usleep(250_000)
        }
        usleep(1_500_000)

        XCTAssertEqual(pageIndicator(app), "2 / 2", "快速翻页之后停在了错误的页")
        let ink2Again = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(ink2Again + 250, ink2,
                                    "快速翻页之后第 2 页的墨迹少了（\(ink2) → \(ink2Again)）")

        // 回到第 1 页，那边的墨迹也要在
        app.buttons["prevPage"].tap()
        usleep(1_500_000)
        XCTAssertEqual(pageIndicator(app), "1 / 2", "没有回到第 1 页")
        let ink1Again = inkPixels(region: paperRegion)
        XCTAssertGreaterThanOrEqual(ink1Again + 250, ink1,
                                    "快速翻页之后第 1 页的墨迹少了（\(ink1) → \(ink1Again)）")

        // 还能继续写
        let more = drawAndConfirm(app, from: CGVector(dx: 0.28, dy: 0.66),
                                  to: CGVector(dx: 0.76, dy: 0.74))
        XCTAssertGreaterThan(more, 200, "快速翻页之后写不出墨")
    }
}
