import XCTest

/// 笔记列表（文档级）用例：收藏、搜索、重命名、删除、复制副本。
///
/// 每条用例都先造一本标题唯一的笔记，避免模拟器上历史数据互相干扰。
final class LibraryFeatureTests: NoteUITestCase {

    // MARK: - 造数据

    /// 新建一本笔记、改成指定标题、回到列表
    @discardableResult
    func createNote(titled name: String, in app: XCUIApplication) -> XCUIElement {
        openNewNote(app)

        let title = app.buttons["未命名笔记"]
        if title.waitForExistence(timeout: 8) {
            title.tap()
            let field = app.textFields["标题"]
            if field.waitForExistence(timeout: 6) {
                field.tap()
                field.clearAndType(name)
                app.buttons["保存"].tap()
                usleep(800_000)
            }
        }
        app.buttons["返回笔记列表"].tap()

        let card = app.staticTexts[name]
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
        let fav = app.buttons["收藏"]
        XCTAssertTrue(fav.waitForExistence(timeout: 8), "长按菜单里没有「收藏」")
        fav.tap()
        usleep(800_000)

        // 切到收藏筛选，这本必须还在
        let chip = app.buttons["收藏"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "顶部没有收藏筛选")
        chip.tap()
        usleep(900_000)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10),
                      "收藏之后在收藏筛选里看不到这本笔记")

        // 取消收藏，收藏筛选里应当消失
        openContextMenu(on: app.staticTexts[name])
        let unfav = app.buttons["取消收藏"]
        XCTAssertTrue(unfav.waitForExistence(timeout: 8), "菜单里没有「取消收藏」")
        unfav.tap()
        usleep(900_000)
        XCTAssertFalse(app.staticTexts[name].exists,
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

        openContextMenu(on: app.staticTexts[before])
        let rename = app.buttons["重命名"]
        XCTAssertTrue(rename.waitForExistence(timeout: 8), "长按菜单里没有「重命名」")
        rename.tap()

        let field = app.textFields["名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "重命名弹窗里没有输入框")
        field.tap()
        field.clearAndType(after)
        app.buttons["保存"].tap()
        usleep(1_000_000)

        XCTAssertTrue(app.staticTexts[after].waitForExistence(timeout: 10),
                      "列表里的标题没有更新")
        XCTAssertFalse(app.staticTexts[before].exists, "旧标题还在")
    }

    // MARK: - 4. 删除

    func test04_delete_removesCard() {
        let name = "UITest-ToDelete"
        let app = launch(fingerDraws: false)
        createNote(titled: name, in: app)

        openContextMenu(on: app.staticTexts[name])
        let del = app.buttons["删除"]
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

        let before = app.staticTexts.matching(identifier: name).count
        openContextMenu(on: app.staticTexts[name])
        let dup = app.buttons["复制副本"]
        XCTAssertTrue(dup.waitForExistence(timeout: 8), "长按菜单里没有「复制副本」")
        dup.tap()
        usleep(1_200_000)

        let after = app.staticTexts.matching(identifier: name).count
        XCTAssertGreaterThan(after, before,
                             "复制副本之后列表里没有多出一本（\(before) → \(after)）")
    }
}
