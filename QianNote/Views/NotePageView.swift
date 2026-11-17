import SwiftUI
import PencilKit
import UIKit

/// 单页：纸张 / PDF 底稿 + 手写层 + 文字层
struct NotePageView: View {
    @EnvironmentObject private var store: NoteStore

    let note: Note
    let pageIndex: Int
    @ObservedObject var tools: ToolStore
    let controller: CanvasController

    /// PDF 底图渲染倍率（随缩放档位提高，保证放大后依然清晰）
    var pdfScale: CGFloat = 3
    var onPinch: ((CGFloat, CGPoint) -> Void)? = nil
    var onPan: ((CGSize) -> Void)? = nil
    var onDoubleTap: ((CGPoint) -> Void)? = nil
    var onPencilDoubleTap: (() -> Void)? = nil
    var shapeRecognition: Bool = false
    var onPenMove: ((CGPoint) -> Void)? = nil
    /// 两指点击撤销 / 三指点击重做
    var onUndoTap: (() -> Void)? = nil
    var onRedoTap: (() -> Void)? = nil
    /// 单指拖动页面（手指=拖动模式）
    var onFingerPan: ((CGSize) -> Void)? = nil
    var onFingerPanEnd: (() -> Void)? = nil
    /// 手指单指是否用手势拖动页面。连续滚动模式下手指交给 ScrollView 原生滚动，
    /// 这里应传 false；单页模式（放大平移 / 翻页）保持 true。
    var fingerPans: Bool = true

    @State private var selectedTextID: UUID?
    /// 正在就地编辑的文字框（不再弹窗，退格 / 全选 / 输入法都走系统原生行为）
    @State private var editingTextID: UUID?
    @State private var draftText: String = ""
    @State private var draftFontSize: CGFloat = 22
    @FocusState private var focusedTextID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var draggingID: UUID?

    // 套索选区
    @State private var lassoPoints: [CGPoint] = []
    @State private var lassoSelection: InkSelectionResult?
    @State private var selectionDrag: CGSize = .zero
    @State private var croppingItem: ImageItem?

    // 图片对象
    @State private var selectedImageID: UUID?
    @State private var imageTranslation: CGSize = .zero
    @State private var resizingTranslation: CGSize = .zero
    @State private var draggingImageID: UUID?
    @State private var resizingImageID: UUID?

    private static let fallbackPageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private var pageID: UUID {
        note.pages[safe: pageIndex]?.id ?? Self.fallbackPageID
    }

    private var page: NotePage? {
        note.pages[safe: pageIndex]
    }

    private var pageSize: CGSize { note.pageSize }

    /// 拖动模式（纯导航）：手形按钮激活后，手指和 Pencil 都只拖页面，任何工具都写不进去
    private var isNavigating: Bool {
        tools.handMode && onFingerPan != nil
    }

    /// 手指是否单指拖动：iPad 上手指永远拖动（不写字），但连续滚动下交给 ScrollView，
    /// 由调用方的 fingerPans 参数决定是否用手势拖动。
    private var fingerCanPan: Bool {
        fingerPans && !tools.fingerCanDraw && onFingerPan != nil
    }

    /// 笔是否单指拖动：手形模式下 Pencil 只拖不写
    private var pencilCanPan: Bool {
        tools.handMode && onFingerPan != nil
    }

