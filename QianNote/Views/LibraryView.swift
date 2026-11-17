import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var opener: DocumentOpenCoordinator
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var selectedFolder: UUID?
    @State private var favoritesOnly = false
    @State private var sortOption: SortOption = .updated
    @State private var showImporter = false
    @State private var showIconPicker = false
    @State private var showAbout = false
    /// 备份：选一个目录，把整个资料库拷进去
    @State private var showBackupPicker = false
    /// 恢复：选一个备份目录，把笔记合并回来
    @State private var showRestorePicker = false
    @State private var backupMessage: String?
    @StateObject private var iconManager = AppIconManager()

    @State private var prompt: LibraryPrompt?
    @State private var promptText = ""

    enum SortOption: String, CaseIterable, Identifiable {
        case updated = "最近修改"
        case created = "创建时间"
        case title = "标题"

        var id: String { rawValue }
    }

    enum LibraryPrompt: Identifiable {
        case newFolder
        case rename(UUID)

        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .rename(let id): return "rename-\(id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .newFolder: return "新建文件夹"
            case .rename: return "重命名笔记"
            }
        }

        var confirmTitle: String {
            switch self {
            case .newFolder: return "创建"
            case .rename: return "保存"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.libraryBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        folderChips

                        if filteredNotes.isEmpty {
                            EmptyLibraryView(onCreate: createNote, onImport: { showImporter = true })
                        } else {
                            LazyVGrid(columns: columns,
                                      alignment: .leading,
                                      spacing: compact ? 18 : 26) {
                                ForEach(filteredNotes) { note in
                                    NavigationLink(value: note.id) {
                                        NoteCardView(note: note,
                                                     previewHeight: compact ? 168 : 210)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { contextMenu(for: note) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, compact ? 16 : 24)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("笔记")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或手写内容")
            .task {
                // 后台补手写索引：只算缺失 / 过期的页，算过的不会重来
                await store.indexHandwritingIfNeeded()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showIconPicker = true
                    } label: {
                        Image(systemName: "app.badge")
                    }
                    .help("更换 App 图标")
                    sortMenu
                    addMenu
                }
            }
            .sheet(isPresented: $showIconPicker) {
                AppIconPicker(manager: iconManager)
            }
            .sheet(isPresented: $showAbout) {
                NavigationStack { AboutView() }
            }
            .alert("提示", isPresented: Binding(get: { iconManager.errorMessage != nil },
                                                set: { if !$0 { iconManager.errorMessage = nil } })) {
                Button("好", role: .cancel) { iconManager.errorMessage = nil }
            } message: {
                Text(iconManager.errorMessage ?? "")
            }
            .navigationDestination(for: UUID.self) { id in
                EditorView(noteID: id)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importTypes,
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .modifier(LibraryBackupModifier(showBackupPicker: $showBackupPicker,
                                            showRestorePicker: $showRestorePicker,
                                            message: $backupMessage,
                                            onBackup: handleBackup,
                                            onRestore: handleRestore))
            .alert(prompt?.title ?? "", isPresented: promptBinding) {
                TextField("名称", text: $promptText)
                Button("取消", role: .cancel) { prompt = nil }
                Button(prompt?.confirmTitle ?? "确定") { commitPrompt() }
            }
            .overlay(alignment: .bottom) {
                if let message = bannerMessage {
                    ErrorBanner(message: message) {
                        store.errorMessage = nil
                        opener.errorMessage = nil
                    }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: bannerMessage)
            // 冷启动的快捷操作、外部文档导入完成，都在这里消费
            .task {
                iconManager.repairIfNeeded()
                consumePending()
            }
            .onChange(of: opener.noteToOpen) { _, _ in consumePending() }
            .onReceive(NotificationCenter.default.publisher(for: .qianNoteShortcutTriggered)) { _ in
                consumePending()
            }
        }
    }

    // MARK: - 工具栏菜单

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            Divider()

            Button {
                startPrompt(.newFolder)
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }

            if let selectedFolder,
               let folder = store.folders.first(where: { $0.id == selectedFolder }) {
                Button(role: .destructive) {
                    store.deleteFolder(folder.id)
                    self.selectedFolder = nil
                } label: {
                    Label("删除「\(folder.name)」", systemImage: "trash")
                }
            }

            Divider()

            Button {
                showAbout = true
            } label: {
                Label("关于", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                createNote()
            } label: {
                Label("新建笔记", systemImage: "square.and.pencil")
            }
            Button {
                showImporter = true
            } label: {
                Label("导入文档", systemImage: "doc.badge.plus")
            }
            Button {
                startPrompt(.newFolder)
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                showBackupPicker = true
            } label: {
                Label("备份到文件夹…", systemImage: "arrow.up.doc.on.clipboard")
            }
            Button {
                showRestorePicker = true
            } label: {
                Label("从备份恢复…", systemImage: "arrow.down.doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
                .font(.headline)
        }
    }

    // MARK: - 文件夹筛选

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", active: selectedFolder == nil && !favoritesOnly) {
                    selectedFolder = nil
                    favoritesOnly = false
                }

                chip(title: "收藏", systemImage: "star.fill", active: favoritesOnly) {
                    favoritesOnly.toggle()
                    if favoritesOnly { selectedFolder = nil }
                }

                ForEach(store.folders) { folder in
                    chip(title: folder.name, systemImage: "folder", active: selectedFolder == folder.id) {
                        selectedFolder = folder.id
                        favoritesOnly = false
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(title: String, systemImage: String? = nil, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(active ? Theme.accent : Color.primary.opacity(0.06))
            )
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.75))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    private var filteredNotes: [Note] {
        var result = store.notes
        if favoritesOnly { result = result.filter(\.isFavorite) }
        if let selectedFolder { result = result.filter { $0.folderID == selectedFolder } }
        if !searchText.isEmpty {
            // 标题 + 手写 OCR + 文字框，三处任意命中即算匹配
            result = result.filter { store.matches($0, query: searchText) }
        }
        switch sortOption {
        case .updated: result.sort { $0.updatedAt > $1.updatedAt }
        case .created: result.sort { $0.createdAt > $1.createdAt }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return result
    }

    // MARK: - 布局 / 外部入口

    private var compact: Bool { sizeClass == .compact }

    private var columns: [GridItem] {
        compact
            ? [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 14)]
            : [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 22)]
    }

    private var bannerMessage: String? {
        store.errorMessage ?? opener.errorMessage
    }

    /// 处理「外部打开文档」与「主屏快捷操作」两个入口。
    /// 两者都会在 App 已经停在编辑页时触发，所以先把导航栈退回书架再跳转。
    private func consumePending() {
        if let shortcut = ShortcutInbox.take() {
            switch shortcut {
            case .newNote:
                present { createNote() }
            case .importDocument:
                returnToLibrary()
                showImporter = true
            }
        }

        if let id = opener.noteToOpen {
            opener.noteToOpen = nil
            present { path.append(id) }
        }
    }

    private func present(_ action: () -> Void) {
        returnToLibrary()
        action()
    }

    private func returnToLibrary() {
        guard !path.isEmpty else { return }
        path = NavigationPath()
    }

    // MARK: - 提示框

    private var promptBinding: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private func startPrompt(_ value: LibraryPrompt) {
        switch value {
        case .newFolder:
            promptText = ""
        case .rename(let id):
            promptText = store.note(id: id)?.title ?? ""
        }
        prompt = value
    }

    private func commitPrompt() {
        guard let prompt else { return }
        switch prompt {
        case .newFolder:
            store.addFolder(named: promptText)
        case .rename(let id):
            store.rename(id, to: promptText)
        }
        self.prompt = nil
    }

    // MARK: - 操作

    private func createNote() {
        let note = store.createNote(folderID: selectedFolder)
        path.append(note.id)
    }

    private var importTypes: [UTType] {
        var types: [UTType] = [.pdf, .image, .rtf, .html, .plainText]
        for ext in ["doc", "docx", "rtfd", "md"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            importFile(first)
        case .failure(let error):
            store.errorMessage = error.localizedDescription
        }
    }

    // MARK: - 资料库备份 / 恢复

    private func handleBackup(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                let created = try store.backupLibrary(to: folder)
                let count = store.notes.count
                backupMessage = "已备份 \(count) 篇笔记\n\(created.lastPathComponent)"
            } catch {
                store.errorMessage = "备份失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            store.errorMessage = error.localizedDescription
        }
    }

    private func handleRestore(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                let restored = try store.restoreLibrary(from: folder)
                if restored > 0 {
                    backupMessage = "已恢复 \(restored) 篇笔记"
                } else {
                    backupMessage = "这个备份里的笔记都不比本地新，没有需要恢复的内容。"
                }
            } catch {
                store.errorMessage = "恢复失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            store.errorMessage = error.localizedDescription
        }
    }

    /// PDF 直接用；Word / RTF / HTML / 图片先转成 PDF，再走同一条导入管线
    private func importFile(_ url: URL) {
        Task { @MainActor in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let pdfURL = try await DocumentImporter.shared.convertToPDF(url: url)
                let note = try store.importPDF(from: pdfURL)
                path.append(note.id)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for note: Note) -> some View {
        Button {
            startPrompt(.rename(note.id))
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Button {
            store.toggleFavorite(note.id)
        } label: {
            Label(note.isFavorite ? "取消收藏" : "收藏", systemImage: "star")
        }

        Button {
            store.duplicate(note.id)
        } label: {
            Label("复制副本", systemImage: "doc.on.doc")
        }

        Menu {
            Button("未分类") { store.move(note.id, to: nil) }
            ForEach(store.folders) { folder in
                Button(folder.name) { store.move(note.id, to: folder.id) }
            }
        } label: {
            Label("移动到文件夹", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            store.delete(note.id)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

// MARK: - 备份 / 恢复的界面装配

/// 单独抽出来，避免 LibraryView 的 body 表达式过长导致 Swift 类型检查超时。
private struct LibraryBackupModifier: ViewModifier {
    @Binding var showBackupPicker: Bool
    @Binding var showRestorePicker: Bool
    @Binding var message: String?
    let onBackup: (Result<[URL], Error>) -> Void
    let onRestore: (Result<[URL], Error>) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $showBackupPicker,
                          allowedContentTypes: [.folder]) { result in onBackup(result.map { [$0] }) }
            .fileImporter(isPresented: $showRestorePicker,
                          allowedContentTypes: [.folder]) { result in onRestore(result.map { [$0] }) }
            .alert("备份", isPresented: Binding(get: { message != nil },
                                              set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
    }
}
