import SwiftUI

// MARK: - 左侧工具栏

struct ToolRailView: View {
    @ObservedObject var tools: ToolStore
    @Binding var showPalette: Bool
    /// 收起工具栏（浮层模式下留一颗箭头，收起来后页面整块可用）
    var onCollapse: () -> Void = {}

    /// 手拖模式：整页进入纯导航，手指和 Pencil 都只拖页面 / 翻页，谁都不写字
    private var isHandActive: Bool { !tools.fingerDrawing }

    /// 刚刚长按过的工具。长按松手时 Button 的 tap 动作还会再触发一次，
    /// 用它把这一次「点」吃掉，否则长按开面板会立刻被当成点击关掉。
    @State private var longPressedTool: ToolKind?
    @State private var longPressedHand = false

    var body: some View {
        VStack(spacing: 4) {
            handButton
            separator
            ForEach(ToolKind.allCases) { tool in
                toolButton(tool)
            }
            separator
            collapseButton
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 24, height: 1)
            .padding(.vertical, 3)
    }

    /// 手：点一下进拖动模式，再点一下回到上一支笔。
    /// 手拖和笔是互斥的两个状态，点哪个就是哪个，不弹面板。
    private var handButton: some View {
        Button {
            if longPressedHand {
                longPressedHand = false
                return
            }
            // 切到拖动：顺手把面板收起来（拖动没有颜色/粗细可调）
            if !isHandActive {
                tools.fingerDrawing = false
                withAnimation(.easeInOut(duration: 0.18)) { showPalette = false }
            } else {
                // 再点一下 = 回到上一支笔，继续改写
                tools.fingerDrawing = true
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHandActive ? Theme.accent.opacity(0.14) : Color.clear)

                Image(systemName: isHandActive ? "hand.point.up.left.fill" : "hand.point.up.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isHandActive ? Theme.accent : Color.primary.opacity(0.72))
            }
            .frame(width: 44, height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                longPressedHand = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // 长按手：直接回到书写并展开面板
                tools.fingerDrawing = true
                withAnimation(.easeInOut(duration: 0.18)) { showPalette = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { longPressedHand = false }
            }
        )
        .accessibilityLabel(isHandActive ? "拖动模式（点击回到书写）" : "拖动模式：手指和 Pencil 都拖动页面")
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.45))
                .frame(width: 44, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收起工具栏")
    }

    private func toolButton(_ tool: ToolKind) -> some View {
        // 手拖模式下所有书写工具都算「未选中」，点一下即回到书写
        let isActive = tools.activeTool == tool && tools.fingerDrawing

        return Button {
            // 长按松手会再触发一次点击，这里把那次吃掉
            if longPressedTool == tool {
                longPressedTool = nil
                return
            }
            // 点 = 换笔 + 退出拖动模式，**不弹面板**：换笔是高频动作，弹面板反而挡视线
            tools.activeTool = tool
            tools.fingerDrawing = true
            if showPalette {
                withAnimation(.easeInOut(duration: 0.18)) { showPalette = false }
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
        .simultaneousGesture(
            // 长按 = 调这支笔的颜色 / 粗细
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                longPressedTool = tool
                tools.activeTool = tool
                tools.fingerDrawing = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeInOut(duration: 0.18)) { showPalette = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { longPressedTool = nil }
            }
        )
        .accessibilityLabel(tool.title)
        .accessibilityHint("长按调整颜色与粗细")
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
                Text("圈住笔迹后可以改色、复制、删除，或拖动选中框整体移动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if tools.activeTool == .laser {
                Text("激光笔只留一道会消失的红线，不会写进笔记")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if tools.activeTool == .dashed {
                Text("虚线笔抬笔后自动切成虚线段，适合画框和分隔")
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
