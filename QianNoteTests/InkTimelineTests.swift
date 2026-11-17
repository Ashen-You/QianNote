import XCTest
import CoreGraphics
@testable import QianNote

/// 录音逐笔时间轴的单元测试。
///
/// 这里只测纯逻辑（打点 → 按时间回算该显示几笔），不碰 AVAudioRecorder。
/// 时间轴本身是「录音时的当前时间」和「这一笔落下后总笔数」两个量的单调映射，
/// 所以核心不变式只有一条：**时间越往后，可见笔数只增不减，且不超过实际笔数**。
final class InkTimelineTests: XCTestCase {

    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        // 独立目录：测试宿主的沙盒和 App 相同，用默认 "QianNote" 会删掉用户真实笔记
        store = NoteStore(rootFolderName: "QianNoteTests-InkTimeline")
        store.destroyStorageForTesting()
        store = NoteStore(rootFolderName: "QianNoteTests-InkTimeline")
    }

    override func tearDown() {
        store.destroyStorageForTesting()
        store = nil
        super.tearDown()
    }

    // MARK: - 无时间轴

    func testReplayStrokeCount_withoutTimeline_returnsNil() {
        let note = store.createNote(title: "空笔记")
        let pageID = note.pages[0].id

        // 没打过点：返回 nil 表示「正常显示全部」，调用方不做裁剪
        XCTAssertNil(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 0))
        XCTAssertFalse(store.hasInkTimeline(noteID: note.id))
    }

    // MARK: - 录音前已有墨迹

    /// 场景：纸上先写了 3 笔，然后才开始录音。
    /// 回放起点（t=0）时这 3 笔必须已在，不能凭空消失。
    func testReplayStrokeCount_beforeFirstStamp_keepsBaselineStrokes() {
        let note = store.createNote(title: "先写后录")
        let pageID = note.pages[0].id

        store.beginInkTimeline(noteID: note.id)
        // 已有 3 笔，录音后第一笔落下时总数为 4
        store.addInkStamp(noteID: note.id, pageID: pageID, time: 1.0, strokeCount: 4)
        store.flushInkTimeline(noteID: note.id)

        // t=0（还没到第一笔）应显示录音前的 3 笔
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 0), 3)
    }

    // MARK: - 逐笔推进

    func testReplayStrokeCount_growsMonotonicallyWithTime() {
        let note = store.createNote(title: "逐笔")
        let pageID = note.pages[0].id

        store.beginInkTimeline(noteID: note.id)
        store.addInkStamp(noteID: note.id, pageID: pageID, time: 1.0, strokeCount: 1)
        store.addInkStamp(noteID: note.id, pageID: pageID, time: 2.0, strokeCount: 2)
        store.addInkStamp(noteID: note.id, pageID: pageID, time: 3.0, strokeCount: 3)
        store.flushInkTimeline(noteID: note.id)

        // 第一个时间戳的 strokeCount=1 → baseline = 0，所以起点是 0 笔
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 0.0), 0)
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 1.0), 1)
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 1.5), 1)
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 2.0), 2)
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 2.5), 2)
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 3.0), 3)
        // 超过最后一个时间点：保持最后一笔，不会越界
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 99.0), 3)
    }

    /// 单调性：随机取一堆时间点，可见笔数必须只增不减
    func testReplayStrokeCount_isMonotonic() {
        let note = store.createNote(title: "单调性")
        let pageID = note.pages[0].id

        store.beginInkTimeline(noteID: note.id)
        for i in 1...20 {
            store.addInkStamp(noteID: note.id, pageID: pageID,
                              time: Double(i) * 0.37, strokeCount: i)
        }
        store.flushInkTimeline(noteID: note.id)

        var previous = -1
        for step in 0...200 {
            let t = Double(step) * 0.05
            let count = store.replayStrokeCount(noteID: note.id, pageID: pageID, time: t) ?? 0
            XCTAssertGreaterThanOrEqual(count, previous, "时间 \(t) 的笔数比上一时刻还少")
            XCTAssertLessThanOrEqual(count, 20, "笔数超过了实际总笔数")
            previous = count
        }
    }

    // MARK: - 多页隔离

    func testReplayStrokeCount_isolatesPages() {
        let note = store.createNote(title: "两页")
        store.addPage(noteID: note.id, after: 0)
        guard let updated = store.note(id: note.id), updated.pages.count >= 2 else {
            return XCTFail("加页失败")
        }
        let p1 = updated.pages[0].id
        let p2 = updated.pages[1].id

        store.beginInkTimeline(noteID: note.id)
        store.addInkStamp(noteID: note.id, pageID: p1, time: 1.0, strokeCount: 2)
        store.addInkStamp(noteID: note.id, pageID: p2, time: 2.0, strokeCount: 1)
        store.addInkStamp(noteID: note.id, pageID: p1, time: 3.0, strokeCount: 5)
        store.flushInkTimeline(noteID: note.id)

        // 第 2 页刚到第一笔时，第 1 页应该已经回到 2 笔（不受第 2 页影响）
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: p1, time: 2.0), 2)
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: p2, time: 2.0), 1)
        // 第 1 页后续那笔到 3.0 才出现
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: p1, time: 2.9), 2)
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: p1, time: 3.0), 5)
    }

    // MARK: - 缓冲与落盘

    /// 打点先攒内存：录完前不应写进 note.inkStamps（否则每笔都触发整页重绘）
    func testAddInkStamp_staysBufferedUntilFlush() {
        let note = store.createNote(title: "缓冲")
        let pageID = note.pages[0].id

        store.beginInkTimeline(noteID: note.id)
        store.addInkStamp(noteID: note.id, pageID: pageID, time: 1.0, strokeCount: 1)

        XCTAssertTrue(store.note(id: note.id)?.inkStamps.isEmpty ?? false,
                      "未 flush 前不应落进模型")
        // 但缓冲里的数据依然能被查询到
        XCTAssertEqual(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 1.0), 1)

        store.flushInkTimeline(noteID: note.id)
        XCTAssertEqual(store.note(id: note.id)?.inkStamps.count, 1)
    }

    /// 重新录音要把旧时间轴清干净，否则会拿上一轮的笔数去裁剪新一轮
    func testPrepareForRecording_clearsPreviousTimeline() {
        let note = store.createNote(title: "重录")
        let pageID = note.pages[0].id

        store.beginInkTimeline(noteID: note.id)
        store.addInkStamp(noteID: note.id, pageID: pageID, time: 1.0, strokeCount: 3)
        store.flushInkTimeline(noteID: note.id)
        XCTAssertEqual(store.note(id: note.id)?.inkStamps.count, 1)

        store.prepareForRecording(note.id)
        XCTAssertTrue(store.note(id: note.id)?.inkStamps.isEmpty ?? false)
        XCTAssertNil(store.replayStrokeCount(noteID: note.id, pageID: pageID, time: 1.0))
    }

    // MARK: - 序列化

    func testInkStamp_codableRoundTrip() throws {
        let stamp = InkStamp(pageID: UUID(), time: 12.5, strokeCount: 7)
        let data = try JSONEncoder().encode(stamp)
        let decoded = try JSONDecoder().decode(InkStamp.self, from: data)

        XCTAssertEqual(decoded.id, stamp.id)
        XCTAssertEqual(decoded.pageID, stamp.pageID)
        XCTAssertEqual(decoded.time, stamp.time, accuracy: 0.0001)
        XCTAssertEqual(decoded.strokeCount, stamp.strokeCount)
    }

    /// 老笔记没有 inkStamps 字段时要能正常解码（不能因为新功能打不开旧笔记）
    func testNote_decodesWithoutInkStamps() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "title": "旧笔记",
          "createdAt": 700000000,
          "updatedAt": 700000000,
          "pages": [],
          "paperTemplate": "ruled",
          "paperTint": "white",
          "isFavorite": false,
          "pageWidth": 768,
          "pageHeight": 1024
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let note = try decoder.decode(Note.self, from: Data(legacy.utf8))

        XCTAssertEqual(note.title, "旧笔记")
        XCTAssertTrue(note.inkStamps.isEmpty)
        XCTAssertTrue(note.markers.isEmpty)
    }
}
