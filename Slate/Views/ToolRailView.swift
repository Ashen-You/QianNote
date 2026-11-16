import SwiftUI

// MARK: - 左侧工具栏

struct ToolRailView: View {
    @ObservedObject var tools: ToolStore
    @Binding var showPalette: Bool

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
            // 与 Notability 一致：再点当前工具收起面板，点别的工具则切换并展开面板
            if isActive {
                withAnimation(.easeInOut(duration: 0.18)) { showPalette.toggle() }
            } else {
                tools.activeTool = tool
                withAnimation(.easeInOut(duration: 0.18)) { showPalette = true }
            }
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

// MARK: - 工具面板（贴工具栏右侧展开）

struct ToolPaletteView: View {
    @ObservedObject var tools: ToolStore

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(26), spacing: 9), count: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tools.activeTool.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if tools.activeTool.needsColor {
                if !tools.recentColors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最近")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 9) {
                            ForEach(Array(tools.recentColors.enumerated()), id: \.offset) { _, color in
                                Button {
                                    tools.setColor(color, for: tools.activeTool)
                                } label: {
                                    ColorDot(color: color,
                                             selected: tools.color(for: tools.activeTool) == color,
                                             size: 24)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                LazyVGrid(columns: columns, spacing: 9) {
                    ForEach(Array(InkPalette.colors.enumerated()), id: \.offset) { _, color in
                        Button {
                            tools.setColor(color, for: tools.activeTool)
                        } label: {
                            ColorDot(color: color,
                                     selected: tools.color(for: tools.activeTool) == color,
                                     size: 24)
                        }
                        .buttonStyle(.plain)
                    }

                    ColorPicker("",
                                selection: tools.colorBinding(for: tools.activeTool),
                                supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 24, height: 24)
                }
            }

            if tools.activeTool.supportsWidth {
                VStack(alignment: .leading, spacing: 7) {
                    Text("粗细")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(Array(tools.activeTool.widthPresets.enumerated()), id: \.offset) { _, preset in
                            Button {
                                tools.setWidth(preset, for: tools.activeTool)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(isSelected(preset)
                                              ? Theme.accent.opacity(0.16)
                                              : Color.primary.opacity(0.05))
                                        .frame(width: 32, height: 32)
                                    Circle()
                                        .fill(tools.activeTool == .eraser
                                              ? Color.primary.opacity(0.45)
                                              : tools.color(for: tools.activeTool))
                                        .frame(width: dotSize(preset), height: dotSize(preset))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if tools.activeTool.supportsShapeSnap {
                Toggle(isOn: $tools.shapeRecognition) {
                    Text("形状识别")
                        .font(.caption2)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
            }

            if tools.activeTool == .eraser {
                Picker("", selection: $tools.eraserMode) {
                    ForEach(ToolStore.EraserMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if tools.activeTool == .text {
                VStack(alignment: .leading, spacing: 6) {
                    Text("字号 \(Int(tools.textFontSize))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $tools.textFontSize, in: 12...72, step: 1)
                        .tint(Theme.accent)
                }
            }

            if tools.activeTool == .lasso {
                Text("圈选后可拖动、缩放或删除笔迹")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    private func isSelected(_ preset: CGFloat) -> Bool {
        abs(tools.width(for: tools.activeTool) - preset) < 0.6
    }

    private func dotSize(_ preset: CGFloat) -> CGFloat {
        min(max(preset, 3), 18)
    }
}
