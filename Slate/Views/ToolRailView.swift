import SwiftUI

// MARK: - 左侧工具栏

struct ToolRailView: View {
    @ObservedObject var tools: ToolStore

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ToolKind.allCases) { tool in
                toolButton(tool)
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    private func toolButton(_ tool: ToolKind) -> some View {
        let isActive = tools.activeTool == tool

        return Button {
            tools.activeTool = tool
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.14) : Color.clear)

                Image(systemName: tool.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Color.primary.opacity(0.72))
                    .overlay(alignment: .bottomTrailing) {
                        if tool.needsColor {
                            Circle()
                                .fill(tools.color(for: tool))
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                                .offset(x: 3, y: 3)
                        }
                    }
            }
            .frame(width: 44, height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
    }
}

// MARK: - 底部样式栏

struct StyleBarView: View {
    @ObservedObject var tools: ToolStore

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: tools.activeTool.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(tools.activeTool.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 74, alignment: .leading)

            Divider().frame(height: 26)

            if tools.activeTool.needsColor {
                colorSwatches
                Divider().frame(height: 26)
            }

            if tools.activeTool.supportsWidth {
                widthControl
            } else if tools.activeTool == .text {
                textSizeControl
            } else if tools.activeTool == .lasso {
                Text("圈选后可拖动、缩放或删除笔迹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    // MARK: 颜色

    private var colorSwatches: some View {
        HStack(spacing: 9) {
            ForEach(Array(InkPalette.colors.enumerated()), id: \.offset) { _, color in
                Button {
                    tools.setColor(color, for: tools.activeTool)
                } label: {
                    ColorDot(color: color,
                             selected: tools.color(for: tools.activeTool) == color,
                             size: 20)
                }
                .buttonStyle(.plain)
            }

            ColorPicker("",
                        selection: tools.colorBinding(for: tools.activeTool),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26, height: 26)
        }
    }

    // MARK: 粗细

    private var widthControl: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tools.color(for: tools.activeTool))
                .frame(width: widthPreview, height: widthPreview)
                .frame(width: 22, height: 22)

            Slider(value: tools.widthBinding(for: tools.activeTool),
                   in: Double(tools.activeTool.widthRange.lowerBound)...Double(tools.activeTool.widthRange.upperBound))
                .frame(width: 130)
                .tint(Theme.accent)
        }
    }

    private var widthPreview: CGFloat {
        let width = tools.width(for: tools.activeTool)
        return min(max(width, 3), 18)
    }

    // MARK: 字号

    private var textSizeControl: some View {
        HStack(spacing: 10) {
            Text("字号")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $tools.textFontSize, in: 12...72, step: 1)
                .frame(width: 130)
                .tint(Theme.accent)
            Text("\(Int(tools.textFontSize))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
