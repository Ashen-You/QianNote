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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 6)
    }
}

private struct PageThumbnailCell: View {
    @EnvironmentObject private var store: NoteStore

    let note: Note
    let page: NotePage
    let index: Int
    let isActive: Bool

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
            .frame(width: 82, height: 108)
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
