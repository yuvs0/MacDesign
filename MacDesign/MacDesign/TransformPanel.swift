import SwiftUI
import TSDKit

/// Which point of the selection's bounds X and Y refer to, and which stays put when
/// resizing. Illustrator's reference point selector.
enum ReferencePoint: Int, CaseIterable {
    case topLeft, top, topRight, left, centre, right, bottomLeft, bottom, bottomRight

    /// 0...1 across and up the bounds.
    var fraction: (x: Double, y: Double) {
        let col = Double(rawValue % 3) / 2
        let row = Double(rawValue / 3)
        return (col, 1 - row / 2)
    }

    func point(in b: TSDRect) -> TSDPoint {
        TSDPoint(x: b.minX + b.width * fraction.x, y: b.minY + b.height * fraction.y)
    }
}

/// Illustrator-style transform panel: reference point grid, X and Y, W and H with a
/// proportions lock.
struct TransformPanel: View {
    @ObservedObject var state: EditorState
    @AppStorage("referencePoint") private var referenceRaw = ReferencePoint.topLeft.rawValue
    @AppStorage("constrainProportions") private var constrain = true

    private var reference: ReferencePoint { ReferencePoint(rawValue: referenceRaw) ?? .topLeft }

    var body: some View {
        if let b = state.selectionBounds {
            let ref = reference.point(in: b)
            HStack(alignment: .center, spacing: 12) {
                ReferenceGrid(selected: reference) { referenceRaw = $0.rawValue }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        field("X", value: ref.x) { v in state.transformSelection(.translation(v - ref.x, 0), actionName: "Move") }
                        field("W", value: b.width) { w in resize(width: w, bounds: b, about: ref) }
                    }
                    GridRow {
                        field("Y", value: ref.y) { v in state.transformSelection(.translation(0, v - ref.y), actionName: "Move") }
                        field("H", value: b.height) { h in resize(height: h, bounds: b, about: ref) }
                    }
                }
                Button {
                    constrain.toggle()
                } label: {
                    Image(systemName: constrain ? "lock.fill" : "lock.open")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(constrain ? "Width and height change together" : "Width and height change independently")
            }
        }
    }

    private func field(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            TextField("", value: Binding(get: { (value * 100).rounded() / 100 }, set: set), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .fixedSize()
        }
    }

    private func resize(width: Double? = nil, height: Double? = nil, bounds b: TSDRect, about anchor: TSDPoint) {
        var sx = 1.0, sy = 1.0
        if let w = width, b.width > 1e-9, w > 0 { sx = w / b.width }
        if let h = height, b.height > 1e-9, h > 0 { sy = h / b.height }
        if constrain {
            if width != nil, b.height > 1e-9 { sy = sx }
            if height != nil, b.width > 1e-9 { sx = sy }
        }
        guard sx != 1 || sy != 1 else { return }
        state.transformSelection(.scale(sx, sy, about: anchor), actionName: "Resize")
    }
}

/// The 3 × 3 grid of reference points.
private struct ReferenceGrid: View {
    let selected: ReferencePoint
    let select: (ReferencePoint) -> Void

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { col in
                        let p = ReferencePoint(rawValue: row * 3 + col)!
                        Button { select(p) } label: {
                            Rectangle()
                                .fill(p == selected ? Color.accentColor : Color.primary.opacity(0.18))
                                .frame(width: 7, height: 7)
                                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help(name(p))
                    }
                }
            }
        }
        .padding(3)
        .help("Reference point: where X and Y are measured, and what stays put when resizing")
    }

    private func name(_ p: ReferencePoint) -> String {
        ["Top left", "Top", "Top right", "Left", "Centre", "Right", "Bottom left", "Bottom", "Bottom right"][p.rawValue]
    }
}
