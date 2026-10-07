import SwiftUI
import Combine
import AppKit
import TSDKit

struct InspectorView: View {
    @ObservedObject var state: EditorState
    @ObservedObject var document: DesignDocument

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch state.inspectorTab {
            case .properties:
                PropertiesPanel(state: state, document: document)
            case .layers:
                LayersPanel(state: state, document: document)
            }
        }
    }
}

// MARK: - Properties

struct PropertiesPanel: View {
    @ObservedObject var state: EditorState
    @ObservedObject var document: DesignDocument
    @FocusState private var textFieldFocused: Bool

    private var selected: [DesignObject] { state.selectedObjects }
    private var single: DesignObject? { selected.count == 1 ? selected[0] : nil }

    var body: some View {
        Form {
            if selected.isEmpty {
                documentSection
                defaultsSection
            } else {
                objectSection
                appearanceSection
                geometrySection
                if let o = single, case .text = o.shape { textSection(o) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.focusTextRequest) { _, _ in
            textFieldFocused = true
        }
    }

    // Document

    private var documentSection: some View {
        Section("Document") {
            LabeledContent("Page", value: document.doc.pageName ?? "Custom")
            LabeledContent("Size", value: "\(fmt(document.doc.pageSize.width)) × \(fmt(document.doc.pageSize.height)) mm")
            LabeledContent("Objects", value: "\(document.doc.objects.count)")
            LabeledContent("File version", value: document.doc.version)
        }
    }

    private var defaultsSection: some View {
        Section("New Shapes") {
            colorRow("Stroke", color: state.newShapeStyle.strokeColor ?? .black) { state.newShapeStyle.strokeColor = $0 }
            fillRow(fill: state.newShapeStyle.fillColor) { state.newShapeStyle.fillColor = $0 }
            Picker("Layer", selection: $state.activeLayer) {
                ForEach(document.doc.layers) { Text($0.name).tag($0.index) }
            }
            TextField("Font", text: $state.newTextFace)
            HStack {
                Text("Text size")
                Spacer()
                TextField("", value: $state.newTextSize, format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }

    // Selection

    private var objectSection: some View {
        Section(selected.count == 1 ? single!.displayName : "\(selected.count) objects") {
            if let o = single {
                TextField("Name", text: Binding(
                    get: { o.name ?? "" },
                    set: { v in state.updateSelected("Rename") { $0.name = v.isEmpty ? nil : v } }
                ))
            }
            Picker("Layer", selection: Binding(
                get: { single?.layer ?? (Set(selected.map { $0.layer }).count == 1 ? selected[0].layer : -1) },
                set: { if $0 > 0 { state.moveSelection(toLayer: $0) } }
            )) {
                if selected.count > 1, Set(selected.map { $0.layer }).count > 1 { Text("Mixed").tag(-1) }
                ForEach(document.doc.layers) { Text($0.name).tag($0.index) }
            }
            if let o = single {
                Toggle("Locked", isOn: Binding(get: { o.isLocked }, set: { v in state.updateSelected("Lock") { $0.isLocked = v } }))
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            colorRow("Stroke", color: single?.style.strokeColor ?? selected.first?.style.strokeColor ?? .black) { state.setStroke($0) }
            HStack(spacing: 6) {
                ForEach(swatches, id: \.hex) { c in
                    Button { state.setStroke(c) } label: {
                        Circle().fill(c.color).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(c.hex)
                }
            }
            fillRow(fill: single?.style.fillColor ?? selected.first?.style.fillColor) { state.setFill($0) }
            if let fill = (single ?? selected.first)?.style.fill, fill.isPreservedKind {
                LabeledContent("Fill type", value: fill.name)
                    .help("Kept as it was in the file. Choosing a fill colour replaces it.")
            }
            Picker("Line", selection: Binding(get: { (single ?? selected.first)?.style.lineType ?? .solid },
                                              set: { state.setLineType($0) })) {
                ForEach(LineType.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            HStack {
                Text("Stroke width")
                Spacer()
                TextField("", value: Binding(get: { single?.style.strokeWidth ?? selected.first?.style.strokeWidth ?? 0.25 },
                                             set: { state.setStrokeWidth($0) }), format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("mm").foregroundStyle(.secondary)
            }
            .help("0 is a hairline.")
        }
    }

    private var swatches: [RGB] {
        [.black, .red, .blue, .green, RGB(r: 255, g: 0, b: 255), RGB(r: 255, g: 128, b: 0), RGB(r: 0, g: 160, b: 255), RGB(r: 128, g: 128, b: 128)]
    }

    private var geometrySection: some View {
        Section("Geometry") {
            if let b = state.selectionBounds {
                numberRow("X", value: b.minX) { newX in state.transformSelection(.translation(newX - b.minX, 0), actionName: "Move") }
                numberRow("Y", value: b.minY) { newY in state.transformSelection(.translation(0, newY - b.minY), actionName: "Move") }
                numberRow("Width", value: b.width) { w in
                    guard b.width > 1e-9, w > 0 else { return }
                    state.transformSelection(.scale(w / b.width, 1, about: TSDPoint(x: b.minX, y: b.minY)), actionName: "Resize")
                }
                numberRow("Height", value: b.height) { h in
                    guard b.height > 1e-9, h > 0 else { return }
                    state.transformSelection(.scale(1, h / b.height, about: TSDPoint(x: b.minX, y: b.minY)), actionName: "Resize")
                }
            }
            if let o = single, case .arc(let c, let rx, let ry, let a0, let a1) = o.shape {
                numberRow("Start angle", value: a0) { v in state.updateSelected("Change Arc") { $0.shape = .arc(center: c, rx: rx, ry: ry, startAngle: v, endAngle: a1) } }
                numberRow("End angle", value: a1) { v in state.updateSelected("Change Arc") { $0.shape = .arc(center: c, rx: rx, ry: ry, startAngle: a0, endAngle: v) } }
            }
            if let o = single, case .circle(let c, let r) = o.shape {
                numberRow("Radius", value: r) { v in if v > 0 { state.updateSelected("Change Radius") { $0.shape = .circle(center: c, radius: v) } } }
            }
        }
    }

    private func textSection(_ o: DesignObject) -> some View {
        Section("Text") {
            if case .text(let t) = o.shape {
                TextField("Text", text: Binding(
                    get: { t.string },
                    set: { v in state.updateSelected("Edit Text") { if case .text(var tt) = $0.shape { tt.string = v; $0.shape = .text(tt) } } }
                ), axis: .vertical)
                .focused($textFieldFocused)
                Picker("Font", selection: Binding(
                    get: { t.fontFace },
                    set: { v in state.updateSelected("Change Font") { if case .text(var tt) = $0.shape { tt.fontFace = v; tt.rawLogFont = nil; $0.shape = .text(tt) } } }
                )) {
                    if !fontFamilies.contains(t.fontFace) {
                        Text("\(t.fontFace) (not installed)").tag(t.fontFace)
                    }
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Size")
                    Spacer()
                    TextField("", value: Binding(
                        get: { t.fontSize },
                        set: { v in if v > 0 { state.updateSelected("Change Size") { if case .text(var tt) = $0.shape { tt.fontSize = v; tt.rawLogFont = nil; tt.rawFontTail = nil; $0.shape = .text(tt) } } } }
                    ), format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    Text("mm").foregroundStyle(.secondary)
                }
                Toggle("Bold", isOn: Binding(get: { t.isBold }, set: { v in state.updateSelected("Bold") { if case .text(var tt) = $0.shape { tt.isBold = v; tt.rawLogFont = nil; $0.shape = .text(tt) } } }))
                Toggle("Italic", isOn: Binding(get: { t.isItalic }, set: { v in state.updateSelected("Italic") { if case .text(var tt) = $0.shape { tt.isItalic = v; tt.rawLogFont = nil; $0.shape = .text(tt) } } }))
                if !Renderer.fontFamilyIsInstalled(t.fontFace) {
                    Label("\(t.fontFace) isn't installed; shown in the system font.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    // Rows

    private func colorRow(_ title: String, color: RGB, set: @escaping (RGB) -> Void) -> some View {
        ColorPicker(title, selection: Binding(
            get: { color.color },
            set: { c in if let rgb = RGB(c) { set(rgb) } }
        ), supportsOpacity: false)
    }

    private func fillRow(fill: RGB?, set: @escaping (RGB?) -> Void) -> some View {
        HStack {
            Toggle("Fill", isOn: Binding(get: { fill != nil }, set: { on in set(on ? (fill ?? RGB(r: 220, g: 220, b: 220)) : nil) }))
            Spacer()
            if let f = fill {
                ColorPicker("", selection: Binding(get: { f.color }, set: { c in if let rgb = RGB(c) { set(rgb) } }), supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private func numberRow(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(get: { (value * 100).rounded() / 100 }, set: { set($0) }), format: .number)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
