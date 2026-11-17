import Foundation
import PencilKit
import PDFKit
import UIKit

enum NoteStoreError: LocalizedError {
    case invalidPDF
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "无法读取这个 PDF 文件。"
        case .unreadableFile: return "无法访问这个文件，请重试。"
        }
    }
}

final class NoteStore: ObservableObject {

    // MARK: 对外状态

    @Published private(set) var notes: [Note] = []
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var thumbnailRevision: Int = 0
    @Published var errorMessage: String?

    // MARK: 存储位置

    private let fm = FileManager.default
    private let rootURL: URL
    private let notesURL: URL
    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "com.slate.store.io", qos: .utility)

    // MARK: 缓存

    private var drawingCache: [UUID: PKDrawing] = [:]
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let pdfPageCache = NSCache<NSString, UIImage>()
    private let imageCache = NSCache<NSString, UIImage>()
    private var pdfDocuments: [UUID: PDFDocument] = [:]

    private var saveTask: Task<Void, Never>?
    private var thumbnailWork: [UUID: DispatchWorkItem] = [:]
    private var lastUpdateBump: [UUID: Date] = [:]

    /// 墨迹落盘的「代」计数：只让最新的快照落盘，中间版本直接跳过
    private let drawingLock = NSLock()
    private var drawingGeneration: [UUID: Int] = [:]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - 初始化

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        rootURL = docs.appendingPathComponent("Slate", isDirectory: true)
        notesURL = rootURL.appendingPathComponent("Notes", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("index.json")

        thumbnailCache.countLimit = 400
        pdfPageCache.countLimit = 80
        imageCache.countLimit = 120

        try? FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 读写索引

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? Self.decoder.decode(LibraryIndex.self, from: data) else {
            seed()
            return
        }
        notes = index.notes
        folders = index.folders
        if notes.isEmpty { seed() }
    }

    private func seed() {
        var welcome = Note(title: "欢迎使用 Slate", paperTemplate: .ruled, paperTint: .white)
        welcome.isFavorite = true
        welcome.pages = [NotePage(textBoxes: WelcomeContent.textBoxes)]
        notes = [welcome]
        saveNow()
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let index = LibraryIndex(notes: notes, folders: folders)
        guard let data = try? Self.encoder.encode(index) else { return }
        let url = indexURL
        ioQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: - 查询

    func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    private func indexOfNote(_ id: UUID) -> Int? {
        notes.firstIndex { $0.id == id }
    }

    var favoriteCount: Int {
        notes.filter(\.isFavorite).count
    }

    func notes(in folderID: UUID?) -> [Note] {
        notes.filter { $0.folderID == folderID }
    }

    // MARK: - 笔记

    @discardableResult
    func createNote(title: String = "未命名笔记",
                    folderID: UUID? = nil,
                    template: PaperTemplate = .ruled,
                    tint: PaperTint = .white) -> Note {
        let note = Note(title: title,
                        folderID: folderID,
                        pages: [NotePage()],
                        paperTemplate: template,
                        paperTint: tint)
        notes.insert(note, at: 0)
        try? fm.createDirectory(at: noteFolder(note.id), withIntermediateDirectories: true)
        saveNow()
        return note
    }

    func update(_ noteID: UUID, _ mutate: (inout Note) -> Void) {
        guard let index = indexOfNote(noteID) else { return }
        var note = notes[index]
        mutate(&note)
        note.updatedAt = Date()
        notes[index] = note
        scheduleSave()
    }

    func rename(_ noteID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(noteID) { $0.title = trimmed }
    }

    func toggleFavorite(_ noteID: UUID) {
        update(noteID) { $0.isFavorite.toggle() }
    }

    func move(_ noteID: UUID, to folderID: UUID?) {
        update(noteID) { $0.folderID = folderID }
    }

    func markUpdated(_ noteID: UUID) {
        guard let index = indexOfNote(noteID) else { return }
        notes[index].updatedAt = Date()
        saveNow()
    }

    func delete(_ noteID: UUID) {
        notes.removeAll { $0.id == noteID }
        pdfDocuments[noteID] = nil
        let folder = noteFolder(noteID)
        ioQueue.async {
            try? FileManager.default.removeItem(at: folder)
        }
        saveNow()
    }

    func duplicate(_ noteID: UUID) {
        guard let source = note(id: noteID) else { return }

        var copy = source
        copy.id = UUID()
        copy.title = source.title + " 副本"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.isFavorite = false

        var newPages: [NotePage] = []
        for page in source.pages {
            var newPage = NotePage()
            newPage.textBoxes = page.textBoxes.map { box in
                var copyBox = box
                copyBox.id = UUID()
                return copyBox
            }
            let existing = drawing(noteID: noteID, pageID: page.id)
            saveDrawing(existing, noteID: copy.id, pageID: newPage.id)
            newPages.append(newPage)
        }
        copy.pages = newPages

        let sourceFolder = noteFolder(noteID)
        let targetFolder = noteFolder(copy.id)
        try? fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)

        if let pdfName = source.pdfFileName {
            try? fm.copyItem(at: sourceFolder.appendingPathComponent(pdfName),
                             to: targetFolder.appendingPathComponent(pdfName))
        }
        if let audioName = source.audioFileName {
            try? fm.copyItem(at: sourceFolder.appendingPathComponent(audioName),
                             to: targetFolder.appendingPathComponent(audioName))
        }

        notes.insert(copy, at: 0)
        saveNow()
    }

    // MARK: - 文件夹

    @discardableResult
    func addFolder(named name: String) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: trimmed.isEmpty ? "新建文件夹" : trimmed)
        folders.append(folder)
        scheduleSave()
        return folder
    }

    func renameFolder(_ folderID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].name = trimmed
        scheduleSave()
    }

    func deleteFolder(_ folderID: UUID) {
        folders.removeAll { $0.id == folderID }
        for index in notes.indices where notes[index].folderID == folderID {
            notes[index].folderID = nil
        }
        scheduleSave()
    }

    // MARK: - 页面

    func addPage(noteID: UUID, after index: Int? = nil) {
        update(noteID) { note in
            let target = index.map { min(max($0 + 1, 0), note.pages.count) } ?? note.pages.count
            note.pages.insert(NotePage(), at: target)
        }
    }

    func duplicatePage(noteID: UUID, at index: Int) {
        guard let note = note(id: noteID), note.pages.indices.contains(index) else { return }
        let source = note.pages[index]

        var copy = NotePage()
        copy.textBoxes = source.textBoxes.map { box in
            var copyBox = box
            copyBox.id = UUID()
            return copyBox
        }

        let existing = drawing(noteID: noteID, pageID: source.id)
        saveDrawing(existing, noteID: noteID, pageID: copy.id)

        update(noteID) { note in
            note.pages.insert(copy, at: min(index + 1, note.pages.count))
        }
    }

    func deletePage(noteID: UUID, at index: Int) {
        guard let note = note(id: noteID),
              note.pages.indices.contains(index),
              note.pages.count > 1 else { return }
        let page = note.pages[index]

        update(noteID) { $0.pages.remove(at: index) }

        drawingCache[page.id] = nil
        let drawingFile = drawingURL(noteID: noteID, pageID: page.id)
        let thumbFile = thumbnailURL(noteID: noteID, pageID: page.id)
        ioQueue.async {
            try? FileManager.default.removeItem(at: drawingFile)
            try? FileManager.default.removeItem(at: thumbFile)
        }
    }

    func movePage(noteID: UUID, from source: Int, to destination: Int) {
        guard let note = note(id: noteID),
              note.pages.indices.contains(source),
              note.pages.indices.contains(destination),
              source != destination else { return }

        update(noteID) { note in
            let page = note.pages.remove(at: source)
            note.pages.insert(page, at: destination)
        }
    }

    func clearPage(noteID: UUID, pageID: UUID) {
        saveDrawing(PKDrawing(), noteID: noteID, pageID: pageID)
    }

    func setPaper(noteID: UUID, template: PaperTemplate, tint: PaperTint) {
        update(noteID) { note in
            note.paperTemplate = template
            note.paperTint = tint
        }
    }

    func updatePage(noteID: UUID, pageID: UUID, _ mutate: (inout NotePage) -> Void) {
        update(noteID) { note in
            guard let index = note.pages.firstIndex(where: { $0.id == pageID }) else { return }
            mutate(&note.pages[index])
        }
    }

    // MARK: - 墨迹

    func drawing(noteID: UUID, pageID: UUID) -> PKDrawing {
        if let cached = drawingCache[pageID] { return cached }

        let url = drawingURL(noteID: noteID, pageID: pageID)
        var drawing = PKDrawing()
        if let data = try? Data(contentsOf: url), let stored = try? PKDrawing(data: data) {
            drawing = stored
        }
        drawingCache[pageID] = drawing
        return drawing
    }

    func saveDrawing(_ drawing: PKDrawing, noteID: UUID, pageID: UUID) {
        drawingCache[pageID] = drawing
        let url = drawingURL(noteID: noteID, pageID: pageID)
        let folder = noteFolder(noteID)

        // dataRepresentation() 是毫秒级到几十毫秒的开销。书写过程中这里每 0.25 秒跑一次，
        // 等于每隔几帧就卡住主线程，PencilKit 的笔迹就断在半路（「写到一半被截断」）。
        // PKDrawing 是值类型，拍照成本极低，编码和写盘都挪到 ioQueue 去做。
        drawingLock.lock()
        let generation = (drawingGeneration[pageID] ?? 0) + 1
        drawingGeneration[pageID] = generation
        drawingLock.unlock()

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.drawingLock.lock()
            let latest = self.drawingGeneration[pageID] ?? 0
            self.drawingLock.unlock()
            // 队列里已经排着更新的快照，这一版没有落盘价值
            guard generation == latest else { return }

            let data = drawing.dataRepresentation()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }

        scheduleThumbnail(noteID: noteID, pageID: pageID)
        bumpUpdated(noteID)
    }

    private func bumpUpdated(_ noteID: UUID) {
        guard let index = indexOfNote(noteID) else { return }
        let now = Date()
        if let last = lastUpdateBump[noteID], now.timeIntervalSince(last) < 4 { return }
        lastUpdateBump[noteID] = now
        notes[index].updatedAt = now
        scheduleSave()
    }

    // MARK: - 缩略图

    private func scheduleThumbnail(noteID: UUID, pageID: UUID) {
        thumbnailWork[pageID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.generateThumbnail(noteID: noteID, pageID: pageID)
            }
        }
        thumbnailWork[pageID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func generateThumbnail(noteID: UUID, pageID: UUID) {
        guard let note = note(id: noteID),
              let pageIndex = note.pages.firstIndex(where: { $0.id == pageID }) else { return }

        let drawing = drawing(noteID: noteID, pageID: pageID)
        let pdf = pdfDocument(for: noteID)
        // 图片资源先在主线程取（走内存缓存），渲染本身必须离开主线程：
        // 整页「纸张 + PDF + 墨迹」合成实测要 1.5 秒，放在主线程等于每写一会儿就冻住一次，
        // PencilKit 收不到触摸点，笔迹就断在半路。
        var images: [String: UIImage] = [:]
        for item in note.pages[safe: pageIndex]?.images ?? [] {
            if let image = image(noteID: noteID, fileName: item.fileName) {
                images[item.fileName] = image
            }
        }
        let url = thumbnailURL(noteID: noteID, pageID: pageID)

        ioQueue.async { [weak self] in
            // 缩略图最宽 520pt，墨迹按 1 倍栅格化即可（原来固定 2 倍，白算 4 倍像素）
            let rendered = PageRenderer.renderPage(note: note,
                                                   pageIndex: pageIndex,
                                                   drawing: drawing,
                                                   pdf: pdf,
                                                   maxWidth: 520,
                                                   inkScale: 1,
                                                   imageLoader: { images[$0] })
            let data = rendered.pngData()
            if let data {
                try? data.write(to: url, options: .atomic)
            }
            Task { @MainActor in
                self?.thumbnailCache.setObject(rendered, forKey: pageID.uuidString as NSString)
                self?.thumbnailRevision += 1
            }
        }
    }

    /// 返回缩略图：只读内存缓存 / 磁盘，**不同步渲染**。
    /// 这个函数是在 SwiftUI body 里被调用的，同步渲染整页实测要 1.5 秒，
    /// 会直接把书写和滚动卡死；没有现成图片时丢给后台补一张，这次先返回 nil。
    func ensureThumbnail(noteID: UUID, pageID: UUID?) -> UIImage? {
        guard let pageID else { return nil }

        if let cached = thumbnailCache.object(forKey: pageID.uuidString as NSString) {
            return cached
        }
        let url = thumbnailURL(noteID: noteID, pageID: pageID)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            thumbnailCache.setObject(image, forKey: pageID.uuidString as NSString)
            return image
        }
        scheduleThumbnail(noteID: noteID, pageID: pageID)
        return nil
    }

    func invalidateThumbnail(pageID: UUID) {
        thumbnailCache.removeObject(forKey: pageID.uuidString as NSString)
    }

    // MARK: - PDF

    func pdfDocument(for noteID: UUID) -> PDFDocument? {
        if let cached = pdfDocuments[noteID] { return cached }
        guard let note = note(id: noteID), let name = note.pdfFileName else { return nil }
        let url = noteFolder(noteID).appendingPathComponent(name)
        guard let document = PDFDocument(url: url) else { return nil }
        pdfDocuments[noteID] = document
        return document
    }

    func pdfPageImage(noteID: UUID, pageIndex: Int, size: CGSize, scale: CGFloat = 3) -> UIImage? {
        let key = "\(noteID.uuidString)-\(pageIndex)-\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString
        if let cached = pdfPageCache.object(forKey: key) { return cached }
        guard let document = pdfDocument(for: noteID),
              let page = document.page(at: pageIndex) else { return nil }

        let target = CGSize(width: max(size.width, 1) * scale, height: max(size.height, 1) * scale)
        let image = page.thumbnail(of: target, for: .mediaBox)
        pdfPageCache.setObject(image, forKey: key)
        return image
    }

    @discardableResult
    func importPDF(from url: URL) throws -> Note {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url), document.pageCount > 0,
              let firstPage = document.page(at: 0) else {
            throw NoteStoreError.invalidPDF
        }

        let bounds = firstPage.bounds(for: .mediaBox)
        let rotated = firstPage.rotation % 180 != 0
        let pageSize = CGSize(width: max(rotated ? bounds.height : bounds.width, 100),
                              height: max(rotated ? bounds.width : bounds.height, 100))

        let title = url.deletingPathExtension().lastPathComponent
        var note = Note(title: title,
                        pages: (0..<document.pageCount).map { _ in NotePage() },
                        paperTemplate: .blank,
                        paperTint: .white,
                        pageSize: pageSize)
        note.pdfFileName = "source.pdf"
        note.pdfPageCount = document.pageCount

        let folder = noteFolder(note.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: folder.appendingPathComponent("source.pdf"))

        notes.insert(note, at: 0)
        saveNow()
        return note
    }

    // MARK: - 导出

    func exportPDF(noteID: UUID) -> URL? {
        guard let note = note(id: noteID) else { return nil }
        let drawings = note.pages.map { drawing(noteID: noteID, pageID: $0.id) }
        let data = PageRenderer.pdfData(note: note,
                                        drawings: drawings,
                                        pdf: pdfDocument(for: noteID),
                                        imageLoader: { [weak self] name in
                                            self?.image(noteID: noteID, fileName: name)
                                        })

        let safeTitle = note.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safeTitle.isEmpty ? "Slate" : safeTitle
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = "导出 PDF 失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 把某一页导出为 PNG（含 PDF 底稿、图片、笔迹与文字）
    func exportPageImage(noteID: UUID, pageIndex: Int) -> URL? {
        guard let note = note(id: noteID), note.pages.indices.contains(pageIndex) else { return nil }
        let pageID = note.pages[pageIndex].id
        let image = PageRenderer.renderPage(note: note,
                                            pageIndex: pageIndex,
                                            drawing: drawing(noteID: noteID, pageID: pageID),
                                            pdf: pdfDocument(for: noteID),
                                            inkScale: 3,
                                            imageLoader: { [weak self] name in
                                                self?.image(noteID: noteID, fileName: name)
                                            })
        guard let data = image.pngData() else {
            errorMessage = "导出图片失败"
            return nil
        }
        let safeTitle = note.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (safeTitle.isEmpty ? "Slate" : safeTitle) + "-第\(pageIndex + 1)页"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = "导出图片失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 录音

    func audioURL(noteID: UUID) -> URL {
        noteFolder(noteID).appendingPathComponent("audio.m4a")
    }

    func prepareForRecording(_ noteID: UUID) {
        update(noteID) { note in
            note.markers.removeAll()
            note.inkStamps.removeAll()
            note.audioFileName = nil
            note.audioDuration = 0
        }
        beginInkTimeline(noteID: noteID)
        let url = audioURL(noteID: noteID)
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    func finishRecording(_ noteID: UUID, duration: TimeInterval) {
        update(noteID) { note in
            note.audioFileName = "audio.m4a"
            note.audioDuration = duration
            if note.markers.isEmpty {
                note.markers = [AudioMarker(pageIndex: 0, time: 0)]
            }
        }
        flushInkTimeline(noteID: noteID)
    }

    func removeRecording(_ noteID: UUID) {
        update(noteID) { note in
            note.audioFileName = nil
            note.audioDuration = 0
            note.markers.removeAll()
            note.inkStamps.removeAll()
        }
        inkStampBuffer[noteID] = nil
        let url = audioURL(noteID: noteID)
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: 逐笔时间轴

    /// 录音期间每落一笔都会打点，直接写进 notes 会触发整页重绘，
    /// 所以先攒在内存里，录完再一次性落盘。
    private var inkStampBuffer: [UUID: [InkStamp]] = [:]

    func beginInkTimeline(noteID: UUID) {
        inkStampBuffer[noteID] = []
    }

    func addInkStamp(noteID: UUID, pageID: UUID, time: TimeInterval, strokeCount: Int) {
        var buffer = inkStampBuffer[noteID] ?? []
        buffer.append(InkStamp(pageID: pageID, time: time, strokeCount: strokeCount))
        inkStampBuffer[noteID] = buffer
    }

    func flushInkTimeline(noteID: UUID) {
        guard let buffer = inkStampBuffer[noteID], !buffer.isEmpty else {
            inkStampBuffer[noteID] = nil
            return
        }
        inkStampBuffer[noteID] = nil
        update(noteID) { note in
            note.inkStamps.append(contentsOf: buffer)
        }
    }

    /// 回放到某个时刻，这一页应该显示多少条笔迹；没有时间轴时返回 nil（正常显示）
    func replayStrokeCount(noteID: UUID, pageID: UUID, time: TimeInterval) -> Int? {
        guard let note = note(id: noteID) else { return nil }
        var stamps = note.inkStamps
        if let buffered = inkStampBuffer[noteID], !buffered.isEmpty {
            stamps.append(contentsOf: buffered)
        }
        let pageStamps = stamps.filter { $0.pageID == pageID }
        guard !pageStamps.isEmpty else { return nil }

        // 录音开始前这一页已有的笔迹，回放时始终可见，之后才是逐笔出现
        let baseline = max((pageStamps.first?.strokeCount ?? 1) - 1, 0)
        if let first = pageStamps.first, time < first.time - 0.05 { return baseline }

        var count = baseline
        for stamp in pageStamps where stamp.time <= time + 0.05 {
            count = max(count, stamp.strokeCount)
        }
        return count
    }

    func hasInkTimeline(noteID: UUID) -> Bool {
        if let buffered = inkStampBuffer[noteID], !buffered.isEmpty { return true }
        return !(note(id: noteID)?.inkStamps.isEmpty ?? true)
    }

    func addMarker(noteID: UUID, pageIndex: Int, time: TimeInterval) {
        update(noteID) { note in
            if let last = note.markers.last, abs(last.time - time) < 1.0, last.pageIndex == pageIndex {
                return
            }
            note.markers.append(AudioMarker(pageIndex: pageIndex, time: time))
            note.markers.sort { $0.time < $1.time }
        }
    }

    // MARK: - 路径

    func noteFolder(_ noteID: UUID) -> URL {
        notesURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
    }

    // MARK: 页面图片

    /// 把图片写进笔记目录，返回文件名
    func saveImage(_ data: Data, noteID: UUID) throws -> String {
        let name = "img_\(UUID().uuidString).png"
        let url = noteFolder(noteID).appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    func image(noteID: UUID, fileName: String) -> UIImage? {
        let key = "\(noteID.uuidString)-\(fileName)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let url = noteFolder(noteID).appendingPathComponent(fileName)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private func drawingURL(noteID: UUID, pageID: UUID) -> URL {
        noteFolder(noteID).appendingPathComponent("p_\(pageID.uuidString).drawing")
    }

    private func thumbnailURL(noteID: UUID, pageID: UUID) -> URL {
        noteFolder(noteID).appendingPathComponent("t_\(pageID.uuidString).png")
    }
}

// MARK: - 首次启动的示例内容

private enum WelcomeContent {
    static let textBoxes: [TextBox] = [
        TextBox(text: "欢迎使用 Slate",
                x: 74, y: 120, width: 560, height: 60,
                fontSize: 38, colorHex: "#1C1C1E"),
        TextBox(text: "一款为 iPad 与 Apple Pencil 打造的手写笔记应用。",
                x: 74, y: 196, width: 560, height: 40,
                fontSize: 20, colorHex: "#4B4B52"),
        TextBox(text: "左侧工具栏：钢笔、铅笔、荧光笔、橡皮、套索、文字\n工具面板：颜色与笔迹粗细（浮在页面上，不挤开纸张）\n右上角：撤销 / 重做、录音、缩略图、手指拖动、导出 PDF\n右侧缩略图栏底部 + 号可插入新页面",
                x: 74, y: 300, width: 600, height: 190,
                fontSize: 20, colorHex: "#1C1C1E"),
        TextBox(text: "现在，开始写点什么吧。",
                x: 74, y: 540, width: 560, height: 40,
                fontSize: 24, colorHex: "#2D6CDF")
    ]
}
