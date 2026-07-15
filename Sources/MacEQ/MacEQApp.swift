import SwiftUI

/// Milestone 0 UI: a single status window to start/stop the passthrough and watch
/// live stats. This is deliberately not a menu-bar app yet — a visible window makes
/// the permission prompt and the go/no-go checks easy to observe.
@main
struct MacEQApp: App {
    var body: some Scene {
        WindowGroup("MacEQ — Milestone 0 Spike") {
            SpikeView()
                .frame(minWidth: 420, minHeight: 320)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class SpikeViewModel: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var errorMessage: String?
    @Published var statusLines: [String] = []
    @Published var callbackCount: UInt64 = 0
    @Published var framesProcessed: UInt64 = 0
    @Published var peakDB: Float = -Float.infinity
    @Published var rmsDB: Float = -Float.infinity
    @Published var zeroBufferStreak: UInt64 = 0
    @Published var toneEnabled: Bool = false {
        didSet { engine.probe.toneEnabled = toneEnabled }
    }
    @Published var probeLines: [String] = []

    private let engine = AudioTapEngine()
    private var pollTimer: Timer?

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        errorMessage = nil
        do {
            try engine.start()
            guard let status = engine.status else {
                throw CoreAudioError(call: "engine started but reported no status", status: noErr)
            }
            let latencyMS = Double(status.bufferFrameSize) / status.sampleRate * 1000
            statusLines = [
                "Output device: \(status.outputDeviceName)",
                "Sample rate: \(Int(status.sampleRate)) Hz",
                "Tap format: \(status.tapFormatDescription)",
                String(format: "IO buffer: %u frames (~%.1f ms per callback)", status.bufferFrameSize, latencyMS),
            ]
            isRunning = true
            startPolling()
        } catch {
            errorMessage = String(describing: error)
            engine.stop()
        }
    }

    private func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        engine.stop()
        isRunning = false
        statusLines = []
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let stats = self.engine.stats
                self.callbackCount = stats.callbackCount
                self.framesProcessed = stats.framesProcessed
                self.peakDB = amplitudeToDB(stats.lastPeak)
                self.rmsDB = amplitudeToDB(stats.lastRMS)
                self.zeroBufferStreak = stats.consecutiveZeroBuffers

                let probe = self.engine.probe
                if probe.layoutCaptured {
                    let samples = (0..<8)
                        .map { String(format: "%.4f", probe.firstSamples[$0]) }
                        .joined(separator: " ")
                    self.probeLines = [
                        "Input buffers: \(probe.inputBufferCount) (ch \(probe.inputChannels), \(probe.inputByteSize) B)",
                        "Output buffers: \(probe.outputBufferCount) (ch \(probe.outputChannels), \(probe.outputByteSize) B)",
                        "Live input samples: \(samples)",
                        String(format: "Max sample ever: %.4f", Float(bitPattern: probe.maxSampleEverBits)),
                        "Tone-mode callbacks: \(probe.toneCallbackCount)",
                    ] + self.engine.diagnostics()
                }
                self.writeStatusSnapshot()
            }
        }
    }
}

extension SpikeViewModel {
    /// Debug aid for Milestone 0: mirrors the window's live state to a file so the
    /// audio path can be inspected without reading the screen.
    func writeStatusSnapshot() {
        let snapshot = """
        timestamp: \(Date())
        running: \(isRunning)
        toneEnabled: \(toneEnabled)
        error: \(errorMessage ?? "none")
        \(statusLines.joined(separator: "\n"))
        callbacks: \(callbackCount)
        frames: \(framesProcessed)
        peakDB: \(peakDB)
        rmsDB: \(rmsDB)
        zeroBufferStreak: \(zeroBufferStreak)
        \(probeLines.joined(separator: "\n"))
        """
        try? snapshot.write(
            toFile: "/tmp/maceq-spike-status.txt",
            atomically: true,
            encoding: .utf8
        )
    }
}

private func amplitudeToDB(_ amplitude: Float) -> Float {
    amplitude > 0 ? 20 * log10(amplitude) : -Float.infinity
}

struct SpikeView: View {
    @StateObject private var model = SpikeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Milestone 0: tap → aggregate → passthrough")
                .font(.headline)

            Button(model.isRunning ? "Stop passthrough" : "Start passthrough") {
                model.toggle()
            }
            .controlSize(.large)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if model.isRunning {
                ForEach(model.statusLines, id: \.self) { line in
                    Text(line).font(.system(.body, design: .monospaced))
                }
                Divider()
                Toggle("Debug: play 440 Hz test tone (bypasses tap input)", isOn: $model.toneEnabled)

                Group {
                    Text("IO callbacks: \(model.callbackCount)")
                    Text("Frames processed: \(model.framesProcessed)")
                    Text(String(format: "Peak: %.1f dBFS   RMS: %.1f dBFS", model.peakDB, model.rmsDB))
                    Text("Consecutive silent callbacks: \(model.zeroBufferStreak)")
                    ForEach(model.probeLines, id: \.self) { line in
                        Text(line)
                    }
                }
                .font(.system(.body, design: .monospaced))

                Text("Play music now. Pass criteria: you hear it once (not doubled), no glitches, and Peak/RMS move with the audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Click Start, grant the system-audio permission when prompted, then play audio in any app. The purple recording indicator in the menu bar is expected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }
}
