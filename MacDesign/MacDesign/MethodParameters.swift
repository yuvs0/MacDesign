import SwiftUI
import Combine
import TSDKit

/// The numbers a drawing method needs: shown in a sheet when the method is picked, and kept
/// in the inspector's New Shapes section so they can be changed afterwards.
struct MethodParameterFields: View {
    @ObservedObject var state: EditorState
    let method: DrawMethod

    var body: some View {
        switch method {
        case .rectSized:
            numberRow("Width", $state.rectSize.width, unit: "mm")
            numberRow("Height", $state.rectSize.height, unit: "mm")
        case .lineLength:
            numberRow("Length", $state.lineLength, unit: "mm")
        case .lineAngle:
            numberRow("Angle", $state.lineAngle, unit: "°")
        case .polygon:
            Stepper("Sides: \(state.polygonSides)", value: $state.polygonSides, in: 3...64)
        case .star:
            Stepper("Points: \(state.starPoints)", value: $state.starPoints, in: 3...64)
            numberRow("Inner radius", Binding(get: { (state.starInnerRatio * 100).rounded() }, set: { state.starInnerRatio = $0 / 100 }), unit: "%")
        default:
            EmptyView()
        }
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

/// Asks for a method's numbers as soon as it's picked. They stay editable in the inspector.
struct MethodParametersSheet: View {
    @ObservedObject var state: EditorState
    let method: DrawMethod

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(method.title).font(.headline)
                Spacer()
                Button("Done") { state.parameterRequest = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Form {
                Section {
                    MethodParameterFields(state: state, method: method)
                } footer: {
                    Text("\(method.hint). You can change these later under New Shapes in the inspector.")
                }
            }
            .formStyle(.grouped)
        }
        #if os(macOS)
        .frame(width: 360, height: 260)
        #else
        .presentationDetents([.medium])
        #endif
    }
}
