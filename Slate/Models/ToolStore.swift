import SwiftUI
import PencilKit
import UIKit

// MARK: - 工具种类

enum ToolKind: String, CaseIterable, Identifiable {
    case pen
    case pencil
    case highlighter
    case eraser
    case lasso
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "钢笔"
        case .pencil: return "铅笔"
        case .highlighter: return "荧光笔"
        case .eraser: return "橡皮"
        case .lasso: return "套索"
        case .text: return "文字"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        }
    }

    var isInk: Bool {
        self == .pen || self == .pencil || self == .highlighter
    }

    var needsColor: Bool {
        isInk || self == .text
    }

    var supportsWidth: Bool {
        isInk || self == .eraser
    }

    var inkType: PKInk.InkType {
        switch self {
        case .pencil: return .pencil
        case .highlighter: return .marker
        default: return .pen
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen: return 1...20
        case .pencil: return 1...20
        case .highlighter: return 8...40
        case .eraser: return 8...60
        default: return 1...20
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .pen: return 3.5
        case .pencil: return 4
        case .highlighter: return 18
        case .eraser: return 24
        default: return 4
        }
    }

    var defaultColor: Color {
        switch self {
        case .pencil: return Color(hex: "#3C3C43") ?? .black
        case .highlighter: return Color(hex: "#FFD84D") ?? .yellow
        default: return Color(hex: "#1C1C1E") ?? .black
        }
    }
}

// MARK: - 工具状态（颜色 / 粗细会持久化）

final class ToolStore: ObservableObject {
    @Published var activeTool: ToolKind = .pen {
        didSet {
            guard activeTool != oldValue else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    @Published private var colors: [ToolKind: Color] = [:]
    @Published private var widths: [ToolKind: CGFloat] = [:]

    @Published var textFontSize: CGFloat = 22 {
        didSet { defaults.set(Double(textFontSize), forKey: "text.fontSize") }
    }

    @Published var fingerDrawing: Bool = true {
        didSet { defaults.set(fingerDrawing, forKey: "tool.fingerDrawing") }
    }

    private let defaults = UserDefaults.standard

    init() {
        var loadedColors: [ToolKind: Color] = [:]
        var loadedWidths: [ToolKind: CGFloat] = [:]

        for tool in ToolKind.allCases {
            if let hex = defaults.string(forKey: "tool.color.\(tool.rawValue)"),
               let color = Color(hex: hex) {
                loadedColors[tool] = color
            } else {
                loadedColors[tool] = tool.defaultColor
            }

            let storedWidth = defaults.double(forKey: "tool.width.\(tool.rawValue)")
            loadedWidths[tool] = storedWidth > 0 ? CGFloat(storedWidth) : tool.defaultWidth
        }

        colors = loadedColors
        widths = loadedWidths

        if defaults.object(forKey: "tool.fingerDrawing") != nil {
            fingerDrawing = defaults.bool(forKey: "tool.fingerDrawing")
        }

        let storedFont = defaults.double(forKey: "text.fontSize")
        if storedFont > 0 {
            textFontSize = CGFloat(storedFont)
        }
    }

    // MARK: 查询

    func color(for tool: ToolKind) -> Color {
        colors[tool] ?? tool.defaultColor
    }

    func width(for tool: ToolKind) -> CGFloat {
        widths[tool] ?? tool.defaultWidth
    }

    var activeColor: Color { color(for: activeTool) }
    var activeWidth: CGFloat { width(for: activeTool) }

    // MARK: 修改

    func setColor(_ color: Color, for tool: ToolKind) {
        colors[tool] = color
        defaults.set(color.hexString, forKey: "tool.color.\(tool.rawValue)")
    }

    func setWidth(_ width: CGFloat, for tool: ToolKind) {
        let clamped = min(max(width, tool.widthRange.lowerBound), tool.widthRange.upperBound)
        widths[tool] = clamped
        defaults.set(Double(clamped), forKey: "tool.width.\(tool.rawValue)")
    }

    // MARK: Bindings

    func colorBinding(for tool: ToolKind) -> Binding<Color> {
        Binding(get: { self.color(for: tool) }, set: { self.setColor($0, for: tool) })
    }

    func widthBinding(for tool: ToolKind) -> Binding<Double> {
        Binding(get: { Double(self.width(for: tool)) },
                set: { self.setWidth(CGFloat($0), for: tool) })
    }

    // MARK: PencilKit

    var pkTool: PKTool {
        switch activeTool {
        case .eraser:
            return PKEraserTool(.vector, width: width(for: .eraser))
        case .lasso, .text:
            return PKLassoTool()
        default:
            return PKInkingTool(activeTool.inkType, color: UIColor(activeColor), width: activeWidth)
        }
    }

    /// 用于判断是否需要把工具同步给 PKCanvasView（避免每次刷新都重设工具）
    var toolKey: String {
        "\(activeTool.rawValue)|\(activeColor.hexString)|\(activeWidth)|\(fingerDrawing)"
    }
}
