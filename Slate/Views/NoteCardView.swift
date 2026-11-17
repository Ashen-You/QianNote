import SwiftUI
import UIKit

struct NoteCardView: View {
    @EnvironmentObject private var store: NoteStore

    let note: Note
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            preview
            info
        }
        .task(id: taskKey) {
            thumbnail = await store.thumbnail(noteID: note.id, pageID: note.pages.first?.id)
        }
    }

    private var taskKey: String {
        let firstPage = note.pages.first?.id
        let version = firstPage.flatMap { store.thumbnailVersions[$0] } ?? 0
        return "\(version)-\(note.id.uuidString)-\(note.updatedAt.timeIntervalSince1970)"
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 5) {
                if note.hasRecording {
                    badge(systemName: "waveform", color: .orange)
                }
                if note.hasPDF {
                    badge(systemName: "doc.richtext", color: .blue)
                }
                if note.isFavorite {
                    badge(systemName: "star.fill", color: .yellow)
                }
            }
            .padding(8)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 10, x: 0, y: 4)
    }

    private func badge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(4)
            .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            HStack(spacing: 5) {
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(note.pageCountText)
                if let folder = store.folders.first(where: { $0.id == note.folderID }) {
                    Text("·")
                    Text(folder.name).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}