    private var canvasInteractive: Bool {
        // 拖动模式下画布必须能收触摸：套索 / 文字 / 激光笔会把画布整个关掉，
        // 拖动手势挂在画布上，画布不响应就变成「既写不了也拖不动」
        if isNavigating { return true }
        switch tools.activeTool {
        case .text, .lasso, .laser:
            return false
        default:
            return true
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            imageVisualLayer
                .sheet(item: $croppingItem) { item in
                    if let ui = store.image(noteID: note.id, fileName: item.fileName) {
                        ImageCropperView(image: ui) { cropped, cropRect in
                            applyCrop(item: item, cropped: cropped, cropRect: cropRect)
                        }
                    }
                }

            DrawingCanvas(pageID: pageID,
                          initialDrawing: store.drawing(noteID: note.id, pageID: pageID),
                          tool: tools.pkTool,
                          toolKey: tools.toolKey,
                          fingerDrawing: tools.fingerCanDraw,
                          isEnabled: canvasInteractive,
                          controller: controller,
                          onChange: { drawing in
                              store.saveDrawing(drawing, noteID: note.id, pageID: pageID)
                          },
                          onPinch: onPinch,
                          onPan: onPan,
                          onDoubleTap: onDoubleTap,
                          onPencilDoubleTap: onPencilDoubleTap,
                          shapeRecognition: shapeRecognition,
                          isShapeEligible: tools.activeTool.supportsShapeSnap && !tools.activeTool.isDashed,
                          onPenMove: onPenMove,
                          isDashed: tools.activeTool.isDashed,
                          dashWidth: tools.width(for: .dashed),
                          onUndoTap: onUndoTap,
                          onRedoTap: onRedoTap,
                          fingerPans: fingerCanPan,
                          pencilPans: pencilCanPan,
                          onFingerPan: onFingerPan,
                          onFingerPanEnd: onFingerPanEnd)
                .frame(width: pageSize.width, height: pageSize.height)

            // 拖动模式下套索 / 激光 / 文字都退场，页面只负责被拖
            if tools.activeTool == .lasso, !isNavigating {
                lassoLayer
            }

            imageHandleLayer

            if tools.activeTool == .laser, !isNavigating {
                LaserOverlay(color: tools.color(for: .laser),
                             width: tools.width(for: .laser))
                    .frame(width: pageSize.width, height: pageSize.height)
            }

            if tools.activeTool == .text, !isNavigating {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: pageSize.width, height: pageSize.height)
                    .onTapGesture(coordinateSpace: .local) { location in
                        // 正在编辑时点空白处只管收笔，避免一个误触又多出一个空框
                        if editingTextID != nil {
                            commitActiveText()
                        } else {
                            addTextBox(at: location)
                        }
                    }
            }

            textLayer
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        .onChange(of: tools.activeTool) { _, newValue in
            if newValue != .text { commitActiveText() }
            lassoPoints = []
            lassoSelection = nil
        }
        .onChange(of: pageIndex) { _, _ in
            commitActiveText()
            selectedTextID = nil
        }
        .toolbar {
            // 键盘上方的一条：字号增减、删除、完成。删除只放在这儿不行（键盘收起就看不到），
            // 所以选中的文字框右上角还有一颗 ×，两处都能删。
            ToolbarItemGroup(placement: .keyboard) {
                if editingTextID != nil {
                    Button {
                        draftFontSize = max(12, draftFontSize - 2)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .accessibilityLabel("减小字号")

                    Button {
                        draftFontSize = min(72, draftFontSize + 2)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityLabel("增大字号")

                    Text("\(Int(draftFontSize))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let id = editingTextID,
                       let box = store.note(id: note.id)?.pages[safe: pageIndex]?.textBoxes
                        .first(where: { $0.id == id }) {
                        Button(role: .destructive) {
                            removeTextBox(box)
                        } label: {
                            Text("删除")
                        }
                    }

                    Button("完成") { commitActiveText() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: 背景

    @ViewBuilder
    private var background: some View {
        if note.hasPDF, note.pdfPageCount > pageIndex,
           let image = store.pdfPageImage(noteID: note.id,
                                          pageIndex: pageIndex,
                                          size: pageSize,
                                          scale: pdfScale) {
            ZStack {
                Color.white
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
            .frame(width: pageSize.width, height: pageSize.height)
        } else {
            PaperBackgroundView(template: note.paperTemplate, tint: note.paperTint)
                .frame(width: pageSize.width, height: pageSize.height)
        }
    }


    // MARK: 套索

    private var lassoLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: pageSize.width, height: pageSize.height)
                .contentShape(Rectangle())
                .gesture(lassoGesture)

            if lassoPoints.count > 1 {
                Canvas { context, _ in
                    var path = Path()
                    path.addLines(lassoPoints)
                    path.closeSubpath()
                    context.fill(path, with: .color(Theme.accent.opacity(0.10)))
                    context.stroke(path,
                                   with: .color(Theme.accent),
                                   style: StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                }
                .frame(width: pageSize.width, height: pageSize.height)
                .allowsHitTesting(false)
            }

            if let selection = lassoSelection, !selection.isEmpty {
                selectionOverlay(selection)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }

    private var lassoGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if lassoPoints.isEmpty { lassoSelection = nil }
                if let last = lassoPoints.last {
                    let distance = hypot(value.location.x - last.x, value.location.y - last.y)
                    guard distance > 2.5 else { return }
                }
                lassoPoints.append(value.location)
            }
            .onEnded { _ in
                finishLasso()
            }
    }

    private func finishLasso() {
        let points = lassoPoints
        lassoPoints = []
        guard points.count >= 6 else {
            lassoSelection = nil
            return
        }
        let drawing = store.drawing(noteID: note.id, pageID: pageID)
        let result = InkSelectionEngine.select(in: drawing, polygon: points)
        withAnimation(.easeOut(duration: 0.15)) {
            lassoSelection = result.isEmpty ? nil : result
        }
    }

    private func selectionOverlay(_ selection: InkSelectionResult) -> some View {
        let bounds = selection.bounds
        let boxX = bounds.minX + selectionDrag.width
        let boxY = bounds.minY + selectionDrag.height
        let toolbarWidth: CGFloat = 244
        let toolbarX = min(max(bounds.midX - toolbarWidth / 2, 8),
                           max(pageSize.width - toolbarWidth - 8, 8))
        let toolbarY = bounds.minY > 68
            ? bounds.minY - 56
            : min(bounds.maxY + 14, max(pageSize.height - 56, 8))

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: max(bounds.width, 10), height: max(bounds.height, 10))
                .overlay(
                    Rectangle().strokeBorder(Theme.accent,
                                             style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                )
                .contentShape(Rectangle())
                .offset(x: boxX, y: boxY)
                .gesture(selectionMoveGesture(selection))

            selectionToolbar(selection)
                .offset(x: toolbarX, y: toolbarY)
        }
    }

    private func selectionToolbar(_ selection: InkSelectionResult) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(InkPalette.colors.prefix(6).enumerated()), id: \.offset) { _, color in
                Button {
                    recolorSelection(selection, color: color)
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            Button {
                duplicateSelection(selection)
            } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.78))
            }
            .buttonStyle(.plain)

            Button {
                deleteSelection(selection)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeOut(duration: 0.12)) { lassoSelection = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .qianNoteGlassCapsule()
    }

    private func selectionMoveGesture(_ selection: InkSelectionResult) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                selectionDrag = value.translation
            }
            .onEnded { value in
                let offset = value.translation
                selectionDrag = .zero
                guard abs(offset.width) > 1 || abs(offset.height) > 1 else { return }

                let drawing = store.drawing(noteID: note.id, pageID: pageID)
                let updated = InkSelectionEngine.translate(drawing,
                                                           indices: selection.indices,
                                                           offset: offset)
                controller.applyEdit(updated)

                var moved = selection
                moved.bounds = selection.bounds.offsetBy(dx: offset.width, dy: offset.height)
                lassoSelection = moved
            }
    }

    private func recolorSelection(_ selection: InkSelectionResult, color: Color) {
        let drawing = store.drawing(noteID: note.id, pageID: pageID)
        let updated = InkSelectionEngine.recolor(drawing,
                                                 indices: selection.indices,
                                                 color: UIColor(color))
        controller.applyEdit(updated)
        withAnimation(.easeOut(duration: 0.12)) { lassoSelection = nil }
    }

    private func duplicateSelection(_ selection: InkSelectionResult) {
        let drawing = store.drawing(noteID: note.id, pageID: pageID)
        let offset = CGSize(width: 26, height: 26)
        let updated = InkSelectionEngine.duplicate(drawing, indices: selection.indices, offset: offset)
        let originalCount = drawing.strokes.count
        controller.applyEdit(updated)

        guard updated.strokes.count > originalCount else { return }
        var moved = selection
        moved.indices = Set(originalCount..<updated.strokes.count)
        moved.bounds = selection.bounds.offsetBy(dx: offset.width, dy: offset.height)
        lassoSelection = moved
    }

    private func deleteSelection(_ selection: InkSelectionResult) {
        let drawing = store.drawing(noteID: note.id, pageID: pageID)
        let updated = InkSelectionEngine.remove(drawing, indices: selection.indices)
        controller.applyEdit(updated)
        withAnimation(.easeOut(duration: 0.12)) { lassoSelection = nil }
    }

    // MARK: 图片裁剪

    private func applyCrop(item: ImageItem, cropped: UIImage, cropRect: CGRect) {
        guard let data = cropped.pngData(),
              let name = try? store.saveImage(data, noteID: note.id) else { return }

        store.updatePage(noteID: note.id, pageID: pageID) { page in
            guard let index = page.images.firstIndex(where: { $0.id == item.id }) else { return }
            var updated = page.images[index]
            updated.fileName = name
            updated.x = Double(CGFloat(item.x) + CGFloat(item.width) * cropRect.minX)
            updated.y = Double(CGFloat(item.y) + CGFloat(item.height) * cropRect.minY)
            updated.width = Double(CGFloat(item.width) * cropRect.width)
            updated.height = Double(CGFloat(item.height) * cropRect.height)
            page.images[index] = updated
        }
        selectedImageID = item.id
    }

    // MARK: 图片对象

    @ViewBuilder
    private var imageVisualLayer: some View {
        if let page, !page.images.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(page.images) { item in
                    if let ui = store.image(noteID: note.id, fileName: item.fileName) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                            .frame(width: CGFloat(item.width), height: CGFloat(item.height))
                            .clipped()
                            .offset(x: CGFloat(item.x), y: CGFloat(item.y))
                    }
                }
            }
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// 套索模式下才出现：可拖动 / 缩放 / 删除图片
    @ViewBuilder
    private var imageHandleLayer: some View {
        if let page, tools.activeTool == .lasso, !isNavigating, !page.images.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(page.images) { item in
                    imageHandleView(item)
                }
            }
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        }
    }

    private func imageHandleView(_ item: ImageItem) -> some View {
        let isSelected = selectedImageID == item.id
        let liveWidth = CGFloat(item.width) + (resizingImageID == item.id ? resizingTranslation.width : 0)
        let liveHeight = CGFloat(item.height) + (resizingImageID == item.id ? resizingTranslation.height : 0)

        return Rectangle()
            .fill(Color.clear)
            .frame(width: max(liveWidth, 40), height: max(liveHeight, 40))
            .overlay(
                Rectangle()
                    .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 1.5)
            )
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .contentShape(Circle().inset(by: -12))
                        .gesture(resizeGesture(item))
                        .offset(x: 6, y: 6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Button {
                        store.updatePage(noteID: note.id, pageID: pageID) { page in
                            page.images.removeAll { $0.id == item.id }
                        }
                        selectedImageID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, Color.red)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 11, y: -11)
                }
            }
            .overlay(alignment: .topLeading) {
                if isSelected {
                    Button {
                        croppingItem = item
                    } label: {
                        Image(systemName: "crop")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -12, y: -12)
                    .accessibilityLabel("裁剪图片")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedImageID = item.id }
            .gesture(moveGesture(item))
            .offset(x: CGFloat(item.x) + (draggingImageID == item.id ? imageTranslation.width : 0),
                    y: CGFloat(item.y) + (draggingImageID == item.id ? imageTranslation.height : 0))
    }

    private func moveGesture(_ item: ImageItem) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                selectedImageID = item.id
                draggingImageID = item.id
                imageTranslation = value.translation
            }
            .onEnded { value in
                var updated = item
                updated.x += Double(value.translation.width)
                updated.y += Double(value.translation.height)
                updated.x = min(max(updated.x, -updated.width * 0.5), Double(pageSize.width) - updated.width * 0.5)
                updated.y = min(max(updated.y, -updated.height * 0.5), Double(pageSize.height) - updated.height * 0.5)
                store.updatePage(noteID: note.id, pageID: pageID) { page in
                    if let index = page.images.firstIndex(where: { $0.id == item.id }) {
                        page.images[index] = updated
                    }
                }
                draggingImageID = nil
                imageTranslation = .zero
            }
    }

    private func resizeGesture(_ item: ImageItem) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                resizingImageID = item.id
                resizingTranslation = value.translation
            }
            .onEnded { value in
                var updated = item
                let ratio = item.height / max(item.width, 1)
                let newWidth = max(60, item.width + Double(value.translation.width))
                updated.width = newWidth
                updated.height = max(60, newWidth * ratio)
                store.updatePage(noteID: note.id, pageID: pageID) { page in
                    if let index = page.images.firstIndex(where: { $0.id == item.id }) {
                        page.images[index] = updated
                    }
                }
                resizingImageID = nil
                resizingTranslation = .zero
            }
    }

    // MARK: 文字层

    @ViewBuilder
    private var textLayer: some View {
        if let page {
            ZStack(alignment: .topLeading) {
                ForEach(page.textBoxes) { box in
                    textBoxView(box)
                        .offset(x: CGFloat(box.x) + (draggingID == box.id ? dragTranslation.width : 0),
                                y: CGFloat(box.y) + (draggingID == box.id ? dragTranslation.height : 0))
                }
            }
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
            .allowsHitTesting(tools.activeTool == .text)
        }
    }

    private func textBoxView(_ box: TextBox) -> some View {
        textBoxBody(box,
                    isSelected: selectedTextID == box.id,
                    isEditing: editingTextID == box.id,
                    interactive: tools.activeTool == .text)
    }

    private func textBoxBody(_ box: TextBox,
                             isSelected: Bool,
                             isEditing: Bool,
                             interactive: Bool) -> some View {
        // 选中时右侧留出一条给 × 的位置，正文按剩余宽度换行，不会压到按钮上
        let textWidth = max(CGFloat(box.width) - (isSelected && interactive && !isEditing ? 26 : 8), 48)
        let tappable = interactive && !isEditing

        return ZStack(alignment: .topTrailing) {
            Group {
                if isEditing {
                    // 就地编辑：不用弹窗，退格、全选、中文输入法候选都跟系统一致
                    TextField("", text: $draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: draftFontSize))
                        .foregroundStyle(Color(hex: box.colorHex) ?? .primary)
                        .focused($focusedTextID, equals: box.id)
                } else {
                    Text(box.text.isEmpty ? "点按输入文字" : box.text)
                        .font(.system(size: CGFloat(box.fontSize)))
                        .foregroundStyle(box.text.isEmpty ? Color.secondary : (Color(hex: box.colorHex) ?? .primary))
                }
            }
            .frame(width: textWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected && interactive ? Theme.accent.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected && interactive ? Theme.accent.opacity(0.6) : Color.clear,
                                  style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            )
            // 手势只挂在文字这一层：编辑中（或非文字工具）完全不挂，
            // 否则光标的点按定位、拖选会被抢走
            .contentShape(Rectangle())
            .onTapGesture {
                guard tappable else { return }
                beginEditing(box)
            }
            .gesture(dragGesture(for: box), including: tappable ? .all : .none)

            // × 和文字是 ZStack 里的兄弟节点，不受上面那层轻点手势影响；
            // 画在框内右上角（不往外偏移），贴页面顶边时不会被 clipped() 裁掉
            if isSelected && interactive && !isEditing {
                Button {
                    removeTextBox(box)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.red)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 1)
                .padding(.top, -2)
                .accessibilityLabel("删除文字")
            }
        }
    }

    private func dragGesture(for box: TextBox) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                draggingID = box.id
                dragTranslation = value.translation
            }
            .onEnded { value in
                guard draggingID == box.id else { return }
                var updated = box
                updated.x += Double(value.translation.width)
                updated.y += Double(value.translation.height)
                updated.x = min(max(updated.x, 0), Double(pageSize.width) - 40)
                updated.y = min(max(updated.y, 0), Double(pageSize.height) - 30)
                store.updatePage(noteID: note.id, pageID: pageID) { page in
                    if let index = page.textBoxes.firstIndex(where: { $0.id == box.id }) {
                        page.textBoxes[index] = updated
                    }
                }
                draggingID = nil
                dragTranslation = .zero
            }
    }

    // MARK: 文字的编辑 / 提交 / 删除

    private func beginEditing(_ box: TextBox) {
        if editingTextID != box.id { commitActiveText() }
        selectedTextID = box.id
        draftText = box.text
        draftFontSize = CGFloat(box.fontSize)
        editingTextID = box.id
        DispatchQueue.main.async { focusedTextID = box.id }
    }

    /// 收笔：把草稿写回存储；内容是空的就直接删掉这个框，不留「点按输入文字」的僵尸占位
    private func commitActiveText() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        focusedTextID = nil
        // 从 store 取，而不是用 body 里那份 note：新建框后视图会换一份 note 值，
        // 用旧值找新框会找不到，表现就是「刚写的字没保存」
        guard let box = store.note(id: note.id)?.pages[safe: pageIndex]?.textBoxes
            .first(where: { $0.id == id }) else { return }

        let content = draftText
        let size = Double(draftFontSize)
        let isEmpty = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        store.updatePage(noteID: note.id, pageID: pageID) { page in
            if isEmpty {
                page.textBoxes.removeAll { $0.id == box.id }
            } else if let index = page.textBoxes.firstIndex(where: { $0.id == box.id }) {
                page.textBoxes[index].text = content
                page.textBoxes[index].fontSize = size
            }
        }
        if isEmpty, selectedTextID == box.id { selectedTextID = nil }
        // 这次调过的字号顺手记成默认值，下一个新建的框跟着走
        if !isEmpty, tools.textFontSize != CGFloat(size) { tools.textFontSize = CGFloat(size) }
    }

    private func removeTextBox(_ box: TextBox) {
        if editingTextID == box.id {
            editingTextID = nil
            focusedTextID = nil
        }
        store.updatePage(noteID: note.id, pageID: pageID) { page in
            page.textBoxes.removeAll { $0.id == box.id }
        }
        if selectedTextID == box.id { selectedTextID = nil }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func addTextBox(at location: CGPoint) {
        // 宽度算出来必须是个正数：点页面右边缘时「pageWidth - x - 16」会变成负数，
        // 旧版没拦，负宽度的框连内容形状都是空的 —— 点不到、也看不到 ×，就等于永久删不掉。
        let minWidth: Double = 140
        let maxX = max(Double(pageSize.width) - minWidth - 16, 0)
        let x = min(max(Double(location.x), 0), maxX)
        var box = TextBox(text: "",
                          x: x,
                          y: min(max(Double(location.y), 0), Double(pageSize.height) - 28),
                          fontSize: Double(tools.textFontSize),
                          colorHex: tools.color(for: .text).hexString)
        box.width = min(320, max(minWidth, Double(pageSize.width) - box.x - 16))

        store.updatePage(noteID: note.id, pageID: pageID) { page in
            page.textBoxes.append(box)
        }
        beginEditing(box)
    }
}

