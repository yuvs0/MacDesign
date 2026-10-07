import SwiftUI
import TSDKit

/// Fillet preferences, shared by all windows.
enum FilletPrefs {
    static let smoothKey = "filletSmooth"
    static let smoothingKey = "filletSmoothing"
    static let radiusKey = "filletRadius"

    static func register() {
        UserDefaults.standard.register(defaults: [smoothKey: false, smoothingKey: 0.6, radiusKey: 5.0])
    }

    static var style: FilletStyle {
        let d = UserDefaults.standard
        return d.bool(forKey: smoothKey) ? .smooth(d.double(forKey: smoothingKey)) : .arc
    }

    static var radius: Double {
        let v = UserDefaults.standard.double(forKey: radiusKey)
        return v > 0 ? v : 5
    }
}

/// Asks for the fillet radius before rounding the selected corners.
struct FilletSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FilletPrefs.radiusKey) private var radius = 5.0
    @AppStorage(FilletPrefs.smoothKey) private var smooth = false
    @AppStorage(FilletPrefs.smoothingKey) private var smoothing = 0.6
    @FocusState private var radiusFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fillet Corners").font(.headline)
            Text(state.filletDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text("Radius")
                Spacer()
                TextField("", value: $radius, format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .focused($radiusFocused)
                Text("mm").foregroundStyle(.secondary)
            }
            Picker("Style", selection: $smooth) {
                Text("Arc (G1)").tag(false)
                Text("Smooth \(Int((smoothing * 100).rounded()))%").tag(true)
            }
            .pickerStyle(.segmented)
            Text("The style and smoothing can be changed in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fillet") {
                    state.fillet(radius: radius, style: smooth ? .smooth(smoothing) : .arc)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(radius <= 0)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { radiusFocused = true }
    }
}

/// The app's Settings window.
struct SettingsView: View {
    @AppStorage(FilletPrefs.smoothKey) private var smooth = false
    @AppStorage(FilletPrefs.smoothingKey) private var smoothing = 0.6
    @AppStorage(FilletPrefs.radiusKey) private var radius = 5.0

    var body: some View {
        Form {
            Section("Fillets") {
                Picker("Corner style", selection: $smooth) {
                    Text("Arc, tangent to both sides (G1)").tag(false)
                    Text("Smooth, curvature eases in (like Apple's shapes)").tag(true)
                }
                .pickerStyle(.radioGroup)
                if smooth {
                    HStack {
                        Text("Smoothing")
                        Slider(value: $smoothing, in: 0...1)
                        Text("\(Int((smoothing * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .help("Figma's corner smoothing. 0% is a plain arc; Apple's icons and buttons are about 60%.")
                }
                HStack {
                    Text("Default radius")
                    Spacer()
                    TextField("", value: $radius, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("mm").foregroundStyle(.secondary)
                }
                FilletPreview(style: smooth ? .smooth(smoothing) : .arc)
                    .frame(height: 90)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

/// A right angle rounded with the chosen style, for the Settings window.
private struct FilletPreview: View {
    let style: FilletStyle

    var body: some View {
        Canvas { ctx, size in
            let corner = PathData(segments: [.move(TSDPoint(x: 0, y: 0)), .line(TSDPoint(x: 60, y: 0)), .line(TSDPoint(x: 60, y: 60))], isClosed: false)
            let filleted = Fillet.apply(to: corner, corners: nil, radius: 24, style: style).path
            var path = Path()
            let ox = size.width / 2 - 30, oy = size.height - 12
            func pt(_ p: TSDPoint) -> CGPoint { CGPoint(x: ox + p.x, y: oy - p.y) }
            for seg in filleted.segments {
                switch seg {
                case .move(let p): path.move(to: pt(p))
                case .line(let p): path.addLine(to: pt(p))
                case .curve(let c1, let c2, let e): path.addCurve(to: pt(e), control1: pt(c1), control2: pt(c2))
                }
            }
            ctx.stroke(path, with: .color(.primary), lineWidth: 2)
            // The sharp corner it replaced, faintly.
            var sharp = Path()
            sharp.move(to: pt(TSDPoint(x: 36, y: 0))); sharp.addLine(to: pt(TSDPoint(x: 60, y: 0))); sharp.addLine(to: pt(TSDPoint(x: 60, y: 24)))
            ctx.stroke(sharp, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}
