import SwiftUI
import Combine

/// Floating Liquid Glass tool palette, Illustrator style, at the left of the canvas. Press and
/// hold a button to choose another way of drawing with that tool.
struct ToolPalette: View {
    @ObservedObject var state: EditorState

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(state: state, tool: tool)
                }
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

private struct ToolButton: View {
    @ObservedObject var state: EditorState
    let tool: Tool

    private var methods: [DrawMethod] { DrawMethod.methods(for: tool) }
    private var isSelected: Bool { state.tool == tool }

    var body: some View {
        Group {
            if methods.count > 1 {
                Menu {
                    Picker("Method", selection: Binding(
                        get: { state.methods[tool] ?? methods[0] },
                        set: { state.choose($0) }
                    )) {
                        ForEach(methods) { m in
                            Label(m.title, systemImage: m.systemImage).tag(m)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    icon
                } primaryAction: {
                    state.tool = tool
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
            } else {
                Button { state.tool = tool } label: { icon }
            }
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.9))
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .help(methods.count > 1 ? "\(tool.help). Press and hold for other ways to draw." : tool.help)
        .accessibilityLabel(tool.title)
    }

    private var icon: some View {
        ToolIcon(tool: tool, method: state.methods[tool])
            .frame(width: 22, height: 22)
            .overlay(alignment: .bottomTrailing) {
                if methods.count > 1 {
                    // The small corner mark 2D Design and Illustrator use for buttons with a flyout.
                    Path { p in
                        p.move(to: CGPoint(x: 5, y: 0)); p.addLine(to: CGPoint(x: 5, y: 5)); p.addLine(to: CGPoint(x: 0, y: 5)); p.closeSubpath()
                    }
                    .fill(isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: 2)
                }
            }
            .contentShape(Rectangle())
    }
}

/// A tool's icon: its chosen method's symbol, or a drawn arc for the Arc tool.
struct ToolIcon: View {
    let tool: Tool
    var method: DrawMethod?

    var body: some View {
        if tool == .arc {
            Path { p in
                p.addArc(center: CGPoint(x: 3, y: 19), radius: 15, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            }
            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        } else {
            Image(systemName: (method ?? DrawMethod.defaultMethod(for: tool))?.systemImage ?? tool.systemImage)
                .font(.system(size: 15, weight: .medium))
        }
    }
}
