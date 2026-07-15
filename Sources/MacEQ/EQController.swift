import Foundation
import MacEQCore
import SwiftUI

/// One graphic-EQ band: display label and peaking-filter center frequency.
struct EQBand {
    let label: String
    let frequency: Double
}

/// Which editing surface drives the DSP chain.
enum EQMode: String {
    case graphic
    case parametric
}

/// UI-facing state for the 10-band graphic EQ. Owns the audio engine, rebuilds
/// the DSP kernel on every change, persists settings, and mirrors status for
/// debugging. Main-actor: all mutations come from the UI or main-queue callbacks.
@MainActor
final class EQController: ObservableObject {
    static let bands: [EQBand] = [
        EQBand(label: "31", frequency: 31.5),
        EQBand(label: "63", frequency: 63),
        EQBand(label: "125", frequency: 125),
        EQBand(label: "250", frequency: 250),
        EQBand(label: "500", frequency: 500),
        EQBand(label: "1k", frequency: 1000),
        EQBand(label: "2k", frequency: 2000),
        EQBand(label: "4k", frequency: 4000),
        EQBand(label: "8k", frequency: 8000),
        EQBand(label: "16k", frequency: 16000),
    ]
    /// PRD choice for octave-band graphic EQ.
    static let bandQ = 2.2
    static let gainRange: ClosedRange<Double> = -12...12

    @Published var gains: [Double] {
        didSet { settingsChanged() }
    }
    @Published var manualPreampDB: Double {
        didSet { settingsChanged() }
    }
    @Published var autoPreampEnabled: Bool {
        didSet { settingsChanged() }
    }
    @Published var eqEnabled: Bool {
        didSet { settingsChanged() }
    }
    @Published var mode: EQMode {
        didSet { settingsChanged() }
    }
    @Published var parametricFilters: [FilterSpec] {
        didSet { settingsChanged() }
    }
    /// Last parse error from the config text editor, shown inline.
    @Published var configParseError: String?

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusSummary = "Not running"
    @Published private(set) var diagnosticLines: [String] = []
    @Published private(set) var effectivePreampDB: Double = 0

    private let engine = AudioTapEngine()
    /// Keeps recently replaced kernels alive so the audio thread's reference
    /// release is never the final one (final release may free memory, which is
    /// forbidden on the real-time thread).
    private var retiredKernels: [EQKernel] = []
    private var pollTimer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        let storedGains = defaults.array(forKey: "bandGains") as? [Double]
        gains = storedGains?.count == Self.bands.count
            ? storedGains!
            : Array(repeating: 0.0, count: Self.bands.count)
        manualPreampDB = defaults.object(forKey: "preampDB") as? Double ?? 0.0
        autoPreampEnabled = defaults.object(forKey: "autoPreampEnabled") as? Bool ?? true
        eqEnabled = defaults.object(forKey: "eqEnabled") as? Bool ?? true
        mode = EQMode(rawValue: defaults.string(forKey: "eqMode") ?? "") ?? .graphic
        // Parametric state persists in the native APO config.txt format.
        if let storedConfig = defaults.string(forKey: "parametricConfig"),
           let preset = try? parseAPOConfig(storedConfig) {
            parametricFilters = preset.filters
        } else {
            parametricFilters = []
        }

