import SwiftUI

enum Theme {
    /// 主强调色（靛蓝）
    static let accent = Color(red: 0.34, green: 0.35, blue: 0.94)
    /// 次强调色（青绿）
    static let accentSecondary = Color(red: 0.10, green: 0.72, blue: 0.68)

    /// 编辑页背景。
    /// 从纯灰改成一层很淡的强调色渐变：浮层用的是 Liquid Glass，
    /// 底下如果没有颜色，玻璃只会「看起来更白」；有这层淡色它能折射出一点色相和明暗变化，
    /// 才有那种液态玻璃的通透感。明暗两套各自取合适的浓度，避免深色下糊成一片。
    static var editorBackdrop: some View {
        backdrop
    }

    static var libraryBackground: some View {
        backdrop
    }

    private static var backdrop: LinearGradient {
        LinearGradient(stops: [
            .init(color: accent.opacity(0.10), location: 0),
            .init(color: Color(uiColor: .systemGroupedBackground), location: 0.42),
            .init(color: Color(uiColor: .systemGroupedBackground), location: 0.62),
            .init(color: accentSecondary.opacity(0.08), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let panelCorner: CGFloat = 20
    static let cardCorner: CGFloat = 16
}
