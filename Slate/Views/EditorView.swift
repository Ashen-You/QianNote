import SwiftUI
import PencilKit

struct EditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    let noteID: UUID

    @StateObject private var tools = ToolStore()
    @StateObject private var canvasController = CanvasController()
    @State private var audio = AudioController()

    @State private var pageIndex = 0
    @State private var showPagePanel = true
    @State private var showRename = false
    @State private var renameText = ""
    @State private var sheet: EditorSheet?
    @State private var errorMessage: String?

    enum EditorSheet: Identifiable {
        case share(URL)
        case paper

        var id: String {
            switch self {
            case .share(let url): return "share-\(url.absoluteString)"
            case .paper: return "paper"
            }
        }
    }

    private var note: Note? { store.note(id: noteID) }

    var body: some View {
        ZStack {
            Theme.editorBackground.ignoresSafeArea()

            if let note {
                workspace(note)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("这本笔记已被删除")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .overlay(alignment: .top) {
            AudioPanelView(audio: audio, noteID: noteID, title: note?.title ?? "")
                .padding(.top, 74)
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .share(let url):
                ShareSheet(items: [url])
            case .paper:
                paperSheet
            }
        }
        .alert("重命名笔记", isPresented: $showRename) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { store.rename(noteID, to: renameText) }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                ErrorBanner(message: errorMessage) { self.errorMessage = nil }
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .onDisappear {
            if audio.mode == .recording {
                let duration = audio.stopRecording()
                store.finishRecording(noteID, duration: duration)
            } else {
                audio.stop()
            }
            store.markUpdated(noteID)
        }
    }

    // MARK: - 主工作区

    private func workspace(_ note: Note) -> some View {
        HStack(spacing: 0) {
            ToolRailView(tools: tools)
                .padding(.leading, 12)
                .frame(maxHeight: .infinity, alignment: .center)

            pageArea(note)

            if showPagePanel {
                PageStripView(note: note, pageIndex: $pageIndex)
                    .frame(width: 118)
                    .padding(.trailing, 10)
            }
        }
        .padding(.top, 70)
        .padding(.bottom, 84)
        .overlay {
            AudioSyncView(audio: audio,
                          noteID: noteID,
                          markers: note.markers,
                          pageIndex: $pageIndex)
        }
        .onAppear {
            pageIndex = min(pageIndex, max(note.pages.count - 1, 0))
        }
        .onChange(of: note.pages.count) { _, newCount in
            if pageIndex >= newCount {
                pageIndex = max(0, newCount - 1)
            }
        }
    }

    private func pageArea(_ note: Note) -> some View {
        GeometryReader { geo in
            let pageWidth = CGFloat(max(note.pageWidth, 1))
            let pageHeight = CGFloat(max(note.pageHeight, 1))
            let scale = max(0.1, min((geo.size.width - 24) / pageWidth, (geo.size.height - 24) / pageHeight))

            NotePageView(note: note,
                         pageIndex: pageIndex,
                         tools: tools,
                         controller: canvasController)
                .frame(width: pageWidth, height: pageHeight)
                .scaleEffect(scale, anchor: .center)
                .frame(width: pageWidth * scale, height: pageHeight * scale)
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 10)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                    Text("笔记")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            Button {
                renameText = note?.title ?? ""
                showRename = true
            } label: {
                HStack(spacing: 5) {
                    Text(note?.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                IconButton(systemName: "arrow.uturn.backward",
                           isActive: false,
                           label: "撤销") { canvasController.undo() }
                    .opacity(canvasController.canUndo ? 1 : 0.35)
                    .disabled(!canvasController.canUndo)

                IconButton(systemName: "arrow.uturn.forward",
                           isActive: false,
                           label: "重做") { canvasController.redo() }
                    .opacity(canvasController.canRedo ? 1 : 0.35)
                    .disabled(!canvasController.canRedo)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))

            AudioToolbarView(audio: audio,
                             noteID: noteID,
                             hasRecording: note?.hasRecording ?? false,
                             onError: { errorMessage = $0 })
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

            IconButton(systemName: "sidebar.right",
                       isActive: showPagePanel,
                       label: "页面缩略图") {
                withAnimation(.easeInOut(duration: 0.2)) { showPagePanel.toggle() }
            }

            Menu {
                Button {
                    sheet = .paper
                } label: {
                    Label("纸张样式", systemImage: "square.grid.2x2")
                }
                Button {
                    store.addPage(noteID: noteID, after: pageIndex)
                    pageIndex += 1
                } label: {
                    Label("插入新页面", systemImage: "plus.square")
                }
                Button {
                    canvasController.resetHistory()
                    store.clearPage(noteID: noteID, pageID: note?.pages[safe: pageIndex]?.id ?? UUID())
                } label: {
                    Label("清空当前页", systemImage: "eraser.line.dashed")
                }
                Divider()
                if note?.hasRecording == true {
                    Button(role: .destructive) {
                        audio.stop()
                        store.removeRecording(noteID)
                    } label: {
                        Label("删除录音", systemImage: "waveform.slash")
                    }
                }
                Button {
                    exportPDF()
                } label: {
                    Label("导出 PDF", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 14) {
            StyleBarView(tools: tools)

            if let note {
                pageIndicator(note)
            }
        }
        .padding(.bottom, 10)
    }

    private func pageIndicator(_ note: Note) -> some View {
        HStack(spacing: 6) {
            Button {
                pageIndex = max(0, pageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(pageIndex == 0)
            .opacity(pageIndex == 0 ? 0.3 : 0.8)

            Text("\(pageIndex + 1) / \(note.pages.count)")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 54)

            Button {
                pageIndex = min(note.pages.count - 1, pageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(pageIndex >= note.pages.count - 1)
            .opacity(pageIndex >= note.pages.count - 1 ? 0.3 : 0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    // MARK: - 纸张选择

    private var paperSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if note?.hasPDF == true {
                        Text("这是 PDF 笔记：纸张样式只在新增的空白页上生效。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("模板")
                            .font(.subheadline.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                            ForEach(PaperTemplate.allCases) { template in
                                Button {
                                    applyPaper(template: template, tint: note?.paperTint ?? .white)
                                } label: {
                                    VStack(spacing: 6) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.white)
                                            PaperBackgroundView(template: template, tint: note?.paperTint ?? .white)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        }
                                        .frame(height: 110)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(note?.paperTemplate == template ? Theme.accent : Color.primary.opacity(0.12),
                                                              lineWidth: note?.paperTemplate == template ? 2 : 1)
                                        )

                                        Text(template.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("纸张底色")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 10) {
                            ForEach(PaperTint.allCases) { tint in
                                Button {
                                    applyPaper(template: note?.paperTemplate ?? .ruled, tint: tint)
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(tint.surface)
                                            .frame(width: 20, height: 20)
                                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                                        Text(tint.title).font(.caption)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule().fill(note?.paperTint == tint ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Toggle(isOn: $tools.fingerDrawing) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("手指书写").font(.subheadline)
                            Text("关闭后只能用 Apple Pencil 书写，手指用于滚动与操作")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .navigationTitle("页面设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { sheet = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func applyPaper(template: PaperTemplate, tint: PaperTint) {
        store.setPaper(noteID: noteID, template: template, tint: tint)
        for page in note?.pages ?? [] {
            store.invalidateThumbnail(pageID: page.id)
        }
    }

    // MARK: - 导出

    private func exportPDF() {
        guard let url = store.exportPDF(noteID: noteID) else { return }
        sheet = .share(url)
    }
}