// MARK: - 纸张背景（SwiftUI 绘制）

struct PaperBackgroundView: View {
    let template: PaperTemplate
    let tint: PaperTint

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tint.surface))

            guard template != .blank else { return }

            let rule = tint.rule

            switch template {
            case .blank:
                break

            case .ruled:
                var y = PaperLayout.topInset
                while y < size.height - 20 {
                    var path = Path()
                    path.move(to: CGPoint(x: PaperLayout.horizontalInset, y: y))
                    path.addLine(to: CGPoint(x: size.width - PaperLayout.horizontalInset, y: y))
                    context.stroke(path, with: .color(rule), lineWidth: 0.8)
                    y += PaperLayout.lineSpacing
                }

            case .grid:
                let spacing = PaperLayout.gridSpacing
                var x: CGFloat = 0
                while x <= size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(rule), lineWidth: 0.8)
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(rule), lineWidth: 0.8)
                    y += spacing
                }

            case .dotted:
                let spacing = PaperLayout.dotSpacing
                var y = spacing
                while y < size.height {
                    var x = spacing
                    while x < size.width {
                        let rect = CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2)
                        context.fill(Path(ellipseIn: rect), with: .color(rule))
                        x += spacing
                    }
                    y += spacing
                }

            case .cornell:
                let topLine = size.height * 0.18
                let bottomLine = size.height * 0.82
                let marginX = size.width * 0.26

                var separators = Path()
                separators.move(to: CGPoint(x: 0, y: topLine))
                separators.addLine(to: CGPoint(x: size.width, y: topLine))
                separators.move(to: CGPoint(x: 0, y: bottomLine))
                separators.addLine(to: CGPoint(x: size.width, y: bottomLine))
                separators.move(to: CGPoint(x: marginX, y: topLine))
                separators.addLine(to: CGPoint(x: marginX, y: bottomLine))
                context.stroke(separators, with: .color(rule), lineWidth: 0.9)

                var y = topLine + PaperLayout.lineSpacing
                while y < bottomLine - 10 {
                    var path = Path()
                    path.move(to: CGPoint(x: PaperLayout.horizontalInset, y: y))
                    path.addLine(to: CGPoint(x: size.width - PaperLayout.horizontalInset, y: y))
                    context.stroke(path, with: .color(rule), lineWidth: 0.7)
                    y += PaperLayout.lineSpacing
                }
            }
        }
    }
}

