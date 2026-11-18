import XCTest

/// UI 测试公共基类。
///
/// 全部用例都是黑盒：真实触摸注入 + 截图数像素，不给 App 加任何测试后门。
/// 这样做的好处是「用户能做的操作，测试就能做」，坏处是慢——所以断言尽量粗粒度
/// （比如「墨迹变多了」而不是「多了 137 个像素」）。
class NoteUITestCase: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 启动

    /// 启动 App。
    ///
    /// `fingerDraws` 用 UserDefaults 的启动参数域注入（优先级最高），
    /// 避免测试之间互相污染磁盘上的开关值。
    /// `extra` 用于额外钉住某些偏好，例如 `["-tool.activeTool", "pen"]`。
    func launch(fingerDraws: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tool.fingerDrawing", fingerDraws ? "YES" : "NO",
            // 拖动工具不跨启动，这里仍然钉住，避免历史值污染测试
            "-tool.activeTool", "pen"
        ] + extra
        app.launch()
        return app
    }

    // MARK: - 进编辑器

    /// 新建一本笔记并进入编辑器
    func openNewNote(_ app: XCUIApplication) {
        // 列表里攒了很多笔记时，首启会慢一些，第一次点击偶尔落空；给一次重试
        for attempt in 0..<2 {
            let emptyCreate = app.buttons["新建笔记"]
            if emptyCreate.waitForExistence(timeout: attempt == 0 ? 8 : 4) {
                emptyCreate.tap()
            } else {
                // 库里有笔记时没有空态按钮，从右上角的「新建」菜单进
                let add = app.buttons["新建"]
                XCTAssertTrue(add.waitForExistence(timeout: 15), "找不到新建入口")
                add.tap()
                XCTAssertTrue(emptyCreate.waitForExistence(timeout: 8), "「新建」菜单里没有「新建笔记」")
                emptyCreate.tap()
            }
            if app.buttons["返回笔记列表"].waitForExistence(timeout: 20) { break }
        }
        XCTAssertTrue(app.buttons["返回笔记列表"].exists, "没有进入编辑器")
        // 页码出现 = 编辑器布局完成（画布 fit 依赖真实 bounds）
        XCTAssertTrue(waitForPageIndicator(app, timeout: 15), "编辑器里没有出现页码")
        // 必须处于书写状态：停在拖动工具上时滚动 / 缩放都正常，但一笔都写不出来
        let hand = app.buttons["拖动工具"]
        XCTAssertTrue(hand.waitForExistence(timeout: 5), "工具栏里没有拖动工具")
        XCTAssertNotEqual(hand.value as? String, "已选中",
                          "进入笔记时停在拖动工具上，笔不会出墨")
        usleep(1_000_000)
    }

    @discardableResult
    func waitForPageIndicator(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !pageIndicator(app).isEmpty { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - 页管理

    /// 通过「更多」菜单插页
    func insertPages(_ count: Int, in app: XCUIApplication) {
        for _ in 0..<count {
            let more = app.buttons["更多"]
            XCTAssertTrue(more.waitForExistence(timeout: 10), "找不到「更多」菜单")
            more.tap()
            let add = app.buttons["插入新页面"]
            XCTAssertTrue(add.waitForExistence(timeout: 6), "菜单里没有「插入新页面」")
            add.tap()
            usleep(300_000)
        }
    }

    /// 点「更多」菜单里的某一项（菜单项是 Button，label 就是文案）
    func tapMoreMenu(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 6) {
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "找不到「更多」菜单")
        more.tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "菜单里没有「\(title)」")
        item.tap()
    }

    /// 插页后编辑器会自动停在末页，跳回第一页再测滚动。
    /// 不数次数：翻页动画 / 视图重建时偶尔会吞掉一次点击，
    /// 直接点到「上一页」变灰（首页时它是禁用的）为止。
    func goToFirstPage(_ app: XCUIApplication, pageCount: Int) {
        let prev = app.buttons["prevPage"]
        var steps = 0
        while prev.exists, prev.isEnabled, steps < pageCount + 4 {
            prev.tap()
            usleep(600_000)
            steps += 1
        }
        usleep(500_000)
        XCTAssertEqual(pageIndicator(app), "1 / \(pageCount)", "没有回到第一页")
    }

    /// 翻到最后一页（「下一页」变灰为止）
    func goToLastPage(_ app: XCUIApplication) {
        let next = app.buttons["nextPage"]
        var steps = 0
        while next.exists, next.isEnabled, steps < 40 {
            next.tap()
            usleep(600_000)
            steps += 1
        }
        usleep(500_000)
    }

    // MARK: - 画

    /// 按归一化坐标画一笔
    func stroke(_ app: XCUIApplication,
                from: CGVector,
                to: CGVector,
                hold: TimeInterval = 0.12) {
        let a = app.coordinate(withNormalizedOffset: from)
        let b = app.coordinate(withNormalizedOffset: to)
        a.press(forDuration: hold, thenDragTo: b)
    }

    /// 画一笔并确认真的有墨（首次可能被退场动画吃掉，重试一次）
    @discardableResult
    func drawAndConfirm(_ app: XCUIApplication,
                        from: CGVector, to: CGVector) -> Int {
        let before = inkPixels(region: paperRegion)
        stroke(app, from: from, to: to)
        usleep(1_200_000)
        if inkPixels(region: paperRegion) - before < 60 {
            stroke(app, from: from, to: to)
            usleep(1_200_000)
        }
        return inkPixels(region: paperRegion) - before
    }

    /// 页面中部的书写区域（避开顶栏、左工具栏、底栏）
    let paperRegion = CGRect(x: 0.20, y: 0.28, width: 0.70, height: 0.30)

    // MARK: - 量

    /// 统计一块区域里的深色像素数（墨迹越多值越大）
    func inkPixels(region: CGRect, threshold: UInt8 = 120) -> Int {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return -1 }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: region.minX * w, y: region.minY * h,
                          width: region.width * w, height: region.height * h).integral
        guard let crop = cg.cropping(to: rect) else { return -1 }
        let cw = crop.width, ch = crop.height
        guard cw > 0, ch > 0 else { return -1 }
        var buf = [UInt8](repeating: 255, count: cw * ch)
        guard let ctx = CGContext(data: &buf, width: cw, height: ch,
                                  bitsPerComponent: 8, bytesPerRow: cw,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return -1 }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        return buf.reduce(into: 0) { if $1 < threshold { $0 += 1 } }
    }

    /// 底栏页码，形如 "1 / 4"。
    /// 只认底栏那个带 identifier 的文本——界面上别处也有 "N / M" 样式的文字，
    /// 按内容模糊匹配会读串（曾经因此误判「翻页没生效」「墨迹丢了」）。
    func pageIndicator(_ app: XCUIApplication) -> String {
        let el = app.staticTexts["pageIndicator"]
        guard el.exists else { return "" }
        return el.label
    }

    /// 当前页数（从底栏页码解析），解析不出来返回 nil
    func pageCount(_ app: XCUIApplication) -> Int? {
        let parts = pageIndicator(app).split(separator: "/")
        guard parts.count == 2,
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return total
    }
}
