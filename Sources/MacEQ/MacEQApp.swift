import SwiftUI

/// Starts the audio engine at launch (before the menu-bar popover is ever opened)
/// so the permission prompt appears immediately and EQ is active from login.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let controller = EQController()
    private var hotkeyManager: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.controller.start()
        // Carbon delivers the hotkey on the main thread; hop into the actor
        // explicitly since the C callback carries no isolation.
        hotkeyManager = HotkeyManager {
            DispatchQueue.main.async {
                AppDelegate.controller.eqEnabled.toggle()
            }
        }
    }
}

@main
struct MacEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("MacEQ", systemImage: "slider.vertical.3") {
            EQPopoverView(controller: AppDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window("Excluded Apps", id: "excluded-apps") {
            ExcludedAppsView(controller: AppDelegate.controller)
        }
        .windowResizability(.contentSize)
    }
}

struct EQPopoverView: View {
    @ObservedObject var controller: EQController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Picker("", selection: $controller.mode) {
                Text("Graphic").tag(EQMode.graphic)
                Text("Parametric").tag(EQMode.parametric)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Group {
                if controller.mode == .graphic {
                    bandSliders
                } else {
                    ParametricView(controller: controller)
                }
                preampRow
            }
            .opacity(controller.eqEnabled ? 1 : 0.4)
            .disabled(!controller.eqEnabled)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 400)
    }

    private var header: some View {
        HStack {
            Text("MacEQ")
                .font(.headline)
            Spacer()
            Toggle("", isOn: $controller.eqEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Enable or bypass the equalizer (⌥⌘E anywhere)")
            Menu {
                Button("Reset All Bands") { controller.resetAllBands() }
                Toggle("Safety Limiter", isOn: $controller.limiterEnabled)
                Toggle("Launch at Login", isOn: $controller.launchAtLogin)
                Picker("Buffer Size", selection: $controller.bufferFrames) {
                    Text("Device Default").tag(0)
                    Text("128 frames (lowest latency)").tag(128)
                    Text("256 frames").tag(256)
                    Text("512 frames").tag(512)
                    Text("1024 frames (safest)").tag(1024)
                }
                Button("Excluded Apps…") {
                    openWindow(id: "excluded-apps")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Divider()
                if let irName = controller.impulseResponseName {
                    Toggle("Convolution (\(irName))", isOn: $controller.convolutionEnabled)
                    Button("Replace Impulse Response…") { controller.chooseImpulseResponse() }
                    Button("Clear Impulse Response") { controller.clearImpulseResponse() }
                } else {
                    Button("Load Impulse Response…") { controller.chooseImpulseResponse() }
                }
                Divider()
                Button("Import Preset…") { controller.importPresetFromFile() }
                Button("Export Preset…") { controller.exportPresetToFile() }
                Divider()
                if controller.isRunning {
                    Button("Stop Audio Engine") { controller.stop() }
                } else {
                    Button("Start Audio Engine") { controller.start() }
                }
                Divider()
                Button("Quit MacEQ") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var bandSliders: some View {
        HStack(alignment: .top, spacing: 6) {
            dbScale
            ForEach(Array(EQController.bands.enumerated()), id: \.offset) { index, band in
                VStack(spacing: 6) {
                    VerticalSlider(
                        value: $controller.gains[index],
                        range: EQController.gainRange
                    )
                    .frame(height: 140)
                    Text(band.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(gainLabel(controller.gains[index]))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var dbScale: some View {
        VStack {
            Text("+12")
            Spacer()
            Text("0")
            Spacer()
            Text("−12")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(height: 140)
    }

    private var preampRow: some View {
        HStack(spacing: 10) {
            Text("Preamp")
                .font(.caption)
            Slider(
                value: $controller.manualPreampDB,
                in: EQController.gainRange
            )
            .controlSize(.small)
            .disabled(controller.autoPreampEnabled)
            Text(String(format: "%+.1f dB", controller.effectivePreampDB))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Toggle("Auto", isOn: $controller.autoPreampEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Automatically lower gain to prevent clipping from boosted bands")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(controller.statusSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.diagnosticLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Diagnostics")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func gainLabel(_ gain: Double) -> String {
        gain == 0 ? "0" : String(format: "%+.0f", gain)
    }
}

/// Center-zero vertical slider: fill grows from the middle, gradient accent,
/// double-click resets to 0, drag snaps to 0.5 dB.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let trackWidth: CGFloat = 5
    private let knobSize: CGFloat = 13
    private static let accent = LinearGradient(
        colors: [Color.purple, Color.blue],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let knobY = yPosition(for: value, height: height)
            let centerY = height / 2

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: trackWidth)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Self.accent)
                    .frame(width: trackWidth)
                    .frame(height: abs(centerY - knobY))
                    .offset(y: min(knobY, centerY))
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: trackWidth + 6, height: 1)
                    .offset(y: centerY)
                    .frame(maxWidth: .infinity)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(y: knobY - knobSize / 2)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = valueFor(y: gesture.location.y, height: height)
                    }
            )
            .onTapGesture(count: 2) {
                value = 0
            }
        }
    }

    private func yPosition(for value: Double, height: CGFloat) -> CGFloat {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return height * CGFloat(1 - fraction)
    }

    private func valueFor(y: CGFloat, height: CGFloat) -> Double {
        let fraction = 1 - Double(min(max(y, 0), height) / height)
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        return (raw * 2).rounded() / 2
    }
}
