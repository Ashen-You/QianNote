import SwiftUI
import PencilKit
import PhotosUI
import UIKit

struct EditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    let noteID: UUID

    @StateObject private var tools = ToolStore()
    @StateObject private var controllers = CanvasControllerPool()
    @State private var audio = AudioController()
    /// 回放时用独立的计时器驱动画面，避免录音期间每秒重绘整个编辑器
    @State private var replayTime: TimeInterval = 0
    @State private var replayTimer: Timer?

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
    /// 工具面板（颜色 / 粗细）是否展开。默认关闭：默认工具是「手拖」，没有颜色可调
    @State private var showPalette = false
    /// 左侧工具栏是否显示（浮层，可收起让页面整块可用）
    @AppStorage("editor.showToolRail") private var showRail = true
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    /// 拍照插入
    @State private var showCamera = false
    /// 书写回放（录音 + 逐笔复现）
    @State private var replay = false
    /// 多页连续滚动（Notability 的阅读模式）
    @State private var continuous = false
    /// 手势操作后的短暂提示（两指撤销 / 三指重做）
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    /// 用户缩放倍率（1 = 适配整页）
    @State private var zoom: CGFloat = 1
    /// 缩放后的平移量（点）
    @State private var pan: CGSize = .zero
    /// 纯手拖：1× 时上下拖动累积的位移，用来翻页
    @State private var swipeAccum: CGFloat = 0

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
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                insertImage(image)
            }
            .ignoresSafeArea()
        }
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
            VStack(spacing: 8) {
                if let toast {
                    toastBadge(toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if replay {
                    replayBadge
                }
                if let errorMessage {
                    ErrorBanner(message: errorMessage) { self.errorMessage = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 96)
        }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .animation(.easeInOut(duration: 0.18), value: toast)
        .onDisappear {
            stopReplayTimer()
            replay = false
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
            Group {
                if continuous {
                    continuousArea(note)
                } else {
                    pageArea(note)
                }
            }
            // 面板打开时，页面压一层轻遮罩：视觉上退到下一层，且不吃触摸（Pencil 照常书写）
            .overlay { paletteScrim }

            if showPagePanel && !immersive {
                PageStripView(note: note, pageIndex: $pageIndex)
                    .frame(width: 118)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // 工具栏和工具面板都浮在页面之上，不再挤占画布宽度（以前工具栏是 HStack 成员，一展开就少 70pt）
        .overlay(alignment: .leading) { railFloating }
        // 注意要挂在 padding 之前：挂在后面时 overlay 的范围是整块屏幕，面板顶部会被顶栏压住
        .overlay(alignment: .leading) { paletteFloating }
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
            if let page = note.pages[safe: pageIndex] {
                controllers.activate(page.id)
            }
        }
        .onChange(of: pageIndex) { _, newValue in
            if let page = note.pages[safe: newValue] {
                controllers.activate(page.id)
            }
        }
        .onChange(of: note.pages.count) { _, newCount in
            if pageIndex >= newCount {
                pageIndex = max(0, newCount - 1)
            }
        }
    }

    // MARK: - 工具栏浮层

    /// 工具栏宽 58 + 左边距 12；面板贴在它右侧再留 8
    private let railWidth: CGFloat = 58
    private let railInset: CGFloat = 12

    /// 整页（全屏）模式下也用同一套工具栏和面板。
    /// 之前全屏有一份单独的窄胶囊（只有七支笔、没有手、没有颜色面板），
    /// 进出全屏时工具的排列和可用项都对不上，看起来像两套东西。
    @ViewBuilder
    private var railFloating: some View {
        if showRail {
            railCard
                .padding(.leading, immersive ? 8 : railInset)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(3)
        } else {
            railRevealTab
                .padding(.leading, 4)
                .transition(.opacity)
                .zIndex(3)
        }
    }

    /// 工具栏卡片：竖着放不下（横屏 / 小屏）时退化成可滚动，不再被容器直接切掉
    private var railCard: some View {
        GeometryReader { geo in
            ViewThatFits(in: .vertical) {
                railContent
                ScrollView(.vertical, showsIndicators: false) {
                    railContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: railWidth, height: geo.size.height, alignment: .center)
        }
        .frame(width: railWidth)
    }

    private var railContent: some View {
        ToolRailView(tools: tools, showPalette: $showPalette) {
            withAnimation(.easeInOut(duration: 0.22)) { hideRail() }
        }
    }

    /// 收起之后留在屏幕左边缘的小把手，点一下把工具栏叫回来
    private var railRevealTab: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { showRail = true }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.5))
                .frame(width: 20, height: 54)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("显示工具栏")
    }

    private func hideRail() {
        showPalette = false
        showRail = false
    }

    // MARK: - 工具面板浮层

    /// 面板卡片：外面留 12pt 给阴影，卡片左边缘正好贴着工具栏右侧（12 + 58 + 8）
    private var paletteCard: some View {
        ToolPaletteView(tools: tools)
            .padding(12)
    }

    /// 盖在页面上的浮层。用 ViewThatFits：放得下就按内容高度显示，
    /// 放不下（小屏 / 横屏）才退化成可滚动的面板，不再像以前那样被容器直接切掉。
    @ViewBuilder
    private var paletteFloating: some View {
        if showPalette && showRail {
            GeometryReader { geo in
                ViewThatFits(in: .vertical) {
                    paletteCard
                    ScrollView(.vertical, showsIndicators: false) {
                        paletteCard
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: 224, alignment: .leading)
                // 与竖向居中的工具栏并排时垂直居中对齐，看起来像从工具栏上「长」出来的一页
                .frame(maxHeight: geo.size.height, alignment: .center)
            }
            .padding(.leading, (immersive ? 8 : railInset) + railWidth + 4)
            .transition(.move(edge: .leading).combined(with: .opacity))
            .zIndex(2)
        }
    }

    /// 面板下面的遮盖层：左边深、向右淡出，做出「面板在上面、页面在下面」的层次。
    /// 只负责视觉，不吃触摸，免得打开面板就没法写字。
    @ViewBuilder
    private var paletteScrim: some View {
        if showPalette && showRail {
            LinearGradient(colors: [Color.black.opacity(0.14),
                                    Color.black.opacity(0.04),
                                    .clear],
                           startPoint: .leading,
                           endPoint: .trailing)
                .allowsHitTesting(false)
                .transition(.opacity)
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
                         controller: controllers.controller(for: currentPageID(note)),
                         pdfScale: pdfRenderScale(for: note.pageSize),
                         onPinch: { delta, focal in
                             applyPinch(delta, focal: focal,
                                        pageSize: note.pageSize, fit: fit, viewport: geo.size)
                         },
                         onPan: { delta in
                             applyPan(delta.scaled(by: fit * zoom),
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
                         },
                         onStrokeCommitted: { count in
                             recordInkStamp(pageID: currentPageID(note), count: count)
                         },
                         onUndoTap: { gestureUndo(currentPageID(note)) },
                         onRedoTap: { gestureRedo(currentPageID(note)) },
                         onFingerPan: { delta in
                             handleFingerPan(delta.scaled(by: fit * zoom),
                                             contentSize: CGSize(width: contentWidth, height: contentHeight),
                                             viewport: geo.size,
                                             pageCount: note.pages.count)
                         },
                         onFingerPanEnd: { swipeAccum = .zero },
                         replayStrokes: replayStrokeCount(for: currentPageID(note)))
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

    private func currentPageID(_ note: Note) -> UUID {
        if let page = note.pages[safe: pageIndex] { return page.id }
        return note.pages.first?.id ?? note.id
    }

    /// 多页纵向连续滚动：每页独立撤销栈，适合阅读长 PDF
    private func continuousArea(_ note: Note) -> some View {
        GeometryReader { geo in
            let inset: CGFloat = immersive ? 6 : 20
            let width = max(geo.size.width - inset * 2, 1)
            let scale = width / max(note.pageSize.width, 1)
            let pageHeight = max(note.pageSize.height * scale, 1)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: immersive ? 10 : 22) {
                    ForEach(Array(note.pages.enumerated()), id: \.element.id) { index, page in
                        NotePageView(note: note,
                                     pageIndex: index,
                                     tools: tools,
                                     controller: controllers.controller(for: page.id),
                                     pdfScale: 2.5,
                                     shapeRecognition: tools.shapeRecognition,
                                     onStrokeCommitted: { count in
                                         recordInkStamp(pageID: page.id, count: count)
                                     },
                                     onUndoTap: { gestureUndo(page.id) },
                                     onRedoTap: { gestureRedo(page.id) },
                                     replayStrokes: replayStrokeCount(for: page.id))
                            .frame(width: note.pageSize.width, height: note.pageSize.height)
                            .scaleEffect(scale)
                            .frame(width: width, height: pageHeight)
                            .background(Color.white)
                            .shadow(color: Color.black.opacity(immersive ? 0 : 0.14),
                                    radius: immersive ? 0 : 14, x: 0, y: 4)
                            .padding(.horizontal, inset)
                            .onTapGesture {
                                pageIndex = index
                                controllers.activate(page.id)
                            }
                    }
                }
                .padding(.vertical, 20)
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

    /// 手指=拖动：放大时平移页面，1× 时上下拖动翻页
    private func handleFingerPan(_ delta: CGSize, contentSize: CGSize,
                                 viewport: CGSize, pageCount: Int) {
        if zoom > 1.001 {
            applyPan(delta, contentSize: contentSize, viewport: viewport)
            return
        }

        swipeAccum += delta.height
        guard abs(swipeAccum) > 84, pageCount > 1 else { return }

        let target = swipeAccum < 0 ? pageIndex + 1 : pageIndex - 1
        swipeAccum = 0
        guard target >= 0, target < pageCount else { return }

        withAnimation(.easeInOut(duration: 0.18)) { pageIndex = target }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                           label: "撤销") { undoCurrentPage() }
                    .opacity(controllers.canUndo ? 1 : 0.35)
                    .disabled(!controllers.canUndo)

                IconButton(systemName: "arrow.uturn.forward",
                           isActive: false,
                           label: "重做") { redoCurrentPage() }
                    .opacity(controllers.canRedo ? 1 : 0.35)
                    .disabled(!controllers.canRedo)
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

            IconButton(systemName: continuous ? "rectangle.portrait" : "square.stack",
                       isActive: continuous,
                       label: "连续滚动") {
                withAnimation(.easeInOut(duration: 0.2)) { continuous.toggle() }
            }

            // 工具栏显隐。手拖按钮已经挪进工具栏第一位，这里只留一个开关
            IconButton(systemName: showRail ? "sidebar.left" : "sidebar.leading",
                       isActive: showRail,
                       label: showRail ? "隐藏工具栏" : "显示工具栏") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if showRail { hideRail() } else { showRail = true }
                }
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
                    showCamera = true
                } label: {
                    Label("拍照插入", systemImage: "camera")
                }

                Button {
                    startReplay()
                } label: {
                    Label("书写回放", systemImage: "pencil.and.scribble")
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
                    if let note {
                        controllers.controller(for: currentPageID(note)).resetHistory()
                    }
                    store.clearPage(noteID: noteID, pageID: note?.pages[safe: pageIndex]?.id ?? UUID())
                } label: {
                    Label("清空当前页", systemImage: "eraser.line.dashed")
                }
                Divider()
                Toggle(isOn: Binding(get: { !tools.fingerDrawing },
                                     set: { tools.fingerDrawing = !$0 })) {
                    Label("拖动模式（不写字）", systemImage: "hand.point.up.left")
                }
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
                            Text("关闭后进入拖动模式：手指和 Apple Pencil 都只拖动页面（放大时平移，1× 时上下拖动翻页），不写字；点任意笔立刻回到书写")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("手势")
                            .font(.subheadline.weight(.semibold))
                        Text("不拿笔也能操作，指写模式下同样有效")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        gestureRow("两指点击", "撤销")
                        gestureRow("三指点击", "重做")
                        gestureRow("单指拖动（拖动模式）", "平移 / 翻页，Pencil 同样适用")
                        gestureRow("双指捏合 / 拖动", "缩放 / 平移")
                        gestureRow("双击（指写模式除外）", "整页 ↔ 2.2×")
                    }
                    .padding(.top, 10)
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

    /// 设置页里的一行手势说明
    private func gestureRow(_ gesture: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(gesture)
                .font(.footnote)
                .foregroundStyle(Color.primary.opacity(0.8))
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(action)
                .font(.footnote.weight(.medium))
            Spacer(minLength: 0)
        }
    }

    private func applyPaper(template: PaperTemplate, tint: PaperTint) {
        store.setPaper(noteID: noteID, template: template, tint: tint)
        for page in note?.pages ?? [] {
            store.invalidateThumbnail(noteID: noteID, pageID: page.id)
        }
    }

    // MARK: - 导出

    private func insertImage(_ data: Data) {
        guard let ui = UIImage(data: data) else {
            errorMessage = "这张图片无法读取"
            return
        }
        insertImage(ui)
    }

    private func insertImage(_ ui: UIImage) {
        guard let note, note.pages.indices.contains(pageIndex) else { return }
        guard let data = ui.jpegData(compressionQuality: 0.92) ?? ui.pngData() else {
            errorMessage = "这张图片无法编码"
            return
        }

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
            // 切到套索，方便立刻拖动 / 缩放 / 裁剪刚插入的图片
            tools.activeTool = .lasso
        } catch {
            errorMessage = "插入图片失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 录音时间轴与书写回放

    /// 录音期间每落一笔，记下当时的时刻，回放时按时间点逐笔复现
    private func recordInkStamp(pageID: UUID, count: Int) {
        guard audio.mode == .recording, !audio.isPaused else { return }
        store.addInkStamp(noteID: noteID, pageID: pageID, time: audio.liveTime, strokeCount: count)
    }

    private func replayStrokeCount(for pageID: UUID) -> Int? {
        guard replay else { return nil }
        return store.replayStrokeCount(noteID: noteID, pageID: pageID, time: replayTime)
    }

    private func startReplay() {
        guard let note else { return }
        guard note.hasRecording else {
            errorMessage = "这本笔记还没有录音。先点麦克风录一段，写下的每一笔都会被记进时间轴。"
            return
        }
        guard store.hasInkTimeline(noteID: noteID) else {
            errorMessage = "录音里还没有记录笔迹。下次录音时写点东西，回放就能一笔笔重现。"
            return
        }

        do {
            if audio.mode != .idle { audio.stop() }
            try audio.play(url: store.audioURL(noteID: noteID))
            replayTime = 0
            replay = true
            startReplayTimer()
            if let first = note.markers.first, note.pages.indices.contains(first.pageIndex) {
                pageIndex = first.pageIndex
            }
        } catch {
            replay = false
            errorMessage = "回放失败：\(error.localizedDescription)"
        }
    }

    private func stopReplay() {
        replay = false
        stopReplayTimer()
        if audio.mode == .playing { audio.stop() }
    }

    private func startReplayTimer() {
        stopReplayTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                self.replayTime = self.audio.time
                if self.audio.mode != .playing {
                    self.stopReplayTimer()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        replayTimer = timer
    }

    private func stopReplayTimer() {
        replayTimer?.invalidate()
        replayTimer = nil
    }

    private var replayBadge: some View {
        HStack(spacing: 10) {
            Image(systemName: audio.mode == .playing ? "waveform" : "pause.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)

            Text("书写回放")
                .font(.footnote.weight(.semibold))

            Text("\(replayTime.clockText) / \(audio.duration.clockText)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                stopReplay()
            } label: {
                Text("退出")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    private func exportPDF() {
        guard let url = store.exportPDF(noteID: noteID) else { return }
        sheet = .share(url)
    }

    // MARK: - 手势撤销 / 重做

    private func undoCurrentPage() {
        if let note {
            controllers.undo(pageID: currentPageID(note))
        } else {
            controllers.undo()
        }
    }

    private func redoCurrentPage() {
        if let note {
            controllers.redo(pageID: currentPageID(note))
        } else {
            controllers.redo()
        }
    }

    /// 两指点击 → 撤销
    private func gestureUndo(_ pageID: UUID) {
        if controllers.undo(pageID: pageID) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            showToast("已撤销")
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast("没有可撤销的操作")
        }
    }

    /// 三指点击 → 重做
    private func gestureRedo(_ pageID: UUID) {
        if controllers.redo(pageID: pageID) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            showToast("已重做")
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast("没有可重做的操作")
        }
    }

    /// 手指：书写 ↔ 拖动。放在顶栏单独一个按钮，不用展开颜色面板去翻
    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) { toast = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }

    private func toastBadge(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: text.hasPrefix("没有") ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(text.hasPrefix("没有") ? Color.orange : Theme.accent)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 4)
        .allowsHitTesting(false)
    }
}
