import SwiftUI
import UIKit

/// 右侧页面缩略图栏
struct PageStripView: View {
    @EnvironmentObject private var store: NoteStore

    let note: Note
    @Binding var pageIndex: Int

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(note.pages.enumerated()), id: \.element.id) { index, page in
                            Button {
                                pageIndex = index
                            } label: {
                                PageThumbnailCell(note: note,
                                                  page: page,
                                                  index: index,
                                                  isActive: index == pageIndex)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .contextMenu {
                                Button {
                                    store.duplicatePage(noteID: note.id, at: index)
                                } label: {
                                    Label("复制此页", systemImage: "doc.on.doc")
                                }
                                Button {
                                    store.addPage(noteID: note.id, after: index)
                                } label: {
                                    Label("在后面插入空白页", systemImage: "plus.square")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    store.deletePage(noteID: note.id, at: index)
                                    if pageIndex >= note.pages.count {
                                        pageIndex = max(0, note.pages.count - 1)
                                    }
                                } label: {
                                    Label("删除此页", systemImage: "trash")
                                }
                                .disabled(note.pages.count <= 1)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
                }
                .onChange(of: pageIndex) { _, newValue in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            Button {
                store.addPage(noteID: note.id)
                pageIndex = note.pages.count
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accent.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .accessibilityLabel("添加页面")
        }
        .slateGlassPanel(cornerRadius: 18)
    }
}

struct PageThumbnailCell: View {
    @EnvironmentObject private var store: NoteStore

    let note: Note
    let page: NotePage
    let index: Int
    let isActive: Bool
    var width: CGFloat = 82
    var height: CGFloat = 108

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isActive ? Theme.accent : Color.primary.opacity(0.12),
                                  lineWidth: isActive ? 2 : 1)
            )

            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? Theme.accent : Color.secondary)
        }
        .contentShape(Rectangle())
        .task(id: taskKey) {
            image = await store.thumbnail(noteID: note.id, pageID: page.id)
        }
    }

    /// 只跟着「自己这一页」的版本号走：别的页面刷新不该让这张单元格重跑
    private var taskKey: String {
        "\(store.thumbnailVersions[page.id] ?? 0)-\(page.id.uuidString)"
    }
}

// MARK: - 手机上的页面选择

/// iPhone 没有右侧那一竖条的位置，页面切换改成弹出的缩略图网格。
struct PageGridSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    let note: Note
    @Binding var pageIndex: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 118), spacing: 14)],
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(Array(note.pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            pageIndex = index
                            dismiss()
                        } label: {
                            PageThumbnailCell(note: note,
                                              page: page,
                                              index: index,
                                              isActive: index == pageIndex,
                                              width: 96,
                                              height: 126)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                store.duplicatePage(noteID: note.id, at: index)
                            } label: {
                                Label("复制此页", systemImage: "doc.on.doc")
                            }
                            Button {
                                store.addPage(noteID: note.id, after: index)
                            } label: {
                                Label("在后面插入空白页", systemImage: "plus.square")
                            }
                            Divider()
                            Button(role: .destructive) {
                                store.deletePage(noteID: note.id, at: index)
                                if pageIndex >= note.pages.count {
                                    pageIndex = max(0, note.pages.count - 1)
                                }
                            } label: {
                                Label("删除此页", systemImage: "trash")
                            }
                            .disabled(note.pages.count <= 1)
                        }
                    }

                    Button {
                        store.addPage(noteID: note.id)
                        pageIndex = note.pages.count - 1
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 96, height: 126)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Theme.accent.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(Theme.accent.opacity(0.35),
                                                      style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                                )
                            Text("新页面")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .navigationTitle("页面 \(pageIndex + 1) / \(note.pages.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
