import SwiftUI
import TSDKit

/// Asks how far to explode the selection, with a picture of each option.
struct ExplodeSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("explodeFully") private var fully = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Explode \(state.selection.count == 1 ? "Object" : "\(state.selection.count) Objects")")
                .font(.headline)
            HStack(spacing: 16) {
                ExplodeOption(title: "One level", caption: "Splits groups, and paths into runs that don't touch. Joined lines stay joined.",
                              selected: !fully) { fully = false } content: { OneLevelThumbnail() }
                ExplodeOption(title: "Fully", caption: "Breaks everything down to lines, curves and circles.",
                              selected: fully) { fully = true } content: { FullyThumbnail() }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Explode") {
                    state.explode(fully: fully)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct ExplodeOption<Content: View>: View {
    let title: String
    let caption: String
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: select) {
            VStack(spacing: 8) {
                content()
                    .frame(width: 200, height: 120)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
                Text(title).font(.body.weight(.semibold))
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(height: 32, alignment: .top)
            }
            .frame(width: 220)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Thumbnails

/// Selection box around a rect, drawn as the canvas does it.
private func selectionBox(_ r: CGRect, in ctx: inout GraphicsContext) {
    let box = r.insetBy(dx: -5, dy: -5)
    ctx.stroke(Path(box), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    for p in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)] {
        let h = CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)
        ctx.fill(Path(h), with: .color(.white))
        ctx.stroke(Path(h), with: .color(.accentColor), lineWidth: 1)
    }
}

/// A zigzag run and a square, each its own object after exploding one level.
private struct OneLevelThumbnail: View {
    var body: some View {
        Canvas { ctx, size in
            let ink = GraphicsContext.Shading.color(.primary)
            var zig = Path()
            zig.move(to: CGPoint(x: 28, y: 88))
            zig.addLine(to: CGPoint(x: 52, y: 40))
            zig.addLine(to: CGPoint(x: 70, y: 76))
            zig.addLine(to: CGPoint(x: 92, y: 32))
            ctx.stroke(zig, with: ink, lineWidth: 2)
            selectionBox(CGRect(x: 28, y: 32, width: 64, height: 56), in: &ctx)
            let square = CGRect(x: 124, y: 36, width: 50, height: 50)
            ctx.stroke(Path(square), with: ink, lineWidth: 2)
            selectionBox(square, in: &ctx)
        }
    }
}

/// A rectangle exploded into four separate lines.
private struct FullyThumbnail: View {
    var body: some View {
        Canvas { ctx, size in
            let ink = GraphicsContext.Shading.color(.primary)
            let r = CGRect(x: 56, y: 32, width: 88, height: 56)
            let gap: CGFloat = 7
            let sides = [
                CGRect(x: r.minX + gap, y: r.minY, width: r.width - 2 * gap, height: 0),
                CGRect(x: r.maxX, y: r.minY + gap, width: 0, height: r.height - 2 * gap),
                CGRect(x: r.minX + gap, y: r.maxY, width: r.width - 2 * gap, height: 0),
                CGRect(x: r.minX, y: r.minY + gap, width: 0, height: r.height - 2 * gap),
            ]
            for s in sides {
                var p = Path()
                p.move(to: CGPoint(x: s.minX, y: s.minY))
                p.addLine(to: CGPoint(x: s.maxX, y: s.maxY))
                ctx.stroke(p, with: ink, lineWidth: 2)
                selectionBox(s, in: &ctx)
            }
        }
    }
}
