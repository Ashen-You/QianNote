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

// MARK: - 调色板

enum InkPalette {
    static let colors: [Color] = [
        Color(hex: "#1C1C1E") ?? .black,
        Color(hex: "#6B7280") ?? .gray,
        Color(hex: "#E03A3A") ?? .red,
        Color(hex: "#F07B24") ?? .orange,
        Color(hex: "#F2C230") ?? .yellow,
        Color(hex: "#3FA34D") ?? .green,
        Color(hex: "#0FA3A3") ?? .teal,
        Color(hex: "#2D6CDF") ?? .blue,
        Color(hex: "#5B4BE0") ?? .indigo,
        Color(hex: "#A64AC9") ?? .purple,
        Color(hex: "#E5488F") ?? .pink,
        Color(hex: "#8B5A2B") ?? .brown
    ]
}
