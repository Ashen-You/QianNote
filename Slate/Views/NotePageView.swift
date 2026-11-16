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

    @State private var selectedTextID: UUID?
    @State private var editingBox: TextBox?
    @State private var dragTranslation: CGSize = .zero
    @State private var draggingID: UUID?

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

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            imageVisualLayer

            DrawingCanvas(pageID: pageID,
                          initialDrawing: store.drawing(noteID: note.id, pageID: pageID),
                          tool: tools.pkTool,
                          toolKey: tools.toolKey,
                          fingerDrawing: tools.fingerDrawing,
                          isEnabled: tools.activeTool != .text,
                          controller: controller,
                          onChange: { drawing in
                              store.saveDrawing(drawing, noteID: note.id, pageID: pageID)
                          },
                          onPinch: onPinch,
                          onPan: onPan,
                          onDoubleTap: onDoubleTap,
                          onPencilDoubleTap: onPencilDoubleTap,
                          shapeRecognition: shapeRecognition,
                          isShapeEligible: tools.activeTool.supportsShapeSnap,
                          onPenMove: onPenMove)
                .frame(width: pageSize.width, height: pageSize.height)

            imageHandleLayer

            if tools.activeTool == .text {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: pageSize.width, height: pageSize.height)
                    .onTapGesture(coordinateSpace: .local) { location in
                        addTextBox(at: location)
                    }
            }

            textLayer
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        .sheet(item: $editingBox) { box in
            TextBoxEditor(box: box) { updated in
                store.updatePage(noteID: note.id, pageID: pageID) { page in
                    if let index = page.textBoxes.firstIndex(where: { $0.id == updated.id }) {
                        page.textBoxes[index] = updated
                    }
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
        if let page, tools.activeTool == .lasso, !page.images.isEmpty {
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
        let isSelected = selectedTextID == box.id
        let interactive = tools.activeTool == .text

        return ZStack(alignment: .topTrailing) {
            Text(box.text.isEmpty ? "点按输入文字" : box.text)
                .font(.system(size: CGFloat(box.fontSize)))
                .foregroundStyle(box.text.isEmpty ? Color.secondary : (Color(hex: box.colorHex) ?? .primary))
                .frame(width: CGFloat(box.width), height: CGFloat(box.height), alignment: .topLeading)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected && interactive ? Theme.accent.opacity(0.06) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected && interactive ? Theme.accent.opacity(0.6) : Color.clear,
                                      style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                )

            if isSelected && interactive {
                Button {
                    store.updatePage(noteID: note.id, pageID: pageID) { page in
                        page.textBoxes.removeAll { $0.id == box.id }
                    }
                    selectedTextID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.red)
                }
                .buttonStyle(.plain)
                .offset(x: 10, y: -10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard interactive else { return }
            selectedTextID = box.id
            editingBox = box
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard interactive else { return }
                    draggingID = box.id
                    dragTranslation = value.translation
                }
                .onEnded { value in
                    guard interactive, draggingID == box.id else { return }
                    var updated = box
                    updated.x += Double(value.translation.width)
                    updated.y += Double(value.translation.height)
                    store.updatePage(noteID: note.id, pageID: pageID) { page in
                        if let index = page.textBoxes.firstIndex(where: { $0.id == box.id }) {
                            page.textBoxes[index] = updated
                        }
                    }
                    draggingID = nil
                    dragTranslation = .zero
                }
        )
    }

    private func addTextBox(at location: CGPoint) {
        var box = TextBox(text: "",
                          x: Double(location.x),
                          y: Double(location.y),
                          fontSize: Double(tools.textFontSize),
                          colorHex: tools.color(for: .text).hexString)
        box.width = min(320, Double(pageSize.width) - box.x - 20)
        box.height = 80

        store.updatePage(noteID: note.id, pageID: pageID) { page in
            page.textBoxes.append(box)
        }
        selectedTextID = box.id
        editingBox = box
    }
}

// MARK: - 文字编辑弹窗

struct TextBoxEditor: View {
    let box: TextBox
    let onSave: (TextBox) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var fontSize: CGFloat

    init(box: TextBox, onSave: @escaping (TextBox) -> Void) {
        self.box = box
        self.onSave = onSave
        _text = State(initialValue: box.text)
        _fontSize = State(initialValue: CGFloat(box.fontSize))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $text)
                    .font(.system(size: fontSize))
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    )

                HStack {
                    Text("字号")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Slider(value: $fontSize, in: 12...72, step: 1)
                    Text("\(Int(fontSize))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            .padding(20)
            .navigationTitle("编辑文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        var updated = box
                        updated.text = text
                        updated.fontSize = Double(fontSize)
                        onSave(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
