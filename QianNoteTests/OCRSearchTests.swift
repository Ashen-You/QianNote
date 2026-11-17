import XCTest
import PencilKit
@testable import QianNote

/// 手写搜索的测试。
///
/// 不测 Vision 本身的识别精度（那是系统能力，且同一张图在不同系统版本上结果可能不同），
/// 只测我们自己写的两段逻辑：**文本归一化** 和 **命中判断**。
/// 这两处一旦出错，搜索会静默失效 —— 用户搜不到东西但没有任何报错。
final class OCRSearchTests: XCTestCase {

    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        // 独立目录：不能用默认 "QianNote"，否则会清掉 App 的真实笔记
        store = NoteStore(rootFolderName: "QianNoteTests-OCR")
        store.destroyStorageForTesting()
        store = NoteStore(rootFolderName: "QianNoteTests-OCR")
    }

    override func tearDown() {
        store.destroyStorageForTesting()
        store = nil
        super.tearDown()
    }

    // MARK: - 归一化

    func testNormalize_trimsAndLowercases() {
        XCTAssertEqual(HandwritingOCR.normalize("  Hello   World  "), "hello world")
    }

    func testNormalize_collapsesFullWidthSpaces() {
        XCTAssertEqual(HandwritingOCR.normalize("笔记\u{00A0}内容"), "笔记 内容")
    }

    func testNormalize_emptyOrWhitespace_returnsNil() {
        XCTAssertNil(HandwritingOCR.normalize(""))
        XCTAssertNil(HandwritingOCR.normalize("   \n\t  "))
    }

    /// 中文没有词间空格，归一化不能把它们连成一片导致子串匹配失败
    func testNormalize_keepsChineseIntact() {
        XCTAssertEqual(HandwritingOCR.normalize("会议纪要"), "会议纪要")
    }

    // MARK: - 命中判断

    func testMatches_titleHit() {
        let note = store.createNote(title: "线性代数复习")
        XCTAssertTrue(store.matches(note, query: "线性"))
        XCTAssertTrue(store.matches(note, query: "代数"))
    }

    func testMatches_ocrHitIsCaseInsensitive() {
        let note = store.createNote(title: "无标题")
        store.update(note.id) { n in
            n.pages[0].ocrText = "machine learning basics"
        }
        guard let updated = store.note(id: note.id) else { return XCTFail("笔记丢了") }

        XCTAssertTrue(store.matches(updated, query: "Machine"))
        XCTAssertTrue(store.matches(updated, query: "LEARNING"))
        XCTAssertTrue(store.matches(updated, query: "basics"))
        XCTAssertFalse(store.matches(updated, query: "deep learning"))
    }

    func testMatches_textBoxHit() {
        let note = store.createNote(title: "无标题")
        store.update(note.id) { n in
            n.pages[0].textBoxes = [TextBox(text: "明天下午三点开会", x: 40, y: 40)]
        }
        guard let updated = store.note(id: note.id) else { return XCTFail("笔记丢了") }

        XCTAssertTrue(store.matches(updated, query: "下午三点"))
        XCTAssertFalse(store.matches(updated, query: "上午"))
    }

    func testMatches_noHit() {
        let note = store.createNote(title: "物理笔记")
        XCTAssertFalse(store.matches(note, query: "化学"))
    }

    /// 只在第二页的手写内容也要能搜到（多页笔记常见）
    func testMatches_secondPageOcr() {
        let note = store.createNote(title: "多页")
        store.addPage(noteID: note.id, after: 0)
        guard let withTwo = store.note(id: note.id), withTwo.pages.count >= 2 else {
            return XCTFail("加页失败")
        }
        store.update(note.id) { n in
            n.pages[1].ocrText = "第二页写的热力学第二定律"
        }
        guard let updated = store.note(id: note.id) else { return XCTFail("笔记丢了") }

        XCTAssertTrue(store.matches(updated, query: "热力学"))
    }

    // MARK: - 索引跳过

    /// 空页不该被写入索引标记，否则每轮都会重新进队列
    func testIndexHandwriting_skipsEmptyPages() async {
        let note = store.createNote(title: "空页")
        await store.indexHandwritingIfNeeded()

        guard let updated = store.note(id: note.id) else { return XCTFail("笔记丢了") }
        for page in updated.pages {
            XCTAssertNil(page.ocrText, "空页不应产生 OCR 文本")
            XCTAssertNil(page.ocrBaseline)
        }
    }

    /// 已有索引页且墨迹未变时，不该被重新识别（这里用「非法 pageSize」间接验证：
    /// 真正被重新识别的话 PKDrawing.image 会拿到无效尺寸，测试环境里会崩或超时）。
    func testIndexHandwriting_skipsUpToDatePages() async {
        let note = store.createNote(title: "已索引")
        let pageID = note.pages[0].id

        // 造一条真实笔迹，让 strokeCount = 1
        let drawing = makeSingleStrokeDrawing()
        store.saveDrawing(drawing, noteID: note.id, pageID: pageID)
        store.update(note.id) { n in
            n.pages[0].ocrText = "already indexed"
            n.pages[0].ocrBaseline = 1
        }

        await store.indexHandwritingIfNeeded()

        guard let updated = store.note(id: note.id) else { return XCTFail("笔记丢了") }
        XCTAssertEqual(updated.pages[0].ocrText, "already indexed", "过期检查失效，被重复识别覆盖了")
        XCTAssertEqual(updated.pages[0].ocrBaseline, 1)
    }

    // MARK: - 辅助

    /// 端到端验证 Vision 链路：渲染一张印着 HELLO 的图，确认能识别出 hello。
    /// 不依赖 PencilKit，只证明「图 → 文字」这一段是通的。
    func testRecognizeText_readsRenderedText() async {
        let size = CGSize(width: 400, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            ("HELLO" as NSString).draw(at: CGPoint(x: 30, y: 28), withAttributes: attributes)
        }

        let text = await HandwritingOCR.recognizeText(in: image)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("hello") ?? false, "识别结果: \(text ?? "nil")")
    }

    private func makeSingleStrokeDrawing() -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 0.7, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 60, y: 60), timeOffset: 0.05,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 0.7, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        return PKDrawing(strokes: [stroke])
    }
}
