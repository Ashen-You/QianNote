import SwiftUI
import UIKit

// MARK: - 纸张样式

enum PaperTemplate: String, Codable, CaseIterable, Identifiable {
    case blank
    case ruled
    case grid
    case dotted
    case cornell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "空白"
        case .ruled: return "横线"
        case .grid: return "方格"
        case .dotted: return "点阵"
        case .cornell: return "康奈尔"
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "rectangle"
        case .ruled: return "list.dash"
        case .grid: return "grid"
        case .dotted: return "circle.grid.3x3"
        case .cornell: return "rectangle.split.3x1"
        }
    }
}

// MARK: - 纸张底色

enum PaperTint: String, Codable, CaseIterable, Identifiable {
    case white
    case cream
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "纯白"
        case .cream: return "米色"
        case .dark: return "深色"
        }
    }

    var surface: Color {
        switch self {
        case .white: return Color(red: 0.996, green: 0.996, blue: 1.0)
        case .cream: return Color(red: 0.980, green: 0.957, blue: 0.898)
        case .dark: return Color(red: 0.106, green: 0.110, blue: 0.125)
        }
    }

    var rule: Color {
        switch self {
        case .white: return Color(red: 0.80, green: 0.82, blue: 0.86)
        case .cream: return Color(red: 0.85, green: 0.80, blue: 0.69)
        case .dark: return Color(red: 0.25, green: 0.26, blue: 0.30)
        }
    }

    var uiSurface: UIColor {
        switch self {
        case .white: return UIColor(red: 0.996, green: 0.996, blue: 1.0, alpha: 1)
        case .cream: return UIColor(red: 0.980, green: 0.957, blue: 0.898, alpha: 1)
        case .dark: return UIColor(red: 0.106, green: 0.110, blue: 0.125, alpha: 1)
        }
    }

    var uiRule: UIColor {
        switch self {
        case .white: return UIColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 1)
        case .cream: return UIColor(red: 0.85, green: 0.80, blue: 0.69, alpha: 1)
        case .dark: return UIColor(red: 0.25, green: 0.26, blue: 0.30, alpha: 1)
        }
    }
}

// MARK: - 纸张排版参数（SwiftUI 与 UIKit 渲染共用）

enum PaperLayout {
    static let lineSpacing: CGFloat = 34
    static let gridSpacing: CGFloat = 36
    static let dotSpacing: CGFloat = 30
    static let horizontalInset: CGFloat = 40
    static let topInset: CGFloat = 50
}
