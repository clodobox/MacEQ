import AppKit
import SwiftUI

/// Checkbox list of running apps to exclude from the tap. Excluded apps play
/// directly to the hardware, unprocessed and unmuted — for DAWs, Zoom, and other
/// software that manages its own audio.
struct ExcludedAppsView: View {
    @ObservedObject var controller: EQController
    @State private var runningApps: [RunningApp] = []

    struct RunningApp: Identifiable {
        let id: String  // bundle ID
        let name: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Excluded apps bypass MacEQ entirely: their audio is not equalized and plays directly to the output device. Use for DAWs, conferencing, and pro-audio tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(runningApps) { app in
                Toggle(app.name, isOn: exclusionBinding(for: app.id))
                    .toggleStyle(.checkbox)
            }
            .listStyle(.bordered)

            HStack {
                Button("Refresh") { refresh() }
                    .controlSize(.small)
                Spacer()
                Text("\(controller.excludedBundleIDs.count) excluded")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 340, height: 400)
        .onAppear { refresh() }
    }

    private func exclusionBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { controller.excludedBundleIDs.contains(bundleID) },
            set: { excluded in
                if excluded {
                    controller.excludedBundleIDs.insert(bundleID)
                } else {
                    controller.excludedBundleIDs.remove(bundleID)
                }
            }
        )
    }

    private func refresh() {
        var apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let bundleID = app.bundleIdentifier, bundleID != "com.jatingrewal.maceq" else { return nil }
                return RunningApp(id: bundleID, name: app.localizedName ?? bundleID)
            }
        // Keep excluded-but-not-running apps visible so they can be un-excluded.
        let runningIDs = Set(apps.map(\.id))
        for bundleID in controller.excludedBundleIDs where !runningIDs.contains(bundleID) {
            apps.append(RunningApp(id: bundleID, name: "\(bundleID) (not running)"))
        }
        runningApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
