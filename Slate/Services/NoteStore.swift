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
    /// 每页独立的版本号。旧版是一个全局 `Int`，任何一页刷新都会让所有缩略图单元格重跑，
    /// 而且分不清「哪一页变了」。按页记版本后，只有真正更新的那一页会重新取图。
    @Published private(set) var thumbnailVersions: [UUID: Int] = [:]
    @Published var errorMessage: String?

    // MARK: 存储位置

    private let fm = FileManager.default
    private let rootURL: URL
    private let notesURL: URL
    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "com.slate.store.io", qos: .utility)
    /// 缩略图渲染单独一条队列。
    /// 之前和落盘共用一条串行 ioQueue：书写时每 0.25 秒的保存都排在它前面，
    /// 缩略图那几十毫秒只能等着，表现就是「明明停了笔，缩略图还是不动」。
    private let thumbnailQueue = DispatchQueue(label: "com.slate.store.thumbnail", qos: .userInitiated)

    // MARK: 缓存

    private var drawingCache: [UUID: PKDrawing] = [:]
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let pdfPageCache = NSCache<NSString, UIImage>()
    private let imageCache = NSCache<NSString, UIImage>()
    private var pdfDocuments: [UUID: PDFDocument] = [:]

    private var saveTask: Task<Void, Never>?
    /// 排队等待渲染的缩略图（每页最多一个，避免书写时堆积）
    private var thumbnailWork: [UUID: DispatchWorkItem] = [:]
    /// 上一次渲染完成的时刻，用来节流
    private var lastThumbnailAt: [UUID: Date] = [:]
    /// 正在后台渲染的页
    private var thumbnailInFlight: Set<UUID> = []
    /// 底稿缓存（纸张 / PDF 页），书写时这层不变，重画纯属浪费
    private let baseLayerCache = NSCache<NSString, UIImage>()
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
        baseLayerCache.countLimit = 200

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
        if notes.isEmpty { seed() } else { sanitizeTextBoxes() }
    }

    /// 清理历史遗留的坏文字框：
    /// 1) 空内容的框（旧版新建后取消编辑会留下「点按输入文字」的僵尸框）；
    /// 2) 宽度 <= 0 或跑到页面外的框（旧版在页面右边缘点按会把宽度算成负数，
    ///    这种框连命中区域都是空的，点不到也看不到删除按钮，等于永久删不掉）。
    private func sanitizeTextBoxes() {
        var changed = false
        for noteIndex in notes.indices {
            let pageWidth = notes[noteIndex].pageSize.width
            for pageIndex in notes[noteIndex].pages.indices {
                let before = notes[noteIndex].pages[pageIndex].textBoxes
                var boxes = before.filter {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                for i in boxes.indices {
                    if boxes[i].width < 40 {
                        boxes[i].width = 200
                        changed = true
                    }
                    let maxX = max(pageWidth - 40, 0)
                    if boxes[i].x < 0 || boxes[i].x > maxX {
                        boxes[i].x = min(max(boxes[i].x, 0), maxX)
                        changed = true
                    }
                    if boxes[i].y < 0 {
                        boxes[i].y = 0
                        changed = true
                    }
                }
                if boxes.count != before.count {
                    changed = true
                }
                notes[noteIndex].pages[pageIndex].textBoxes = boxes
            }
        }
        if changed { scheduleSave() }
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
        // 页面顺序变了，PDF 页序跟着错位，底稿缓存整本作废（条目本身也很便宜）
        baseLayerCache.removeAllObjects()
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
        baseLayerCache.removeAllObjects()
    }

    func deletePage(noteID: UUID, at index: Int) {
        guard let note = note(id: noteID),
              note.pages.indices.contains(index),
              note.pages.count > 1 else { return }
        let page = note.pages[index]

        update(noteID) { $0.pages.remove(at: index) }
        baseLayerCache.removeAllObjects()

        drawingCache[page.id] = nil
        thumbnailWork[page.id]?.cancel()
        thumbnailWork[page.id] = nil
        thumbnailInFlight.remove(page.id)
        lastThumbnailAt[page.id] = nil
        thumbnailCache.removeObject(forKey: page.id.uuidString as NSString)
        thumbnailVersions[page.id] = nil
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
        baseLayerCache.removeAllObjects()
    }

    func clearPage(noteID: UUID, pageID: UUID) {
        saveDrawing(PKDrawing(), noteID: noteID, pageID: pageID)
    }

    func setPaper(noteID: UUID, template: PaperTemplate, tint: PaperTint) {
        update(noteID) { note in
            note.paperTemplate = template
            note.paperTint = tint
        }
        // 底稿缓存里存的是旧纸张，整本作废
        baseLayerCache.removeAllObjects()
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

        requestThumbnail(noteID: noteID, pageID: pageID)
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

    /// 连续书写时两次渲染的最小间隔
    private static let minThumbnailInterval: TimeInterval = 0.9
    /// 一次渲染最早多久之后启动（等落盘的 0.25 秒消抖先跑完）
    private static let thumbnailStartDelay: TimeInterval = 0.15

    /// 请求刷新某一页的缩略图。
    ///
    /// 旧版是「每次落盘都把定时器重置到 1.2 秒之后」——一直在写就永远不刷新，
    /// 抬笔之后还得再等 1.2 秒 + 一次整页渲染，所以看起来半天不动。
    /// 现在换成节流而不是消抖：
    /// 1) 距上一次渲染已经超过 `minThumbnailInterval` → 0.15 秒后立刻补一版，抬笔几乎马上看到更新；
    /// 2) 正在连续书写 → 最多每 0.9 秒出一版，不会因为请求不断而被无限推迟。
    private func requestThumbnail(noteID: UUID, pageID: UUID) {
        // 已经在渲染 / 已经排好队，就不要再插一个：结束时会按墨迹代计数自己补新版
        guard !thumbnailInFlight.contains(pageID), thumbnailWork[pageID] == nil else { return }

        let now = Date()
        var delay = Self.thumbnailStartDelay
        if let last = lastThumbnailAt[pageID] {
            delay = max(Self.thumbnailStartDelay,
                        Self.minThumbnailInterval - now.timeIntervalSince(last))
        }

        let work = DispatchWorkItem { [weak self] in
            self?.thumbnailWork[pageID] = nil
            self?.generateThumbnail(noteID: noteID, pageID: pageID)
        }
        thumbnailWork[pageID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func generateThumbnail(noteID: UUID, pageID: UUID) {
        guard let note = note(id: noteID),
              let pageIndex = note.pages.firstIndex(where: { $0.id == pageID }) else { return }

        // 墨迹直接从内存缓存取（saveDrawing 里已经同步写过一份），不要在后台线程碰字典
        let drawing = drawing(noteID: noteID, pageID: pageID)
        let generation = drawingGenerationValue(pageID)
        let pdf = pdfDocument(for: noteID)

        // 图片资源也先在主线程取（走内存缓存），渲染本身必须离开主线程：
        // 整页「纸张 + PDF + 墨迹」合成实测要 1.5 秒，放在主线程等于每写一会儿就冻住一次，
        // PencilKit 收不到触摸点，笔迹就断在半路。
        var images: [String: UIImage] = [:]
        for item in note.pages[safe: pageIndex]?.images ?? [] {
            if let image = image(noteID: noteID, fileName: item.fileName) {
                images[item.fileName] = image
            }
        }

        // 缩略图最宽 520pt；墨迹按输出比例栅格化（以前固定 1 倍再缩小，等于白算 4 倍像素）
        let maxWidth: CGFloat = 520
        let inkScale = min(1, PageRenderer.outputScale(note: note, maxWidth: maxWidth))
        let baseKey = baseLayerKey(noteID: noteID, pageID: pageID, pageIndex: pageIndex,
                                   note: note, maxWidth: maxWidth) as NSString
        let cachedBase = baseLayerCache.object(forKey: baseKey)
        let url = thumbnailURL(noteID: noteID, pageID: pageID)

        lastThumbnailAt[pageID] = Date()
        thumbnailInFlight.insert(pageID)

        thumbnailQueue.async { [weak self] in
            let base = cachedBase ?? PageRenderer.renderBase(note: note,
                                                            pageIndex: pageIndex,
                                                            pdf: pdf,
                                                            maxWidth: maxWidth)
            let rendered = PageRenderer.renderPage(note: note,
                                                   pageIndex: pageIndex,
                                                   drawing: drawing,
                                                   pdf: pdf,
                                                   maxWidth: maxWidth,
                                                   inkScale: inkScale,
                                                   baseLayer: base,
                                                   imageLoader: { images[$0] })
            if let data = rendered.pngData() {
                try? data.write(to: url, options: .atomic)
            }

            Task { @MainActor in
                guard let self else { return }
                self.thumbnailInFlight.remove(pageID)
                if cachedBase == nil {
                    self.baseLayerCache.setObject(base, forKey: baseKey)
                }
                self.thumbnailCache.setObject(rendered, forKey: pageID.uuidString as NSString)
                self.thumbnailVersions[pageID, default: 0] += 1

                // 渲染这段时间里又写了新墨迹：再补一版，别让缩略图停在上一笔
                if self.drawingGenerationValue(pageID) != generation {
                    self.requestThumbnail(noteID: noteID, pageID: pageID)
                }
            }
        }
    }

    private func baseLayerKey(noteID: UUID, pageID: UUID, pageIndex: Int,
                              note: Note, maxWidth: CGFloat) -> String {
        // 模板 / 底色 / 尺寸 / PDF 页序任何一项变了，底稿就得重画
        [
            noteID.uuidString,
            pageID.uuidString,
            String(pageIndex),
            note.paperTemplate.rawValue,
            note.paperTint.rawValue,
            String(Int(note.pageSize.width)),
            String(Int(note.pageSize.height)),
            String(Int(maxWidth))
        ].joined(separator: "-")
    }

    private func drawingGenerationValue(_ pageID: UUID) -> Int {
        drawingLock.lock()
        defer { drawingLock.unlock() }
        return drawingGeneration[pageID] ?? 0
    }

    /// 取缩略图（异步）：内存缓存 → 磁盘 → 都没有就返回 nil 并安排后台补一张。
    ///
    /// 旧版是同步 `Data(contentsOf:)` + `UIImage(data:)`，而它是在 SwiftUI 的 `.task` / body 里被调用的。
    /// 一屏十几张卡片就是十几次主线程磁盘读 + 图片解码，进入编辑页、回到书架时都会有明显停顿。
    func thumbnail(noteID: UUID, pageID: UUID?) async -> UIImage? {
        guard let pageID else { return nil }

        if let cached = thumbnailCache.object(forKey: pageID.uuidString as NSString) {
            return cached
        }

        let url = thumbnailURL(noteID: noteID, pageID: pageID)
        let stored: UIImage? = await withCheckedContinuation { continuation in
            thumbnailQueue.async {
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.decodedImage(data))
            }
        }

        if let stored {
            thumbnailCache.setObject(stored, forKey: pageID.uuidString as NSString)
            return stored
        }

        requestThumbnail(noteID: noteID, pageID: pageID)
        return nil
    }

    /// 磁盘上的 PNG 是延迟解码的，交给 SwiftUI 首次绘制时才解会掉帧；这里先解一遍
    private static func decodedImage(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    func invalidateThumbnail(noteID: UUID, pageID: UUID) {
        thumbnailCache.removeObject(forKey: pageID.uuidString as NSString)
        requestThumbnail(noteID: noteID, pageID: pageID)
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
