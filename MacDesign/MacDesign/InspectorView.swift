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
            strokeRows
            fillRows
            Picker("Layer", selection: $state.activeLayer) {
                ForEach(document.doc.layers) { Text($0.name).tag($0.index) }
            }
            Picker("Font", selection: $state.newTextFace) {
                if !fontFamilies.contains(state.newTextFace) { Text(state.newTextFace).tag(state.newTextFace) }
                ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Text height")
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
            alignRow
        }
    }

    /// Six alignment buttons; one object aligns to the page, several to each other.
    private var alignRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(state.alignsToPage ? "Align to page" : "Align")
                Spacer()
                ForEach(EditorState.AlignEdge.allCases, id: \.self) { edge in
                    Button { state.align(edge) } label: {
                        Image(systemName: edge.systemImage)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(edge.title)
                }
            }
            if selected.count >= 3 {
                HStack(spacing: 4) {
                    Text("Distribute")
                    Spacer()
                    Button { state.distribute(horizontally: true) } label: { Image(systemName: "distribute.horizontal.center").frame(width: 18, height: 18) }
                        .buttonStyle(.borderless).help("Equal horizontal gaps")
                    Button { state.distribute(horizontally: false) } label: { Image(systemName: "distribute.vertical.center").frame(width: 18, height: 18) }
                        .buttonStyle(.borderless).help("Equal vertical gaps")
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            strokeRows
            fillRows
        }
    }

    /// Stroke on/off, colour, fine or thick (2D Design's two kinds), width and line pattern.
    /// With nothing selected these edit the defaults for new shapes.
    private var strokeRows: some View {
        let style = state.inspectedStyle
        let isFine = style.strokeWidth <= 0
        return Group {
            HStack {
                Toggle("Stroke", isOn: Binding(get: { style.isStroked }, set: { state.setStrokeEnabled($0) }))
                Spacer()
                if style.isStroked {
                    ColorPicker("", selection: Binding(get: { style.effectiveStroke.color },
                                                       set: { c in if let rgb = RGB(c) { state.setStroke(rgb) } }), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            if style.isStroked {
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
                Picker("Thickness", selection: Binding(get: { isFine ? 0 : 1 },
                                                       set: { state.setStrokeWidth($0 == 0 ? 0 : max(style.strokeWidth, 0.5)) })) {
                    Text("Fine").tag(0)
                    Text("Thick").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Fine lines have no thickness: a plotter or laser follows the path. Thick lines have a printed width.")
                if !isFine {
                    HStack {
                        Text("Width")
                        Spacer()
                        TextField("", value: Binding(get: { style.strokeWidth }, set: { state.setStrokeWidth(max(0.05, $0)) }), format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
                Picker("Pattern", selection: Binding(get: { style.lineType }, set: { state.setLineType($0) })) {
                    ForEach(LineType.allCases.filter { $0 != .none }, id: \.self) { Text($0.name).tag($0) }
                }
            }
        }
    }

    /// Fill on/off and colour. Hatch, gradient, texture and pattern fills from a file are kept
    /// while the toggle is on; switching off and on again, or picking a colour, makes them solid.
    private var fillRows: some View {
        let style = state.inspectedStyle
        return Group {
            HStack {
                Toggle("Fill", isOn: Binding(get: { style.isFilled },
                                             set: { on in state.setFill(on ? .solid(style.fill.representativeColor ?? RGB(r: 220, g: 220, b: 220)) : .none) }))
                Spacer()
                if style.isFilled {
                    ColorPicker("", selection: Binding(get: { (style.fill.representativeColor ?? .white).color },
                                                       set: { c in if let rgb = RGB(c) { state.setFill(rgb) } }), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            if style.fill.isPreservedKind {
                LabeledContent("Fill type", value: style.fill.name)
                    .help("Kept as it was in the file. Choosing a fill colour replaces it.")
            }
        }
    }

    private var swatches: [RGB] {
        [.black, .red, .blue, .green, RGB(r: 255, g: 0, b: 255), RGB(r: 255, g: 128, b: 0), RGB(r: 0, g: 160, b: 255), RGB(r: 128, g: 128, b: 128)]
    }

    private var geometrySection: some View {
        Section("Transform") {
            TransformPanel(state: state)
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
                    Text("Height")
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
