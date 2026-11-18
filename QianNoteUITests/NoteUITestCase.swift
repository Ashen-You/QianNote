import XCTest
import ObjectiveC

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
            "-tool.activeTool", "pen",
            // 打开画布状态探针：断言直接读真实笔画数，不再截屏数像素
            "-uiTestProbe",
            // 每条用例从空存储开始，避免上次失败残留的同名笔记让查询匹配到多个元素
            "-uiTestResetData",
            // 动画跑快一点，减少真实等待（不关动画：PencilKit 落笔依赖它）
            "-UIAnimationDragCoefficient", "0.01"
        ] + extra
        app.launch()
        app.skipQuiescenceWaits()
        return app
    }

    // MARK: - 进编辑器

    /// 当前用例创建的这本笔记的标题。
    ///
    /// 每条用例都用一个独一无二的标题（见 `uniqueTitle()`），原因是模拟器上的
    /// 笔记会一轮轮累积：早先生成的都叫「未命名笔记」，回列表里按这个名字找卡片
    /// 会匹配到十几本，XCUITest 直接抛 "Multiple matching elements found"。
    /// 那不叫测试失败，那叫测试自己找不着北。
    private(set) var noteTitle = ""

    /// 新建一本笔记并进入编辑器
    func openNewNote(_ app: XCUIApplication, rename: Bool = true) {
        // 先看右上角有没有「新建」：库里有笔记时是常态，
        // 反过来等「新建笔记」空态按钮会白等满 8 秒（这一条曾占单例 10% 时间）
        let add = app.buttons["新建"]
        if add.waitForExistence(timeout: 3) {
            add.tap()
            let create = app.buttons["新建笔记"]
            XCTAssertTrue(create.waitForExistence(timeout: 8), "「新建」菜单里没有「新建笔记」")
            create.tap()
        } else {
            let emptyCreate = app.buttons["新建笔记"]
            XCTAssertTrue(emptyCreate.waitForExistence(timeout: 8), "找不到新建入口")
            emptyCreate.tap()
        }

        XCTAssertTrue(app.buttons["返回笔记列表"].waitForExistence(timeout: 20), "没有进入编辑器")
        // 页码出现 = 编辑器布局完成（画布 fit 依赖真实 bounds）
        XCTAssertTrue(waitForPageIndicator(app, timeout: 15), "编辑器里没有出现页码")
        // 必须处于书写状态：停在拖动工具上时滚动 / 缩放都正常，但一笔都写不出来
        let hand = app.buttons["拖动工具"]
        XCTAssertTrue(hand.waitForExistence(timeout: 5), "工具栏里没有拖动工具")
        XCTAssertNotEqual(hand.value as? String, "已选中",
                          "进入笔记时停在拖动工具上，笔不会出墨")

        // 只有需要回列表找卡片的用例才改名；改一次要开弹窗、打字、保存，约 5 秒
        noteTitle = uniqueTitle()
        if rename { renameCurrentNote(to: noteTitle, in: app) }
    }

    /// 生成一条用例专属的标题，形如 `UI-07-3FA2`
    private func uniqueTitle() -> String {
        let tag = name.range(of: #"test(\d+)"#, options: .regularExpression)
            .map { String(name[$0]).replacingOccurrences(of: "test", with: "") } ?? "n"
        return "UI-\(tag)-" + String(format: "%04X", UInt16.random(in: 0...UInt16.max))
    }

    /// 把当前笔记改名（点标题 → 弹窗里输入 → 保存）。
    ///
    /// 标题按钮的 label 就是当前标题：第一次改名时它还叫「未命名笔记」，
    /// 之后再改就是上一轮起的名字，所以按候选顺序找。
    func renameCurrentNote(to newTitle: String, in app: XCUIApplication) {
        var title: XCUIElement?
        for candidate in [noteTitle, "未命名笔记"] where !candidate.isEmpty {
            let el = app.buttons[candidate]
            if el.waitForExistence(timeout: 5) { title = el; break }
        }
        guard let title else {
            XCTFail("编辑器里找不到笔记标题按钮，没法改名")
            return
        }
        title.tap()
        let field = app.textFields["标题"]
        guard field.waitForExistence(timeout: 6) else {
            app.tap()
            XCTFail("重命名弹窗里没有输入框")
            return
        }
        field.tap()
        field.clearAndType(newTitle)
        commitRenameAlert(in: app, field: field, expected: newTitle)
        noteTitle = newTitle
    }

    /// 在重命名弹窗里等输入落定，再点保存直到弹窗消失。
    ///
    /// 跳过 quiescence 后没有系统帮忙等"输入落定"：键盘还在处理最后几个键时
    /// 点保存可能落空（弹窗留在画布上，后面一笔都画不出来）。编辑器标题和
    /// 列表侧重命名共用同一个弹窗（标题都是「重命名笔记」），走同一套兜底。
    func commitRenameAlert(in app: XCUIApplication, field: XCUIElement, expected: String) {
        let typed = Date().addingTimeInterval(5)
        while (field.value as? String) != expected, Date() < typed {
            usleep(50_000)
        }
        // 二分标定（两台 iPad 各 3 次/档）：内容落定后 100ms 已能 3/3 一次点中，
        // 这里取 250ms 留余量；再慢的机器由下面的补点兜底。
        usleep(250_000)
        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "重命名弹窗里没有保存按钮")
        for _ in 0..<4 {
            save.tap()
            if app.alerts["重命名笔记"].waitForNonExistence(timeout: 1.5) { break }
        }
        XCTAssertTrue(app.alerts["重命名笔记"].waitForNonExistence(timeout: 5),
                      "重命名弹窗没有关掉")
        usleep(500_000)
    }

    /// 当前用例那本笔记在列表里的卡片
    func noteCard(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts[noteTitle].firstMatch
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

    /// 切换「连续滚动」（菜单里的 Toggle，只在多页时出现）。
    ///
    /// 需要精确量屏幕上的墨迹时得先关掉它：连续滚动下一屏不等于一页，
    /// 按屏幕坐标取样会量到相邻页的内容。
    ///
    /// 开关本身带 `toggle-continuous` 标识和 "1"/"0" 的 value。
    /// 早先靠 label「连续滚动」去猜，结果 SwiftUI 把它压成了 label 是 SF Symbol 名的
    /// Button，`value` 读不到，`isOn` 恒为 false —— 于是"关掉连续滚动"实际没关，
    /// 后面按屏幕取样的断言全部落空。
    func setContinuousScroll(_ on: Bool, in app: XCUIApplication) {
        let want = on ? "1" : "0"
        // 菜单里的 Toggle 状态读不可靠（整行被压成 Button，value 时有时无），
        // 直接读 App 暴露的模式探针：它反映真正生效的模式，而不是开关的 UI 表象
        let probe = app.staticTexts["modeProbe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10),
                      "找不到模式探针（-uiTestProbe 没生效？）")
        if probe.label == "continuous=\(want)" { return }

        for attempt in 0..<3 {
            let more = app.buttons["更多"]
            XCTAssertTrue(more.waitForExistence(timeout: 10), "找不到「更多」菜单")
            more.tap()

            let toggle = app.descendants(matching: .any)["toggle-continuous"].firstMatch
            guard toggle.waitForExistence(timeout: 5) else {
                app.tap()          // 菜单还开着，点外部关掉
                XCTFail("菜单里没有「连续滚动」开关（多页时才出现）")
                return
            }

            // 整行点按有时只是把菜单收起来，开关本身不动；没生效就改点行尾的开关
            if attempt == 0 {
                toggle.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            usleep(400_000)
            if toggle.exists { app.tap(); usleep(600_000) }

            // 以探针为准，等模式真正切换（菜单收起 ≠ 切换成功）
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                if probe.exists, probe.label == "continuous=\(want)" {
                    usleep(1_200_000)  // 等画布按新模式完成重建
                    return
                }
                usleep(150_000)
            }
        }
        XCTFail("「连续滚动」没有切到 \(on ? "开" : "关")（当前 \(probe.exists ? probe.label : "探针消失")）")
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
    ///
    /// `region` 默认取页面中部的书写区。连续滚动模式下 `paperRegion` 里可能根本不是纸，
    /// 那时传 `wideRegion` 进来——它几乎覆盖整屏，配合「画前画后的增量」判断仍然可靠。
    @discardableResult
    func drawAndConfirm(_ app: XCUIApplication,
                        from: CGVector, to: CGVector,
                        region: CGRect? = nil) -> Int {
        let area = region ?? paperRegion
        let before = inkPixels(region: area)
        stroke(app, from: from, to: to)
        usleep(1_200_000)
        if inkPixels(region: area) - before < 60 {
            stroke(app, from: from, to: to)
            usleep(1_200_000)
        }
        return inkPixels(region: area) - before
    }

    /// 页面书写区（避开顶栏、左工具栏、右侧缩略图栏、底栏）。
    /// 下沿必须盖住用例画到 y≈0.74 的笔迹：之前只到 0.58，
    /// 页 4 那一笔整条落在框外，屏幕上有墨也被判成 0。
    let paperRegion = CGRect(x: 0.20, y: 0.28, width: 0.66, height: 0.50)

    // MARK: - 画布状态（走 App 内探针，比截屏数像素快两个数量级）

    /// 画布真实状态：当前页有几笔、墨迹包围盒多大。
    ///
    /// 这个读数是跟"屏幕上哪个像素变黑"脱钩的——不管笔迹画在纸面哪个位置、
    /// 是不是被浮层挡着、页面滚动到了哪里，只要笔真的落到了画布上，
    /// `strokes` 就会涨。之前那些"画不出墨"的假失败，多半是采样矩形没覆盖到笔迹。
    struct InkState: Equatable {
        let strokes: Int
        let length: Int
        let width: Int
        let height: Int
        var hasInk: Bool { length > 0 }
        var summary: String { "strokes=\(strokes) len=\(length)" }
    }

    /// 读一次画布状态（几十毫秒，不截屏）
    func inkState(_ app: XCUIApplication, timeout: TimeInterval = 8) -> InkState {
        let el = app.staticTexts["inkProbe"]
        guard el.waitForExistence(timeout: timeout) else {
            XCTFail("找不到 inkProbe——App 没有带 -uiTestProbe 启动，或探针没接上画布")
            return InkState(strokes: -1, length: -1, width: -1, height: -1)
        }
        var s = -1, len = -1, w = -1, h = -1
        for part in el.label.split(separator: ";") {
            let kv = part.split(separator: "=")
            guard kv.count == 2, let v = Int(kv[1]) else { continue }
            switch kv[0] {
            case "strokes": s = v
            case "len": len = v
            case "w": w = v
            case "h": h = v
            default: break
            }
        }
        return InkState(strokes: s, length: len, width: w, height: h)
    }

    /// 轮询等到画布状态满足条件。用状态收敛替代固定 usleep：
    /// 快的时候 100ms 就返回，不再无脑等 1.2 秒。
    @discardableResult
    func waitForInk(_ app: XCUIApplication,
                    timeout: TimeInterval = 6,
                    _ predicate: (InkState) -> Bool) -> InkState {
        let deadline = Date().addingTimeInterval(timeout)
        var last = inkState(app)
        while Date() < deadline {
            if predicate(last) { return last }
            usleep(80_000)
            last = inkState(app)
        }
        return last
    }

    /// 画一笔并等到墨迹长度真的增加（不截屏、不算像素）
    /// 返回长度增量：>0 表示这一笔落到了画布上，0 表示根本没写进去。
    /// 新建/改名后的第一笔偶尔会被画布重建吞掉，等一拍再补一笔。
    @discardableResult
    func drawStroke(_ app: XCUIApplication,
                    from: CGVector, to: CGVector, hold: TimeInterval = 0.12) -> Int {
        let before = inkState(app).length
        stroke(app, from: from, to: to, hold: hold)
        var after = waitForInk(app, timeout: 3) { $0.length > before + 20 }
        if after.length <= before + 20 {
            usleep(300_000)
            stroke(app, from: from, to: to, hold: hold)
            after = waitForInk(app, timeout: 3) { $0.length > before + 20 }
        }
        return after.length - before
    }

    /// 几乎整屏的取样区。连续滚动时一屏跨了多页，纸面位置没法预设，
    /// 只能靠「画前 / 画后的像素增量」判断有没有新墨。
    let wideRegion = CGRect(x: 0.04, y: 0.14, width: 0.92, height: 0.74)

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

// MARK: - 跳过 XCUITest 的动画静默期

extension XCUIApplication {
    /// 关掉事件前后的「等 App 动画结束」静默检查。
    ///
    /// 起因：在重命名弹窗里打完字后，模拟器上的系统键盘会把动画挂住，
    /// XCUITest 收不到 "App animations complete" 通知，之后每个 tap / drag
    /// 都要白等满 60 秒（一条用例能多花 7 分钟）。
    ///
    /// XCUIAutomation 内部本来就有跳过这两个阶段的开关
    /// （XCUIApplicationInteractionOptionSkipPreEventQuiescence = 1，
    /// SkipPostEventQuiescence = 2），只是没公开。这里用运行时直接设置，
    /// 关闭的是"等动画"这一步，不是 App 自己的动画——PencilKit 落笔不受影响。
    ///
    /// 私有方法不存在时静默返回：测试退回原速，不会因此失败。
    func skipQuiescenceWaits() {
        let sel = NSSelectorFromString("setCurrentInteractionOptions:")
        guard let method = class_getInstanceMethod(XCUIApplication.self, sel) else { return }
        typealias SetOptions = @convention(c) (AnyObject, Selector, UInt) -> Void
        let set = unsafeBitCast(method_getImplementation(method), to: SetOptions.self)
        set(self, sel, 3)
    }
}
