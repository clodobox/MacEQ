import SwiftUI

/// Tiny window that names and saves the current tuning as a preset.
/// Saving with an existing name replaces that preset.
struct PresetNameView: View {
    @ObservedObject var controller: EQController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Save Preset")
                .font(.headline)
            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if controller.namedPresets.contains(where: { $0.name == trimmedName }) {
                Text("Replaces the existing “\(trimmedName)” preset.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 260)
        .onAppear { name = "" }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        controller.saveCurrentAsPreset(named: trimmedName)
        dismiss()
    }
}
