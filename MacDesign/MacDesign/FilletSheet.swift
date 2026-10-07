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

/// Asks for the fillet style and radius before rounding the selected corners.
struct FilletSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FilletPrefs.radiusKey) private var radius = 5.0
    @AppStorage(FilletPrefs.smoothKey) private var smooth = false
    @AppStorage(FilletPrefs.smoothingKey) private var smoothing = 0.6
    /// Typed text, so the canvas previews every keystroke rather than waiting for Return.
    @State private var radiusText = ""

    private var typedRadius: Double? {
        Double(radiusText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private var style: FilletStyle { smooth ? .smooth(smoothing) : .arc }

    private func updatePreview() {
        state.filletPreview = typedRadius.flatMap { $0 > 0 ? FilletPreview(radius: $0, style: style) : nil }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Fillet Corners").font(.headline)
            Text(state.filletDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                OptionCard(title: "Arc", caption: "A constant radius corner, formed using part of a circle.",
                           selected: !smooth) { smooth = false } content: { FilletThumbnail(style: .arc) }
                OptionCard(title: "Smooth", caption: "Curvature eases into and out of the corner. Adjust smoothing in preferences.",
                           selected: smooth) { smooth = true } content: { FilletThumbnail(style: .smooth(smoothing)) }
            }
            HStack {
                Text("Radius")
                TextField("", text: $radiusText)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text("mm").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fillet") {
                    guard let r = typedRadius, r > 0 else { return }
                    radius = r
                    state.filletPreview = nil
                    state.fillet(radius: r, style: style)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled((typedRadius ?? 0) <= 0)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            radiusText = radius == radius.rounded() ? String(Int(radius)) : String(radius)
            updatePreview()
        }
        .onChange(of: radiusText) { _, _ in updatePreview() }
        .onChange(of: smooth) { _, _ in updatePreview() }
        .onDisappear { state.filletPreview = nil }
    }
}

/// A rounded right angle in the given style, with the sharp corner it replaces shown faintly.
struct FilletThumbnail: View {
    let style: FilletStyle

    var body: some View {
        Canvas { ctx, size in
            let corner = PathData(segments: [.move(TSDPoint(x: 0, y: 0)), .line(TSDPoint(x: 96, y: 0)), .line(TSDPoint(x: 96, y: 96))], isClosed: false)
            let filleted = Fillet.apply(to: corner, corners: nil, radius: 56, style: style).path
            let ox = size.width / 2 - 48, oy = size.height / 2 + 48
            func pt(_ p: TSDPoint) -> CGPoint { CGPoint(x: ox + p.x, y: oy - p.y) }
            var sharp = Path()
            sharp.move(to: pt(TSDPoint(x: 30, y: 0))); sharp.addLine(to: pt(TSDPoint(x: 96, y: 0))); sharp.addLine(to: pt(TSDPoint(x: 96, y: 66)))
            ctx.stroke(sharp, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            var path = Path()
            for seg in filleted.segments {
                switch seg {
                case .move(let p): path.move(to: pt(p))
                case .line(let p): path.addLine(to: pt(p))
                case .curve(let c1, let c2, let e): path.addCurve(to: pt(e), control1: pt(c1), control2: pt(c2))
                }
            }
            ctx.stroke(path, with: .color(.primary), lineWidth: 2.5)
        }
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
                FilletThumbnail(style: smooth ? .smooth(smoothing) : .arc)
                    .frame(height: 110)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