        engine.onDefaultOutputDeviceChanged = { [weak self] in
            self?.handleDeviceChange()
        }
    }

    func start() {
        errorMessage = nil
        do {
            try engine.start()
            isRunning = true
            rebuildKernel()
            startPolling()
        } catch {
            errorMessage = String(describing: error)
            engine.stop()
            isRunning = false
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        engine.kernelHolder.kernel = nil
        engine.stop()
        isRunning = false
        statusSummary = "Not running"
        diagnosticLines = []
    }

    func resetAllBands() {
        gains = Array(repeating: 0.0, count: Self.bands.count)
    }

    private func settingsChanged() {
        persist()
        rebuildKernel()
    }

    private func persist() {
        defaults.set(gains, forKey: "bandGains")
        defaults.set(manualPreampDB, forKey: "preampDB")
        defaults.set(autoPreampEnabled, forKey: "autoPreampEnabled")
        defaults.set(eqEnabled, forKey: "eqEnabled")
        defaults.set(mode.rawValue, forKey: "eqMode")
        defaults.set(
            serializeAPOConfig(EQPreset(preampDB: effectivePreampDB, filters: parametricFilters)),
            forKey: "parametricConfig"
        )
    }

    // MARK: - Parametric editing

    func addParametricBand() {
        parametricFilters.append(
            FilterSpec(type: .peaking, isEnabled: true, frequency: 1000, gainDB: 0, q: 1.0)
        )
    }

    func removeParametricBand(at index: Int) {
        guard parametricFilters.indices.contains(index) else { return }
        parametricFilters.remove(at: index)
    }

    /// The live APO config text for the editor tab.
    func currentConfigText() -> String {
        serializeAPOConfig(EQPreset(preampDB: effectivePreampDB, filters: parametricFilters))
    }

    /// Applies edited/pasted APO config text (also the AutoEQ import path).
    /// Sets `configParseError` instead of throwing so the editor can show it inline.
    func applyConfigText(_ text: String) {
        do {
            let preset = try parseAPOConfig(text)
            configParseError = nil
            autoPreampEnabled = false
            manualPreampDB = preset.preampDB
            parametricFilters = preset.filters
            mode = .parametric
        } catch let error as APOParseError {
            configParseError = error.description
        } catch {
            configParseError = String(describing: error)
        }
    }

    /// Builds a fresh kernel off the audio thread and swaps it in. nil = bypass.
    private func rebuildKernel() {
        guard isRunning, eqEnabled else {
            retire(engine.kernelHolder.kernel)
            engine.kernelHolder.kernel = nil
            effectivePreampDB = 0
            return
        }
        let sampleRate = engine.status?.sampleRate ?? 48000
        let cascade = activeCascade(sampleRate: sampleRate)
        let preamp = autoPreampEnabled ? autoPreampDB(of: cascade, sampleRate: sampleRate) : manualPreampDB
        effectivePreampDB = preamp
        guard let kernel = EQKernel(cascade: cascade, preampDB: preamp, sampleRate: sampleRate, maxChannels: 2) else {
            errorMessage = "EQKernel construction failed (bands: \(gains), preamp: \(preamp))"
            return
        }
        retire(engine.kernelHolder.kernel)
        engine.kernelHolder.kernel = kernel
    }

    /// The biquad cascade for the current mode. Never empty: an identity peaking
    /// section stands in when the parametric list has no enabled filters.
    func activeCascade(sampleRate: Double) -> [BiquadCoefficients] {
        switch mode {
        case .graphic:
            return zip(Self.bands, gains).map { band, gain in
                peakingCoefficients(sampleRate: sampleRate, frequency: band.frequency, q: Self.bandQ, gainDB: gain)
            }
        case .parametric:
            let enabled = parametricFilters.filter(\.isEnabled)
            guard !enabled.isEmpty else {
                return [peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 1.0, gainDB: 0)]
            }
            return enabled.map { coefficients(for: $0, sampleRate: sampleRate) }
        }
    }

    var currentSampleRate: Double {
        engine.status?.sampleRate ?? 48000
    }

    private func retire(_ kernel: EQKernel?) {
        guard let kernel else { return }
        retiredKernels.append(kernel)
        if retiredKernels.count > 8 {
            retiredKernels.removeFirst(retiredKernels.count - 8)
        }
    }

    /// Tears down and rebuilds the audio path on the new default output device.
    private func handleDeviceChange() {
        guard isRunning else { return }
        stop()
        start()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        guard let status = engine.status else { return }
        let stats = engine.stats
        let peakDB: Double = stats.lastPeak > 0 ? Double(20 * log10(stats.lastPeak)) : -120
        statusSummary = String(
            format: "%@ · %.0f kHz · peak %.1f dBFS",
            status.outputDeviceName,
            status.sampleRate / 1000,
            peakDB
        )
        diagnosticLines = [
            "Tap format: \(status.tapFormatDescription)",
            String(format: "IO buffer: %u frames (~%.1f ms)", status.bufferFrameSize, Double(status.bufferFrameSize) / status.sampleRate * 1000),
            "Callbacks: \(stats.callbackCount), silent streak: \(stats.consecutiveZeroBuffers)",
        ] + engine.diagnostics()
        writeStatusSnapshot()
    }

    /// Debug aid: mirrors live state to a file so the audio path can be inspected
    /// without reading the screen. Best-effort by design; remove after Milestone 1.
    private func writeStatusSnapshot() {
        let snapshot = """
        timestamp: \(Date())
        running: \(isRunning)
        eqEnabled: \(eqEnabled)
        gains: \(gains)
        preamp: \(effectivePreampDB) (auto: \(autoPreampEnabled))
        error: \(errorMessage ?? "none")
        status: \(statusSummary)
        \(diagnosticLines.joined(separator: "\n"))
        """
        try? snapshot.write(toFile: "/tmp/maceq-spike-status.txt", atomically: true, encoding: .utf8)
    }
}
