import SwiftUI
import PencilKit
import PhotosUI
import UIKit

struct EditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    /// 系统撤销管理器：三指滑动 / 摇一摇 / 外接键盘 ⌘Z 都经由它触发
    @Environment(\.undoManager) private var undoManager
    /// iPhone（紧凑宽度）走另一套排版：顶栏精简、工具栏贴底、页面列表改成弹窗
    @Environment(\.horizontalSizeClass) private var sizeClass

    let noteID: UUID

    @StateObject private var tools = ToolStore()
    @StateObject private var controllers = CanvasControllerPool()
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
    /// 工具面板（颜色 / 粗细）是否展开。默认关闭：默认工具是「手拖」，没有颜色可调
    @State private var showPalette = false
    /// 左侧工具栏是否显示（浮层，可收起让页面整块可用）
    @AppStorage("editor.showToolRail") private var showRail = true
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    /// 手势操作后的短暂提示（两指撤销 / 三指重做）
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    /// 用户缩放倍率（1 = 适配整页）
    @State private var zoom: CGFloat = 1
    /// 缩放后的平移量（点）
    @State private var pan: CGSize = .zero
    /// 纯手拖：1× 时上下拖动累积的位移，用来翻页
    @State private var swipeAccum: CGFloat = 0
    /// 多页纵向连续滚动（衔接滚动）：所有页在一个纵向列表里无缝排布。
    /// 默认开启；关闭时回到单页视图（可缩放、上下拖动翻页）。
    @State private var continuous = true
    /// 程序跳页（点缩略图/底栏）时置位，避免滚动到位的 onAppear 再反过来触发 scrollTo 形成回环
    @State private var isProgrammaticScroll = false
    /// 连续滚动模式下 ScrollView 的实时滚动位置（最接近视口顶部锚点的页）。
    /// 用它来同步 pageIndex，替代之前靠 onAppear 同步——后者在页面刚滚入视口边缘就触发，
    /// 导致滚动到两页中间时被 scrollTo(.center) 强行拽走（瞬移）。
    @State private var continuousPage: Int? = nil
    /// 连续滚动 + 手形模式下，Pencil 单指拖动的累积位移（用于翻页）
    @State private var flowSwipeAccum: CGFloat = 0

    enum EditorSheet: Identifiable {
        case share(URL)
        case paper
        case pages

        var id: String {
            switch self {
            case .share(let url): return "share-\(url.absoluteString)"
            case .paper: return "paper"
            case .pages: return "pages"
            }
        }
    }

    private var note: Note? { store.note(id: noteID) }

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        ZStack {
            Theme.editorBackdrop.ignoresSafeArea()

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
                .padding(.top, compact ? 62 : 74)
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
            case .pages:
                if let note {
                    PageGridSheet(note: note, pageIndex: $pageIndex)
                }
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
                if continuous && note.pages.count > 1 {
                    continuousArea(note)
                } else {
                    pageArea(note)
                }
            }
            // 面板打开时，页面压一层轻遮罩：视觉上退到下一层，且不吃触摸（Pencil 照常书写）
            .overlay { paletteScrim }

            // 手机宽度放不下右侧那一竖条，改成底部工具栏里的「页面」按钮弹窗
            if showPagePanel && !immersive && !compact {
                PageStripView(note: note, pageIndex: $pageIndex)
                    .frame(width: 118)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // 工具栏和工具面板都浮在页面之上，不再挤占画布宽度（以前工具栏是 HStack 成员，一展开就少 70pt）
        .overlay(alignment: .leading) { railFloating }
        // 注意要挂在 padding 之前：挂在后面时 overlay 的范围是整块屏幕，面板顶部会被顶栏压住
        .overlay(alignment: compact ? .bottom : .leading) { paletteFloating }
        .padding(.top, immersive ? 0 : (compact ? 58 : 70))
        .padding(.bottom, immersive ? 0 : (compact ? 74 : 84))
        .animation(.easeInOut(duration: 0.24), value: immersive)
        .overlay {
            AudioSyncView(audio: audio,
                          noteID: noteID,
                          markers: note.markers,
                          pageIndex: $pageIndex)
        }
        .onAppear {
            pageIndex = min(pageIndex, max(note.pages.count - 1, 0))
            controllers.systemUndoManager = undoManager
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
        // 手机上工具栏在底部（CompactToolBar），左边这条不出现
        if !compact {
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
                .qianNoteGlassCapsule()
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
        if compact {
            // 手机上从底部工具栏上方弹出，横向铺开更好点
            if showPalette {
                GeometryReader { geo in
                    ViewThatFits(in: .vertical) {
                        paletteCard
                        ScrollView(.vertical, showsIndicators: false) {
                            paletteCard
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(width: 224, alignment: .leading)
                    .frame(maxHeight: geo.size.height, alignment: .bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .padding(.leading, 10)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        } else if showPalette && showRail {
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
    /// 面板打开时是模态的：点页面任意处（面板以外）就收起面板，比再回去点工具顺手。
    @ViewBuilder
    private var paletteScrim: some View {
        if !compact && showPalette && showRail {
            LinearGradient(colors: [Color.black.opacity(0.14),
                                    Color.black.opacity(0.04),
                                    .clear],
                           startPoint: .leading,
                           endPoint: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { closePalette() }
                .transition(.opacity)
        } else if compact && showPalette {
            // 手机上面板从底部弹出，这里盖一层轻遮罩，点页面收起
            Color.black.opacity(0.16)
                .contentShape(Rectangle())
                .onTapGesture { closePalette() }
                .transition(.opacity)
        }
    }

    private func closePalette() {
        withAnimation(.easeInOut(duration: 0.2)) { showPalette = false }
    }

    private func pageArea(_ note: Note) -> some View {
        GeometryReader { geo in
            let pageWidth = CGFloat(max(note.pageWidth, 1))
            let pageHeight = CGFloat(max(note.pageHeight, 1))
            let inset: CGFloat = immersive ? 0 : (compact ? 8 : 24)
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
                         onUndoTap: { gestureUndo(currentPageID(note)) },
                         onRedoTap: { gestureRedo(currentPageID(note)) },
                         onFingerPan: { delta in
                             handleFingerPan(delta.scaled(by: fit * zoom),
                                             contentSize: CGSize(width: contentWidth, height: contentHeight),
                                             viewport: geo.size,
                                             pageCount: note.pages.count)
                         },
                         onFingerPanEnd: { swipeAccum = .zero })
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

    // MARK: - 连续滚动（衔接滚动）

    /// 多页纵向连续滚动：所有页在一个纵向 ScrollView 里无缝排布。
    /// 手指上下滑动连续翻页（看 PDF 的体验），Pencil 照常在各页画布上书写。
    /// 每页一个独立的撤销栈（CanvasControllerPool 已按页隔离）。
    private func continuousArea(_ note: Note) -> some View {
        GeometryReader { geo in
            let inset: CGFloat = immersive ? 0 : (compact ? 8 : 24)
            let width = max(geo.size.width - inset * 2, 1)
            let pageWidth = CGFloat(max(note.pageWidth, 1))
            let pageHeight = CGFloat(max(note.pageHeight, 1))
            // 基础适配：让页面宽度填满可用宽度（不含用户缩放 zoom）。
            let fit = width / max(pageWidth, 1)
            let renderedHeight = pageHeight * fit

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: immersive ? 8 : 18) {
                        ForEach(Array(note.pages.enumerated()), id: \.element.id) { index, page in
                            flowPage(note, page: page, index: index,
                                     fit: fit, width: width, renderedHeight: renderedHeight,
                                     inset: inset, proxy: proxy, geo: geo)
                                .id(index)
                                .onAppear {
                                    // 只负责把该页的撤销栈激活，页码同步交给 scrollPosition。
                                    // 之前这里写 pageIndex = index，在 LazyVStack 惰性加载时
                                    // 页面刚进入视口边缘就触发，配合下面的 scrollTo 造成瞬移。
                                    controllers.activate(page.id)
                                }
                        }
                    }
                    // 沉浸全屏下 workspace 顶部 padding 归零，页面会滚到状态栏下面；
                    // 这里把顶部安全区补回来，让第一页顶部始终停在状态栏之下。
                    .padding(.top, immersive ? geo.safeAreaInsets.top : 16)
                    .padding(.bottom, immersive ? max(geo.safeAreaInsets.bottom, 16) : 16)
                }
                .offset(x: pan.width)
                .scrollPosition(id: $continuousPage)
                .onAppear {
                    // 首次进入定位：从缩略图/历史恢复到非第一页时，scrollPosition 初始为 nil，
                    // 需要主动滚一次。等布局稳定后跳过去（无动画，避免进入时看到一段滚动）。
                    guard continuousPage == nil, pageIndex > 0 else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(pageIndex, anchor: .top)
                    }
                }
                .onChange(of: continuousPage) { _, newValue in
                    // 用户手指滚动到位后，把「最接近视口顶部的页」同步成当前页码。
                    // 程序 scrollTo 动画期间（isProgrammaticScroll）不响应，避免反向覆盖。
                    guard !isProgrammaticScroll else { return }
                    if let newValue, newValue != pageIndex {
                        pageIndex = newValue
                    }
                }
                .onChange(of: pageIndex) { _, newValue in
                    // 点右侧缩略图 / 底栏翻页按钮时，滚动到对应页。
                    // 若目标页已是当前滚动位置（滚动同步刚把 pageIndex 改成它），则跳过，
                    // 否则会形成「滚动→同步→scrollTo」的回环瞬移。
                    guard !isProgrammaticScroll else { return }
                    if continuousPage == newValue { return }
                    isProgrammaticScroll = true
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                    // 滚动动画结束后放开，让后续滚动重新驱动页码同步
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isProgrammaticScroll = false
                    }
                }
            }
        }
    }

    /// 连续滚动模式下的一页：一个普通列表 item。
    /// 页面（PDF 底稿 + 墨迹）在 NotePageView 内部完整渲染，这里只做「适配宽度 + 用户缩放」。
    /// 无任何覆盖层 / 额外背景 / 阴影——页与页直接拼接。
    @ViewBuilder
    private func flowPage(_ note: Note, page: NotePage, index: Int,
                          fit: CGFloat, width: CGFloat, renderedHeight: CGFloat,
                          inset: CGFloat, proxy: ScrollViewProxy, geo: GeometryProxy) -> some View {
        let pageWidth = CGFloat(max(note.pageWidth, 1))
        let pageHeight = CGFloat(max(note.pageHeight, 1))
        NotePageView(note: note,
                     pageIndex: index,
                     tools: tools,
                     controller: controllers.controller(for: page.id),
                     pdfScale: pdfRenderScale(for: note.pageSize),
                     onPinch: { delta, focal in
                         applyFlowPinch(delta, focal: focal, viewport: geo.size)
                     },
                     onPan: { delta in
                         applyFlowPan(delta, contentWidth: width * zoom, viewport: geo.size)
                     },
                     onDoubleTap: { focal in
                         toggleFlowZoom(focal: focal, viewport: geo.size)
                     },
                     onPencilDoubleTap: {
                         tools.togglePencilEraser()
                     },
                     shapeRecognition: tools.shapeRecognition,
                     onPenMove: { _ in },
                     onStrokeCommitted: nil,
                     onUndoTap: { gestureUndo(page.id) },
                     onRedoTap: { gestureRedo(page.id) },
                     onFingerPan: { delta in
                         flowPanToScroll(delta, proxy: proxy, pageCount: note.pages.count)
                     },
                     onFingerPanEnd: { flowSwipeAccum = 0 },
                     fingerPans: false)
            // 适配宽度 + 用户缩放。frame 用缩放后的真实尺寸，让 ScrollView 滚动范围天然匹配。
            .scaleEffect(fit * zoom, anchor: .top)
            .frame(width: width * zoom, height: renderedHeight * zoom)
            .clipped()
    }

    // MARK: 连续滚动整体缩放（zoom 作用在整个页面流，而非单页）
    //
    // 结构：ScrollView（列表）→ .scaleEffect(zoom, anchor: .top) → .offset(pan)。
    // zoom 线性作用在容器宽高上（面积自然 × zoom²），offset 是缩放后的屏幕坐标。
    // 每页只是列表里的一个普通 item，页面内容（PDF + 墨迹）在 NotePageView 内部渲染，无覆盖层。

    /// 双指捏合：围绕捏合中心缩放整个页面流。
    private func applyFlowPinch(_ delta: CGFloat, focal: CGPoint, viewport: CGSize) {
        let old = zoom
        let new = min(max(old * delta, 1), 6)
        guard abs(new - old) > 0.0005 else { return }

        // 围绕捏合中心缩放：保持焦点在屏幕上不动（屏幕坐标）。
        let contentW = viewport.width * old
        let k = new / old
        pan.width += contentW * (k - 1) * (0.5 - focal.x)

        zoom = new
        if new <= 1.001 {
            pan = .zero
        }
        pan = clampedFlowPan(viewport: viewport)
    }

    /// 双指拖动：放大后水平平移页面流（纵向由 ScrollView 原生滚动负责）。
    /// delta 是屏幕像素，直接累加即可。
    private func applyFlowPan(_ delta: CGSize, contentWidth: CGFloat, viewport: CGSize) {
        guard zoom > 1.001 else { return }
        pan.width += delta.width
        pan = clampedFlowPan(viewport: viewport)
    }

    private func toggleFlowZoom(focal: CGPoint, viewport: CGSize) {
        if zoom > 1.05 {
            withAnimation(.easeOut(duration: 0.24)) { resetZoom() }
            return
        }
        let target: CGFloat = 2.2
        let contentW = viewport.width
        var newPanX = pan.width + contentW * (target - 1) * (0.5 - focal.x)
        withAnimation(.easeOut(duration: 0.24)) {
            zoom = target
            pan = CGSize(width: newPanX, height: 0)
        }
        pan = clampedFlowPan(viewport: viewport)
    }

    /// 限制水平平移范围，避免放大后的页面流被拖出左右边缘（纵向交给 ScrollView）。
    private func clampedFlowPan(viewport: CGSize) -> CGSize {
        let maxX = max(0, (viewport.width * zoom - viewport.width) / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: 0)
    }

    /// 手形模式下 Pencil 单指拖动整个页面流：累积位移翻页。
    /// iOS 17 的 ScrollViewProxy 没有增量滚动 API，只能按 id 跳页，这里累积位移触发翻页。
    private func flowPanToScroll(_ delta: CGSize, proxy: ScrollViewProxy, pageCount: Int) {
        flowSwipeAccum += delta.height
        guard abs(flowSwipeAccum) > 96 else { return }
        let dir = flowSwipeAccum < 0 ? 1 : -1
        flowSwipeAccum = 0
        let target = pageIndex + dir
        guard target >= 0, target < pageCount else { return }
        isProgrammaticScroll = true
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            isProgrammaticScroll = false
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
                .qianNoteGlassCapsule()
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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            // 退出按钮必须用明确的背景材质：iOS 26 的 interactive glass
                            // 叠在全屏 ScrollView 上时 hit-test 可能失效，导致「收不回去」。
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
                .qianNoteGlassCapsule()
                .padding(.bottom, 14)
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: compact ? 6 : 10) {
            Button {
                dismiss()
            } label: {
                // 手机上不写「笔记」两个字，省下来的宽度留给标题
                if compact {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                        .foregroundStyle(Theme.accent)
                } else {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回笔记列表")

            Button {
                renameText = note?.title ?? ""
                showRename = true
            } label: {
                HStack(spacing: 5) {
                    Text(note?.title ?? "")
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, compact ? 4 : 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: compact ? 2 : 8)

            HStack(spacing: 2) {
                IconButton(systemName: "arrow.uturn.backward",
                           isActive: false,
                           size: compact ? 32 : 36,
                           label: "撤销") { undoCurrentPage() }
                    .opacity(controllers.canUndo ? 1 : 0.35)
                    .disabled(!controllers.canUndo)

                IconButton(systemName: "arrow.uturn.forward",
                           isActive: false,
                           size: compact ? 32 : 36,
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

            if !compact {
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
                    let pageID = note?.pages[safe: pageIndex]?.id ?? UUID()
                    if let note {
                        // clearCanvas 会通过回调把画布真正清空并落盘；
                        // store.clearPage 兜底确保 drawingCache 与磁盘也是空图。
                        controllers.controller(for: currentPageID(note)).clearCanvas()
                    }
                    store.clearPage(noteID: noteID, pageID: pageID)
                } label: {
                    Label("清空当前页", systemImage: "eraser.line.dashed")
                }
                if compact {
                    Button {
                        sheet = .pages
                    } label: {
                        Label("页面列表", systemImage: "rectangle.on.rectangle")
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.24)) { immersive = true }
                    } label: {
                        Label("全屏阅读", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Divider()
                if note?.pages.count ?? 0 > 1 {
                    Toggle(isOn: $continuous) {
                        Label("连续滚动", systemImage: "rectangle.stack")
                    }
                }
                Toggle(isOn: $tools.handMode) {
                    Label("拖动模式（笔也不写字）", systemImage: "hand.point.up.left")
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
                    .frame(width: compact ? 32 : 36, height: compact ? 32 : 36)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 6 : 8)
        .qianNoteGlassPanel(cornerRadius: 18, interactive: true)
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.top, compact ? 6 : 8)
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        Group {
            // 手机上底栏就是工具栏：手形 / 一排笔 / 页码
            if compact, let note {
                CompactToolBar(tools: tools,
                               showPalette: $showPalette,
                               pageIndex: pageIndex,
                               pageCount: note.pages.count) {
                    sheet = .pages
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            } else if let note {
                pageIndicator(note)
                    .padding(.bottom, 10)
            }
        }
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
        .qianNoteGlassCapsule()
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

                    Toggle(isOn: $tools.handMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("拖动模式").font(.subheadline)
                            Text("开启后手指和 Apple Pencil 都只拖动页面（放大时平移，1× 时上下拖动翻页），不写字；手指平时就一直是拖动，点任意笔立刻回到书写")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("手势")
                            .font(.subheadline.weight(.semibold))
                        Text("不拿笔也能操作")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        gestureRow("两指点击", "撤销")
                        gestureRow("三指点击", "重做")
                        gestureRow("单指拖动", "平移 / 翻页（手指始终如此，拖动模式下 Pencil 同样适用）")
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

    // MARK: - 插入图片

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

    // MARK: - 导出

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
        .qianNoteGlassCapsule()
        .allowsHitTesting(false)
    }
}
