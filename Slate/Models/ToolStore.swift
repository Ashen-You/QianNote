import SwiftUI
import PencilKit
import UIKit

// MARK: - 工具种类

enum ToolKind: String, CaseIterable, Identifiable {
    case pen
    case pencil
    case fountainPen
    case monoline
    case crayon
    case watercolor
    case highlighter
    case eraser
    case lasso
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "钢笔"
        case .pencil: return "铅笔"
        case .fountainPen: return "毛笔"
        case .monoline: return "单线笔"
        case .crayon: return "蜡笔"
        case .watercolor: return "水彩"
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
        case .fountainPen: return "paintbrush.pointed.fill"
        case .monoline: return "line.diagonal"
        case .crayon: return "scribble"
        case .watercolor: return "paintbrush.fill"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        }
    }

    var isInk: Bool {
        switch self {
        case .pen, .pencil, .fountainPen, .monoline, .crayon, .watercolor, .highlighter:
            return true
        default:
            return false
        }
    }

    /// 形状识别只对"写字/画线"类笔生效
    var supportsShapeSnap: Bool {
        switch self {
        case .pen, .pencil, .fountainPen, .monoline: return true
        default: return false
        }
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
        case .fountainPen: return .fountainPen
        case .monoline: return .monoline
        case .crayon: return .crayon
        case .watercolor: return .watercolor
        case .highlighter: return .marker
        default: return .pen
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .highlighter: return 8...40
        case .eraser: return 8...60
        case .watercolor: return 4...40
        case .fountainPen: return 1...24
        default: return 1...20
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .pen: return 3.5
        case .pencil: return 4
        case .fountainPen: return 6
        case .monoline: return 3
        case .crayon: return 8
        case .watercolor: return 14
        case .highlighter: return 18
        case .eraser: return 24
        default: return 4
        }
    }

    /// 常用粗细档位（对应 Notability 的几档笔尖大小）
    var widthPresets: [CGFloat] {
        switch self {
        case .pen: return [1.5, 3, 6, 10]
        case .pencil: return [2, 4, 7, 12]
        case .fountainPen: return [3, 6, 10, 16]
        case .monoline: return [1.5, 3, 5, 8]
        case .crayon: return [4, 8, 12, 18]
        case .watercolor: return [6, 12, 20, 30]
        case .highlighter: return [10, 16, 24, 34]
        case .eraser: return [12, 24, 40, 60]
        default: return [2, 4, 8, 12]
        }
    }

    var defaultColor: Color {
        switch self {
        case .pencil: return Color(hex: "#3C3C43") ?? .black
        case .highlighter: return Color(hex: "#FFD84D") ?? .yellow
        case .fountainPen: return Color(hex: "#101828") ?? .black
        case .crayon: return Color(hex: "#C2410C") ?? .orange
        case .watercolor: return Color(hex: "#2D6CDF") ?? .blue
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

    /// 橡皮模式：整笔擦（vector）/ 像素擦（bitmap）
    @Published var eraserMode: EraserMode = .stroke {
        didSet { defaults.set(eraserMode.rawValue, forKey: "tool.eraserMode") }
    }

    enum EraserMode: String, CaseIterable, Identifiable {
        case stroke
        case pixel

        var id: String { rawValue }
        var title: String { self == .stroke ? "整笔擦" : "像素擦" }
    }

    /// 最近使用过的颜色（最多 6 个，与 Notability 一致）
    @Published private(set) var recentColors: [Color] = []
    private static let recentLimit = 6

    /// 形状识别：画圆 / 方 / 三角 / 直线后自动规整
    @Published var shapeRecognition: Bool = true {
        didSet { defaults.set(shapeRecognition, forKey: "tool.shapeRecognition") }
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

        if let raw = defaults.string(forKey: "tool.eraserMode"),
           let mode = EraserMode(rawValue: raw) {
            eraserMode = mode
        }

        let storedFont = defaults.double(forKey: "text.fontSize")
        if storedFont > 0 {
            textFontSize = CGFloat(storedFont)
        }

        if let hexes = defaults.stringArray(forKey: "tool.recentColors") {
            recentColors = hexes.compactMap { Color(hex: $0) }
        }

        if defaults.object(forKey: "tool.shapeRecognition") != nil {
            shapeRecognition = defaults.bool(forKey: "tool.shapeRecognition")
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
        if tool.needsColor {
            recordRecent(color)
        }
    }

    /// 记录最近使用的颜色
    func recordRecent(_ color: Color) {
        let hex = color.hexString
        var list = recentColors.filter { $0.hexString != hex }
        list.insert(color, at: 0)
        if list.count > Self.recentLimit {
            list = Array(list.prefix(Self.recentLimit))
        }
        recentColors = list
        defaults.set(list.map { $0.hexString }, forKey: "tool.recentColors")
    }

    /// Apple Pencil 双击：笔 ↔ 橡皮
    func togglePencilEraser() {
        switch activeTool {
        case .eraser:
            activeTool = .pen
        case .pen, .pencil, .highlighter:
            activeTool = .eraser
        default:
            break
        }
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
            let style: PKEraserTool.EraserType = eraserMode == .stroke ? .vector : .bitmap
            return PKEraserTool(style, width: width(for: .eraser))
        case .lasso, .text:
            return PKLassoTool()
        default:
            return PKInkingTool(activeTool.inkType, color: UIColor(activeColor), width: activeWidth)
        }
    }

    /// 用于判断是否需要把工具同步给 PKCanvasView（避免每次刷新都重设工具）
    var toolKey: String {
        "\(activeTool.rawValue)|\(activeColor.hexString)|\(activeWidth)|\(fingerDrawing)|\(eraserMode.rawValue)"
    }
}
