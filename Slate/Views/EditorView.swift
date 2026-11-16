import SwiftUI
import PencilKit
import PhotosUI
import UIKit

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

    /// 沉浸式全屏：隐藏顶栏 / 底栏 / 工具栏 / 缩略图，页面铺满整屏
    @State private var immersive = false
    /// 全屏时按宽度还是按高度适配
    @State private var fitToWidth = false
    /// 工具面板（颜色 / 粗细）是否展开
    @State private var showPalette = true
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    /// 用户缩放倍率（1 = 适配整页）
    @State private var zoom: CGFloat = 1
    /// 缩放后的平移量（点）
    @State private var pan: CGSize = .zero

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
        .overlay(alignment: .top) {
            topBar
                .opacity(immersive ? 0 : 1)
                .allowsHitTesting(!immersive)
        }
        .overlay(alignment: .bottom) {
            bottomBar
                .opacity(immersive ? 0 : 1)
                .allowsHitTesting(!immersive)
        }
        .overlay(alignment: .top) {
            AudioPanelView(audio: audio, noteID: noteID, title: note?.title ?? "")
                .padding(.top, 74)
                .opacity(immersive ? 0 : 1)
                .allowsHitTesting(!immersive)
        }
        .overlay {
            if immersive, let note {
                immersiveControls(note)
                    .transition(.opacity)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { @MainActor in
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    insertImage(data)
                }
                photoItem = nil
            }
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
            if !immersive {
                HStack(alignment: .center, spacing: 8) {
                    ToolRailView(tools: tools, showPalette: $showPalette)

                    if showPalette {
                        ToolPaletteView(tools: tools)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(.leading, 12)
                .frame(maxHeight: .infinity, alignment: .center)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            pageArea(note)

            if showPagePanel && !immersive {
                PageStripView(note: note, pageIndex: $pageIndex)
                    .frame(width: 118)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, immersive ? 0 : 70)
        .padding(.bottom, immersive ? 0 : 84)
        .animation(.easeInOut(duration: 0.24), value: immersive)
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
            let inset: CGFloat = immersive ? 0 : 24
            let availableWidth = max(geo.size.width - inset, 1)
            let availableHeight = max(geo.size.height - inset, 1)
            let scaleToWidth = availableWidth / pageWidth
            let scaleToHeight = availableHeight / pageHeight
            // 全屏时可按宽度铺满（上下可滚动空间更大），否则取较小的那个保证整页可见
            let fit = max(0.1, immersive && fitToWidth ? scaleToWidth : min(scaleToWidth, scaleToHeight))
            let contentWidth = pageWidth * fit * zoom
            let contentHeight = pageHeight * fit * zoom

            NotePageView(note: note,
                         pageIndex: pageIndex,
                         tools: tools,
                         controller: canvasController,
                         pdfScale: pdfRenderScale(for: note.pageSize),
                         onPinch: { delta, focal in
                             applyPinch(delta, focal: focal,
                                        pageSize: note.pageSize, fit: fit, viewport: geo.size)
                         },
                         onPan: { delta in
                             applyPan(delta,
                                      contentSize: CGSize(width: contentWidth, height: contentHeight),
                                      viewport: geo.size)
                         },
                         onDoubleTap: { focal in
                             toggleZoom(focal: focal, pageSize: note.pageSize, fit: fit, viewport: geo.size)
                         },
                         onPencilDoubleTap: {
                             tools.togglePencilEraser()
                         },
                         shapeRecognition: tools.shapeRecognition,
                         onPenMove: { point in
                             followPen(point, pageSize: note.pageSize, fit: fit, viewport: geo.size)
                         })
                .frame(width: pageWidth, height: pageHeight)
                .scaleEffect(fit * zoom, anchor: .center)
                .frame(width: contentWidth, height: contentHeight)
                .shadow(color: Color.black.opacity(immersive ? 0 : 0.18),
                        radius: immersive ? 0 : 22, x: 0, y: immersive ? 0 : 10)
                .offset(clampedPan(contentSize: CGSize(width: contentWidth, height: contentHeight),
                                   viewport: geo.size))
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    zoomBadge
                        .padding(.trailing, 18)
                        .padding(.bottom, immersive ? 74 : 18)
                }
                .onChange(of: pageIndex) { _, _ in
                    resetZoom()
                }
        }
    }

    // MARK: - 缩放平移

    /// 缩放倍率对应的 PDF 渲染倍率：按档位取，避免每一帧都重新生成图片
    private func pdfRenderScale(for pageSize: CGSize) -> CGFloat {
        let base: CGFloat = zoom < 1.35 ? 3 : (zoom < 2.2 ? 4.5 : 6)
        // 按像素总量设上限（约 1200 万像素 / 48 MB），防止大倍率下内存暴涨
        let area = max(pageSize.width * pageSize.height, 1)
        let density = sqrt(12_000_000 / area)
        return min(base, max(2, density))
    }

    private var zoomBadge: some View {
        Group {
            if zoom > 1.02 {
                HStack(spacing: 8) {
                    Text(String(format: "%.1f×", zoom))
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Button {
                        withAnimation(.easeOut(duration: 0.22)) { resetZoom() }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Theme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("恢复整页")
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 32)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    private func applyPinch(_ delta: CGFloat, focal: CGPoint,
                            pageSize: CGSize, fit: CGFloat, viewport: CGSize) {
        let old = zoom
        let new = min(max(old * delta, 1), 6)
        guard abs(new - old) > 0.0005 else { return }

        // 保持捏合中心点在屏幕上不动
        let contentW = pageSize.width * fit * old
        let contentH = pageSize.height * fit * old
        let k = new / old
        pan.width += contentW * (k - 1) * (0.5 - focal.x)
        pan.height += contentH * (k - 1) * (0.5 - focal.y)

        zoom = new
        if new <= 1.001 {
            pan = .zero
        }
        pan = clampedPan(contentSize: CGSize(width: pageSize.width * fit * new,
                                             height: pageSize.height * fit * new),
                         viewport: viewport)
    }

    private func applyPan(_ delta: CGSize, contentSize: CGSize, viewport: CGSize) {
        guard zoom > 1.001 else { return }
        pan.width += delta.width
        pan.height += delta.height
        pan = clampedPan(contentSize: contentSize, viewport: viewport)
    }

    private func toggleZoom(focal: CGPoint, pageSize: CGSize, fit: CGFloat, viewport: CGSize) {
        if zoom > 1.05 {
            withAnimation(.easeOut(duration: 0.24)) { resetZoom() }
            return
        }

        let target: CGFloat = 2.2
        let contentW = pageSize.width * fit
        let contentH = pageSize.height * fit
        var newPan = CGSize(width: pan.width + contentW * (target - 1) * (0.5 - focal.x),
                            height: pan.height + contentH * (target - 1) * (0.5 - focal.y))
        let targetSize = CGSize(width: pageSize.width * fit * target,
                                height: pageSize.height * fit * target)
        let maxX = max(0, (targetSize.width - viewport.width) / 2)
        let maxY = max(0, (targetSize.height - viewport.height) / 2)
        newPan.width = min(max(newPan.width, -maxX), maxX)
        newPan.height = min(max(newPan.height, -maxY), maxY)

        withAnimation(.easeOut(duration: 0.24)) {
            zoom = target
            pan = newPan
        }
    }

    private func resetZoom() {
        zoom = 1
        pan = .zero
    }

    /// 内容比视口大时限制平移范围，避免页面被拖出屏幕
    private func clampedPan(contentSize: CGSize, viewport: CGSize) -> CGSize {
        clampedPan(pan, contentSize: contentSize, viewport: viewport)
    }

    private func clampedPan(_ value: CGSize, contentSize: CGSize, viewport: CGSize) -> CGSize {
        let maxX = max(0, (contentSize.width - viewport.width) / 2)
        let maxY = max(0, (contentSize.height - viewport.height) / 2)
        return CGSize(width: min(max(value.width, -maxX), maxX),
                      height: min(max(value.height, -maxY), maxY))
    }

    /// 放大书写时让页面跟着笔尖走：写到可见区域边缘就把纸往前推
    private func followPen(_ normalized: CGPoint, pageSize: CGSize, fit: CGFloat, viewport: CGSize) {
        guard zoom > 1.05, viewport.width > 1, viewport.height > 1 else { return }

        let scale = fit * zoom
        let visibleWidth = viewport.width / scale
        let visibleHeight = viewport.height / scale
        let pageCenter = CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)

        // 当前可见区域在页面坐标系中的范围
        let offsetX = -pan.width / scale
        let offsetY = -pan.height / scale
        let minX = pageCenter.x + offsetX - visibleWidth / 2
        let maxX = pageCenter.x + offsetX + visibleWidth / 2
        let minY = pageCenter.y + offsetY - visibleHeight / 2
        let maxY = pageCenter.y + offsetY + visibleHeight / 2

        let point = CGPoint(x: normalized.x * pageSize.width, y: normalized.y * pageSize.height)
        let margin = 110 / scale

        var updated = pan
        if point.y > maxY - margin { updated.height -= (point.y - (maxY - margin)) * scale }
        if point.y < minY + margin { updated.height += ((minY + margin) - point.y) * scale }
        if point.x > maxX - margin { updated.width -= (point.x - (maxX - margin)) * scale }
        if point.x < minX + margin { updated.width += ((minX + margin) - point.x) * scale }

        guard updated != pan else { return }
        pan = clampedPan(updated,
                         contentSize: CGSize(width: pageSize.width * scale, height: pageSize.height * scale),
                         viewport: viewport)
    }

    // MARK: - 全屏控件

    private func immersiveControls(_ note: Note) -> some View {
        ZStack(alignment: .leading) {
            immersiveToolCapsule
                .padding(.leading, 10)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.24)) { immersive = false }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                            .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("退出全屏")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button {
                        pageIndex = max(0, pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(pageIndex == 0)
                    .opacity(pageIndex == 0 ? 0.3 : 0.8)

                    Text("\(pageIndex + 1) / \(note.pages.count)")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 56)

                    Button {
                        pageIndex = min(note.pages.count - 1, pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(pageIndex >= note.pages.count - 1)
                    .opacity(pageIndex >= note.pages.count - 1 ? 0.3 : 0.8)

                    Divider().frame(height: 18)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { fitToWidth.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: fitToWidth ? "arrow.left.and.right" : "arrow.up.and.down")
                                .font(.system(size: 11, weight: .bold))
                            Text(fitToWidth ? "适应宽度" : "整页")
                                .font(.footnote.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 5)
                .padding(.bottom, 14)
            }
        }
    }

    /// 全屏时的窄工具条：不占版面，但能直接换笔
    private var immersiveToolCapsule: some View {
        VStack(spacing: 4) {
            ForEach([ToolKind.pen, ToolKind.pencil, ToolKind.highlighter, ToolKind.eraser, ToolKind.lasso], id: \.self) { kind in
                Button {
                    tools.activeTool = kind
                } label: {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(tools.activeTool == kind ? Theme.accent.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(tools.activeTool == kind ? Theme.accent : Color.primary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.title)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 5)
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

            IconButton(systemName: "arrow.up.left.and.arrow.down.right",
                       isActive: false,
                       label: "全屏阅读") {
                withAnimation(.easeInOut(duration: 0.24)) { immersive = true }
            }

            Menu {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("插入图片", systemImage: "photo.on.rectangle")
                }

                Button {
                    if let url = store.exportPageImage(noteID: noteID, pageIndex: pageIndex) {
                        sheet = .share(url)
                    }
                } label: {
                    Label("导出本页图片", systemImage: "photo.badge.arrow.down")
                }

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
        HStack(spacing: 12) {
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

    private func insertImage(_ data: Data) {
        guard let ui = UIImage(data: data) else {
            errorMessage = "这张图片无法读取"
            return
        }
        guard let note, note.pages.indices.contains(pageIndex) else { return }

        do {
            let fileName = try store.saveImage(data, noteID: noteID)
            let pageID = note.pages[pageIndex].id
            let maxWidth = min(note.pageSize.width * 0.62, 520)
            let ratio = ui.size.height / max(ui.size.width, 1)
            let width = maxWidth
            let height = min(maxWidth * ratio, note.pageSize.height * 0.82)

            let item = ImageItem(fileName: fileName,
                                 x: (note.pageSize.width - width) / 2,
                                 y: (note.pageSize.height - height) / 2,
                                 width: width,
                                 height: height)
            store.updatePage(noteID: noteID, pageID: pageID) { page in
                page.images.append(item)
            }
            // 切到套索，方便立刻拖动 / 缩放刚插入的图片
            tools.activeTool = .lasso
        } catch {
            errorMessage = "插入图片失败：\(error.localizedDescription)"
        }
    }

    private func exportPDF() {
        guard let url = store.exportPDF(noteID: noteID) else { return }
        sheet = .share(url)
    }
}
