import SwiftUI
import Combine

/// Floating Liquid Glass tool palette, Illustrator style, at the left of the canvas.
struct ToolPalette: View {
    @ObservedObject var state: EditorState

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(tool: tool, isSelected: state.tool == tool) {
                        state.tool = tool
                    }
                }
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

private struct ToolButton: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.9))
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .help(tool.help)
        .accessibilityLabel(tool.title)
    }
}
