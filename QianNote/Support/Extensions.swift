import SwiftUI
import UIKit

// MARK: - Color <-> Hex

extension Color {
    init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6 || string.count == 8,
              let value = UInt64(string, radix: 16) else { return nil }

        if string.count == 6 {
            self.init(.sRGB,
                      red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255,
                      opacity: 1)
        } else {
            self.init(.sRGB,
                      red: Double((value >> 24) & 0xFF) / 255,
                      green: Double((value >> 16) & 0xFF) / 255,
                      blue: Double((value >> 8) & 0xFF) / 255,
                      opacity: Double(value & 0xFF) / 255)
        }
    }

    var hexString: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X",
                          Int((r * 255).rounded()),
                          Int((g * 255).rounded()),
                          Int((b * 255).rounded()))
        }
        return "#000000"
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6 || string.count == 8,
              let value = UInt64(string, radix: 16) else { return nil }

        if string.count == 6 {
            self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                      green: CGFloat((value >> 8) & 0xFF) / 255,
                      blue: CGFloat(value & 0xFF) / 255,
                      alpha: 1)
        } else {
            self.init(red: CGFloat((value >> 24) & 0xFF) / 255,
                      green: CGFloat((value >> 16) & 0xFF) / 255,
                      blue: CGFloat((value >> 8) & 0xFF) / 255,
                      alpha: CGFloat(value & 0xFF) / 255)
        }
    }
}

// MARK: - Collections

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Geometry

extension CGSize {
    func scaled(by factor: CGFloat) -> CGSize {
        CGSize(width: width * factor, height: height * factor)
    }
}

extension CGRect {
    static func aspectFit(_ content: CGSize, in rect: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return rect }
        let scale = min(rect.width / content.width, rect.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: rect.midX - size.width / 2,
                      y: rect.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }
}

// MARK: - App 图标切换

/// 两套图标都打进包里；`nil` 表示用主图标（Assets.xcassets/AppIcon）。
enum AppIconChoice: String, CaseIterable, Identifiable {
    case `default`
    case ai

    var id: String { rawValue }

    /// 传给 setAlternateIconName 的名字；主图标传 nil。
    var alternateName: String? {
        switch self {
        case .default: return nil
        case .ai: return "AppIconAI"
        }
    }

    var title: String {
        switch self {
        case .default: return "默认 · 手写笔记"
        case .ai: return "AI 重绘 · 奋斗头带"
        }
    }

    var thumbName: String {
        switch self {
        case .default: return "IconThumbScreenshot"
        case .ai: return "IconThumbAI"
        }
    }

    static func current() -> AppIconChoice {
        AppIconChoice(rawValue: UIApplication.shared.alternateIconName ?? "") ?? .default
    }
}

@MainActor
final class AppIconManager: ObservableObject {
    @Published private(set) var current: AppIconChoice = .current()
    @Published var errorMessage: String?

    /// 包里真正声明过的备用图标名（CFBundleIcons.CFBundleAlternateIcons）。
    ///
    /// 这一条不能省：`setAlternateIconName` 只要名字被设置为非 nil 就会「成功」，
    /// 系统之后却按这个名字去 Assets.car 里找图，找不到就退成白底网格占位图。
    /// 之前 Info.plist 手写了 AppIconAI 但包里没这个文件，主屏就变成了网格。
    private static func declaredAlternates() -> Set<String> {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        guard let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any] else { return [] }
        return Set(alternates.keys)
    }

    /// 启动时自愈：已经停在「名字有、图没有」的坏状态下就退回主图标，
    /// 否则用户会一直看着白底网格，且 App 里怎么切都救不回来。
    func repairIfNeeded() {
        guard let name = UIApplication.shared.alternateIconName else {
            current = .default
            return
        }
        guard !Self.declaredAlternates().contains(name) else {
            current = AppIconChoice.current()
            return
        }
        UIApplication.shared.setAlternateIconName(nil) { [weak self] _ in
            Task { @MainActor in self?.current = .default }
        }
    }

    /// iOS 用系统弹窗确认切换，这里只负责调用。切完记录当前项供 UI 打勾。
    func select(_ choice: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "当前系统不支持更换图标"
            return
        }
        guard choice != current else { return }
        if let name = choice.alternateName,
           !Self.declaredAlternates().contains(name) {
            errorMessage = "这套图标没有打进当前安装包，先把这两张图加进 Assets 再试。"
            return
        }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = "切换图标失败：\(error.localizedDescription)"
                } else {
                    self.current = choice
                }
            }
        }
    }
}

// MARK: - 调色板

enum InkPalette {
    /// 24 色：深色系 / 彩色系 / 浅色荧光系各 8 个，贴近 Notability 的取色习惯
    static let colors: [Color] = [
        // 深色系
        Color(hex: "#000000") ?? .black,
        Color(hex: "#3C3C43") ?? .black,
        Color(hex: "#6B7280") ?? .gray,
        Color(hex: "#9CA3AF") ?? .gray,
        Color(hex: "#1E3A8A") ?? .blue,
        Color(hex: "#7F1D1D") ?? .red,
        Color(hex: "#14532D") ?? .green,
        Color(hex: "#4C1D95") ?? .purple,
        // 彩色系
        Color(hex: "#E03A3A") ?? .red,
        Color(hex: "#F97316") ?? .orange,
        Color(hex: "#F2C230") ?? .yellow,
        Color(hex: "#3FA34D") ?? .green,
        Color(hex: "#0FA3A3") ?? .teal,
        Color(hex: "#2D6CDF") ?? .blue,
        Color(hex: "#5B4BE0") ?? .indigo,
        Color(hex: "#A64AC9") ?? .purple,
        // 浅色 / 荧光系
        Color(hex: "#E5488F") ?? .pink,
        Color(hex: "#8B5A2B") ?? .brown,
        Color(hex: "#F9A8D4") ?? .pink,
        Color(hex: "#FDE68A") ?? .yellow,
        Color(hex: "#BBF7D0") ?? .green,
        Color(hex: "#BAE6FD") ?? .blue,
        Color(hex: "#DDD6FE") ?? .purple,
        Color(hex: "#FED7AA") ?? .orange
    ]
}
