import SwiftUI
import UIKit

// MARK: - 液态玻璃浮层

extension View {
    /// 圆角浮层（工具栏 / 颜色面板 / 缩略图栏）
    func qianNoteGlassPanel(cornerRadius: CGFloat = 20,
                         tint: Color? = nil,
                         interactive: Bool = false) -> some View {
        modifier(QianNoteGlassPanelModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// 胶囊浮层（顶栏 / 底栏 / 提示条）
    func qianNoteGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(QianNoteGlassCapsuleModifier(tint: tint, interactive: interactive))
    }
}

/// iOS 26 起用系统的 Liquid Glass（`glassEffect`）：真实折射、随内容变化的边缘高光、
/// 按压时会有形变。iOS 17–18 上退回「毛玻璃 + 细描边 + 阴影」，观感尽量靠拢。
private struct QianNoteGlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

private struct QianNoteGlassCapsuleModifier: ViewModifier {
    var tint: Color?
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Capsule()
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 6)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - 图标按钮

struct IconButton: View {
    let systemName: String
    var isActive: Bool = false
    var size: CGFloat = 36
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(isActive ? Theme.accent : Color.primary.opacity(0.78))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isActive ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.05))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.isEmpty ? systemName : label)
    }
}

// MARK: - 分享面板

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 颜色圆点

struct ColorDot: View {
    let color: Color
    var selected: Bool = false
    var size: CGFloat = 24

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(Color.primary.opacity(color == .black ? 0.15 : 0.10), lineWidth: 1)
            )
            .overlay(
                Circle()
                    .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2.5)
                    .padding(-4)
            )
            .contentShape(Circle())
    }
}

// MARK: - 空状态

struct EmptyLibraryView: View {
    let onCreate: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 108, height: 108)
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.accent)
            }

            VStack(spacing: 6) {
                Text("还没有笔记")
                    .font(.title3.weight(.semibold))
                Text("新建一本手写笔记，或导入 PDF / Word / 图片开始批注。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: onCreate) {
                    Label("新建笔记", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button(action: onImport) {
                    Label("导入文档", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

// MARK: - 错误提示条

struct ErrorBanner: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("关闭", action: onDismiss)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .qianNoteGlassPanel(cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - 更换 App 图标

struct AppIconPicker: View {
    @ObservedObject var manager: AppIconManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("选一个图标。切换时 iOS 会弹确认框，主屏幕图标随即更换。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                HStack(alignment: .top, spacing: 18) {
                    ForEach(AppIconChoice.allCases) { choice in
                        iconCard(choice)
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
            }
            .navigationTitle("App 图标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func iconCard(_ choice: AppIconChoice) -> some View {
        let selected = manager.current == choice
        Button {
            manager.select(choice)
        } label: {
            VStack(spacing: 10) {
                Image(choice.thumbName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 3)
                    )
                Text(choice.title)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text("使用中")
                    } else {
                        Text("点击切换")
                    }
                }
                .font(.caption)
                .foregroundStyle(selected ? Theme.accent : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .qianNoteGlassPanel(cornerRadius: Theme.cardCorner)
        }
        .buttonStyle(.plain)
    }
}

