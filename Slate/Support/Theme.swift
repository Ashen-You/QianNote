import SwiftUI

enum Theme {
    /// 主强调色（靛蓝）
    static let accent = Color(red: 0.34, green: 0.35, blue: 0.94)
    /// 次强调色（青绿）
    static let accentSecondary = Color(red: 0.10, green: 0.72, blue: 0.68)

    static var editorBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    static var libraryBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    static let panelCorner: CGFloat = 20
    static let cardCorner: CGFloat = 16
}
