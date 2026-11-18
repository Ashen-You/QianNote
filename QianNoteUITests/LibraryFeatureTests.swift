import XCTest

/// 笔记列表（文档级）用例：收藏、搜索、重命名、删除、复制副本。
///
/// 每条用例都先造一本标题唯一的笔记，避免模拟器上历史数据互相干扰。
final class LibraryFeatureTests: NoteUITestCase {

    // MARK: - 造数据

    /// 新建一本笔记、改成指定标题、回到列表
    @discardableResult
    func createNote(titled name: String, in app: XCUIApplication) -> XCUIElement {
        // openNewNote 已经把笔记改成了用例专属标题，这里换成业务用例要的名字
        openNewNote(app)
        renameCurrentNote(to: name, in: app)
        app.buttons["返回笔记列表"].tap()

        let card = app.staticTexts[name].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "列表里没有找到标题为「\(name)」的笔记")
        return card
    }

    /// 长按卡片，等上下文菜单出来
    func openContextMenu(on card: XCUIElement) {
        card.press(forDuration: 1.3)
        usleep(600_000)
    }

    // MARK: - 1. 收藏

    func test01_favorite_appearsInFavoriteFilter() {
        let name = "UITest-Favorite"
        let app = launch(fingerDraws: false)
        createNote(titled: name, in: app)
        let card = app.staticTexts[name]

        openContextMenu(on: card)
        let fav = app.buttons["menu-favorite"]
        XCTAssertTrue(fav.waitForExistence(timeout: 8), "长按菜单里没有「收藏」")
        fav.tap()
        // 菜单收起有动画，收起前点下面的 chip 会被遮罩吞掉，
        // 筛选根本没切过去，但「目标还在」的断言却会误判为通过
        XCTAssertTrue(fav.waitForNonExistence(timeout: 5), "收藏之后长按菜单没有收起")
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        // 元素从树里消失 ≠ 收起动画结束；遮罩还在时点击会被吞掉
        usleep(600_000)

        // 切到收藏筛选。菜单收起动画期间快照里的 chip frame 可能是过期的，
        // 第一次点可能落空甚至误开笔记；以探针为准，只有没生效才补点——
        // 旧写法按 chip 的选中态判断，而那个状态永远不更新，补点会把筛选点开又点回去
        let probe = app.staticTexts["libraryProbe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 8),
                      "找不到筛选状态探针（-uiTestProbe 没生效？）")
        func filterOn() -> Bool { probe.exists && probe.label.hasPrefix("favorites=1") }
        for attempt in 0..<3 {
            if filterOn() { break }
            // 点歪进了编辑器：先退回列表再继续
            if !probe.exists, app.buttons["返回笔记列表"].waitForExistence(timeout: 3) {
                app.buttons["返回笔记列表"].tap()
                XCTAssertTrue(probe.waitForExistence(timeout: 8), "退回列表后探针没回来")
            }
            let chip = app.buttons["filter-收藏"].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 8), "顶部没有收藏筛选")
            chip.tap()
            let deadline = Date().addingTimeInterval(2.5)
            while !filterOn(), Date() < deadline { usleep(100_000) }
            if attempt == 2 { break }
        }
        XCTAssertTrue(filterOn(), "点了收藏筛选，但筛选没有切换过去")
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10),
                      "收藏之后在收藏筛选里看不到这本笔记")

        // 取消收藏，收藏筛选里应当消失
        openContextMenu(on: app.staticTexts[name].firstMatch)
        let unfav = app.buttons["menu-favorite"]
        XCTAssertTrue(unfav.waitForExistence(timeout: 8), "菜单里没有「取消收藏」")
        // 标识不随文案变，再用文案确认这次真的是「取消收藏」
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 3),
                      "菜单里显示的还是「收藏」，说明刚才没收藏上")
        unfav.tap()
        XCTAssertTrue(unfav.waitForNonExistence(timeout: 5), "取消收藏之后长按菜单没有收起")
        usleep(600_000)
        // 等卡片真的消失，而不是赌固定 900ms；筛选没反应时这里会等满再失败
        XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 8),
                      "取消收藏之后仍然出现在收藏筛选里")
    }

    // MARK: - 2. 搜索

    func test02_search_filtersByTitle() {
        let target = "UITest-Searchable"
        let app = launch(fingerDraws: false)
        createNote(titled: target, in: app)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "找不到搜索框")
        field.tap()
        field.typeText("Searchable")
        usleep(1_000_000)

        XCTAssertTrue(app.staticTexts[target].waitForExistence(timeout: 10),
                      "搜索自己的标题却搜不到")

        // 搜一个肯定不存在的词，列表应当清空
        field.clearAndType("zzNoSuchNotezz")
        usleep(1_000_000)
        XCTAssertFalse(app.staticTexts[target].exists,
                       "搜索无关关键词时目标笔记还在")
    }

    // MARK: - 3. 重命名（列表侧）

    func test03_rename_fromContextMenu() {
        let before = "UITest-RenameBefore"
        let after = "UITest-RenameAfter"
        let app = launch(fingerDraws: false)
        createNote(titled: before, in: app)

        openContextMenu(on: app.staticTexts[before].firstMatch)
        let rename = app.buttons["menu-rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 8), "长按菜单里没有「重命名」")
        rename.tap()

        let field = app.textFields["名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "重命名弹窗里没有输入框")
        field.tap()
        field.clearAndType(after)
        // 列表侧弹窗同样会吞掉落定前的那次保存点击，与编辑器改名共用兜底
        commitRenameAlert(in: app, field: field, expected: after)

        XCTAssertTrue(app.staticTexts[after].waitForExistence(timeout: 10),
                      "列表里的标题没有更新")
        XCTAssertFalse(app.staticTexts[before].exists, "旧标题还在")
    }

    // MARK: - 4. 删除

    func test04_delete_removesCard() {
        let name = "UITest-ToDelete"
        let app = launch(fingerDraws: false)
        createNote(titled: name, in: app)

        openContextMenu(on: app.staticTexts[name].firstMatch)
        let del = app.buttons["menu-delete"]
        XCTAssertTrue(del.waitForExistence(timeout: 8), "长按菜单里没有「删除」")
        del.tap()
        usleep(1_200_000)

        XCTAssertFalse(app.staticTexts[name].exists, "删除之后卡片还在")
        // 列表还活着（没崩）
        XCTAssertTrue(app.buttons["新建"].exists || app.buttons["新建笔记"].exists,
                      "删除之后列表页异常")
    }

    // MARK: - 5. 复制副本

    func test05_duplicate_createsSecondCopy() {
        let name = "UITest-Duplicate"
        let app = launch(fingerDraws: false)
        createNote(titled: name, in: app)

        openContextMenu(on: app.staticTexts[name].firstMatch)
        let dup = app.buttons["menu-duplicate"]
        XCTAssertTrue(dup.waitForExistence(timeout: 8), "长按菜单里没有「复制副本」")
        dup.tap()
        usleep(1_200_000)

        // 副本会改名成「原名 副本」，所以不能数同名卡片
        XCTAssertTrue(app.staticTexts["\(name) 副本"].waitForExistence(timeout: 10),
                      "复制副本之后列表里没有出现「\(name) 副本」")
    }
}