// MARK: - 激光笔

/// 只在屏幕上留一道会消失的红线，不写入笔迹文件
struct LaserOverlay: View {
    var color: Color
    var width: CGFloat

    @State private var points: [CGPoint] = []
    @State private var clearWork: DispatchWorkItem?

    var body: some View {
        Canvas { context, _ in
            guard points.count > 1 else { return }
            var path = Path()
            path.addLines(points)
            let line = max(width, 2)
            context.stroke(path,
                           with: .color(color.opacity(0.22)),
                           style: StrokeStyle(lineWidth: line * 2.4, lineCap: .round, lineJoin: .round))
            context.stroke(path,
                           with: .color(color.opacity(0.92)),
                           style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    clearWork?.cancel()
                    if let last = points.last,
                       hypot(value.location.x - last.x, value.location.y - last.y) < 2.2 {
                        return
                    }
                    points.append(value.location)
                }
                .onEnded { _ in
                    let work = DispatchWorkItem { points.removeAll() }
                    clearWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                }
        )
        .allowsHitTesting(true)
    }
}

// MARK: - 图片裁剪

struct ImageCropperView: View {
    let image: UIImage
    let onDone: (UIImage, CGRect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rect = CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96)
    @State private var baseRect: CGRect?

    init(image: UIImage, onDone: @escaping (UIImage, CGRect) -> Void) {
        self.image = image
        self.onDone = onDone
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geo in
                    let fitted = fittedRect(in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)

                        dimming
                        cropFrame(fitted: fitted)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Text("拖动白框四角调整保留区域，拖动框内可整体移动")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
            }
            .navigationTitle("裁剪图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { performCrop() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var dimming: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(boxRect(fitted: fittedRect(in: size)))
            context.fill(path,
                         with: .color(Color.black.opacity(0.45)),
                         style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private func cropFrame(fitted: CGRect) -> some View {
        let box = boxRect(fitted: fitted)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: max(box.width, 1), height: max(box.height, 1))
                .offset(x: box.minX, y: box.minY)
                .contentShape(Rectangle())
                .gesture(moveGesture(fitted: fitted))

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(fitted: fitted, corner: corner)
            }
        }
    }

    private func handle(fitted: CGRect, corner: Corner) -> some View {
        let box = boxRect(fitted: fitted)
        let point: CGPoint
        switch corner {
        case .topLeft: point = CGPoint(x: box.minX, y: box.minY)
        case .topRight: point = CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft: point = CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: point = CGPoint(x: box.maxX, y: box.maxY)
        }

        return Circle()
            .fill(Color.white)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .contentShape(Circle().inset(by: -16))
            .offset(x: point.x - 8, y: point.y - 8)
            .gesture(resizeGesture(fitted: fitted, corner: corner))
    }

    private func moveGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if baseRect == nil { baseRect = rect }
                guard let base = baseRect else { return }
                let dx = value.translation.width / max(fitted.width, 1)
                let dy = value.translation.height / max(fitted.height, 1)
                var updated = base
                updated.origin.x = min(max(base.minX + dx, 0), 1 - base.width)
                updated.origin.y = min(max(base.minY + dy, 0), 1 - base.height)
                rect = updated
            }
            .onEnded { _ in baseRect = nil }
    }

    private func resizeGesture(fitted: CGRect, corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if baseRect == nil { baseRect = rect }
                guard let base = baseRect else { return }
                let dx = value.translation.width / max(fitted.width, 1)
                let dy = value.translation.height / max(fitted.height, 1)
                var updated = base
                switch corner {
                case .topLeft:
                    updated.origin.x += dx
                    updated.origin.y += dy
                    updated.size.width -= dx
                    updated.size.height -= dy
                case .topRight:
                    updated.origin.y += dy
                    updated.size.width += dx
                    updated.size.height -= dy
                case .bottomLeft:
                    updated.origin.x += dx
                    updated.size.width -= dx
                    updated.size.height += dy
                case .bottomRight:
                    updated.size.width += dx
                    updated.size.height += dy
                }
                rect = clamp(updated)
            }
            .onEnded { _ in baseRect = nil }
    }

    private func clamp(_ r: CGRect) -> CGRect {
        var minX = min(r.minX, r.maxX)
        var maxX = max(r.minX, r.maxX)
        var minY = min(r.minY, r.maxY)
        var maxY = max(r.minY, r.maxY)

        minX = min(max(minX, 0), 1)
        maxX = min(max(maxX, 0), 1)
        minY = min(max(minY, 0), 1)
        maxY = min(max(maxY, 0), 1)

        if maxX - minX < 0.08 {
            minX = min(minX, 0.92)
            maxX = minX + 0.08
        }
        if maxY - minY < 0.08 {
            minY = min(minY, 0.92)
            maxY = minY + 0.08
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func boxRect(fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + rect.minX * fitted.width,
               y: fitted.minY + rect.minY * fitted.height,
               width: rect.width * fitted.width,
               height: rect.height * fitted.height)
    }

    private func performCrop() {
        let upright = normalizedUp(image)
        guard let cg = upright.cgImage else {
            dismiss()
            return
        }
        let pixel = CGRect(x: rect.minX * CGFloat(cg.width),
                           y: rect.minY * CGFloat(cg.height),
                           width: rect.width * CGFloat(cg.width),
                           height: rect.height * CGFloat(cg.height)).integral
        guard pixel.width > 1, pixel.height > 1, let cropped = cg.cropping(to: pixel) else {
            dismiss()
            return
        }
        onDone(UIImage(cgImage: cropped, scale: upright.scale, orientation: .up), rect)
        dismiss()
    }

    private func normalizedUp(_ source: UIImage) -> UIImage {
        guard source.imageOrientation != .up else { return source }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = source.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: source.size, format: format)
        return renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
    }
}
