import XCTest
import PencilKit
@testable import QianNote

/// 资料库备份 / 恢复的测试。
///
/// 这块逻辑最容易出的问题是「恢复时把用户刚写的东西覆盖掉」，
/// 所以重点测合并方向：备份旧、本地新的时候必须一个字节都不动。
final class BackupRestoreTests: XCTestCase {

    private var store: NoteStore!
    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = NoteStore(rootFolderName: "QianNoteTests-Backup")
        store.destroyStorageForTesting()
        store = NoteStore(rootFolderName: "QianNoteTests-Backup")

        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("qn-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store.destroyStorageForTesting()
        store = nil
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - 备份

    func testBackup_createsIndexAndNotesFolder() throws {
        _ = store.createNote(title: "要备份的笔记")

        let created = try store.backupLibrary(to: sandbox)
        let fm = FileManager.default

        XCTAssertTrue(fm.fileExists(atPath: created.appendingPathComponent("index.json").path))
        XCTAssertTrue(fm.fileExists(atPath: created.appendingPathComponent("Notes").path))
    }

    /// 空资料库也要能备份成功（不能因为 Notes 目录没有内容就报错）
    func testBackup_emptyLibrary_succeeds() throws {
        let created = try store.backupLibrary(to: sandbox)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }

    // MARK: - 恢复

    func testRestore_roundTrip() throws {
        let note = store.createNote(title: "原始笔记")
        let backup = try store.backupLibrary(to: sandbox)

        // 模拟「换机」：本地清空
        store.delete(note.id)
        // 空资料库会自动 seed 一篇「欢迎使用」，所以这里不判断整体为空
        XCTAssertFalse(store.notes.contains { $0.id == note.id })

        let restored = try store.restoreLibrary(from: backup)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(store.notes.first?.title, "原始笔记")
        XCTAssertEqual(store.notes.first?.id, note.id)
    }

    /// 本地这份比备份新时，必须原样保留，不能被旧备份盖掉
    func testRestore_skipsWhenLocalIsNewer() throws {
        let note = store.createNote(title: "旧标题")
        let backup = try store.backupLibrary(to: sandbox)

        // 备份之后本地又改过（updatedAt 更新）
        store.rename(note.id, to: "新标题")
        guard let newer = store.note(id: note.id) else { return XCTFail("笔记丢了") }
        XCTAssertGreaterThan(newer.updatedAt, note.updatedAt)

        let restored = try store.restoreLibrary(from: backup)
        XCTAssertEqual(restored, 0)
        XCTAssertEqual(store.note(id: note.id)?.title, "新标题")
    }

    /// 本地没有的笔记要加进来，已有的不受影响（真正的合并，不是全量替换）
    func testRestore_mergesInsteadOfReplacing() throws {
        let old = store.createNote(title: "备份里的笔记")
        let backup = try store.backupLibrary(to: sandbox)

        // 备份之后本地新增了一篇，并把旧的删掉
        store.delete(old.id)
        let fresh = store.createNote(title: "本地新写的")

        let restored = try store.restoreLibrary(from: backup)
        XCTAssertEqual(restored, 1)
        // 两篇都在（外加 seed 出来的欢迎笔记）
        XCTAssertTrue(store.notes.contains { $0.id == fresh.id })
        XCTAssertTrue(store.notes.contains { $0.id == old.id })
    }

    /// 文件夹也要一起恢复
    func testRestore_restoresFolders() throws {
        let folder = store.addFolder(named: "工作")
        let backup = try store.backupLibrary(to: sandbox)

        // 清掉文件夹
        store.deleteFolder(folder.id)
        XCTAssertTrue(store.folders.isEmpty)

        _ = try store.restoreLibrary(from: backup)
        XCTAssertTrue(store.folders.contains { $0.id == folder.id })
    }

    func testRestore_invalidFolderThrows() throws {
        let empty = sandbox.appendingPathComponent("not-a-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.restoreLibrary(from: empty)) { error in
            XCTAssertTrue(error is BackupError)
        }
    }

    /// 恢复后墨迹要能读出来（不能只有元数据，笔迹文件没拷过来）
    func testRestore_carriesDrawingFiles() throws {
        let note = store.createNote(title: "带笔迹")
        let pageID = note.pages[0].id
        let drawing = makeSingleStrokeDrawing()
        store.saveDrawing(drawing, noteID: note.id, pageID: pageID)

        let backup = try store.backupLibrary(to: sandbox)
        store.delete(note.id)

        _ = try store.restoreLibrary(from: backup)
        let recovered = store.drawing(noteID: note.id, pageID: pageID)
        XCTAssertEqual(recovered.strokes.count, 1, "笔迹文件没跟过来")
    }

    // MARK: - 辅助

    private func makeSingleStrokeDrawing() -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 0.7, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 80, y: 80), timeOffset: 0.05,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 0.7, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        return PKDrawing(strokes: [stroke])
    }
}
