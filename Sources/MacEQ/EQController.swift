import AppKit
import CoreAudio
import Foundation
import MacEQCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// libsystem SPI: the PID of the app responsible for another PID (how Activity
/// Monitor groups helper processes under their app). Required to match browser
/// audio helpers against user-excluded apps; safe for Developer ID distribution.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

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

/// Everything a device remembers, keyed by its Core Audio UID.
/// The parametric chain is stored as APO config text (the native format).
struct DeviceProfile: Codable {
    var gains: [Double]
    var mode: String
    var parametricConfig: String
    var manualPreampDB: Double
    var autoPreampEnabled: Bool
    var eqEnabled: Bool
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
    @Published var limiterEnabled: Bool {
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
    @Published private(set) var spectrumDB: [Double] = []
    @Published private(set) var cpuPercent: Double = 0
    @Published var bufferFrames: Int {
        didSet {
            guard !isApplyingProfile else { return }
            defaults.set(bufferFrames, forKey: "bufferFrames")
            if isRunning {
                stop()
                start()
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isApplyingProfile else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = "Launch-at-login change failed: \(error)"
            }
        }
    }
    @Published var excludedBundleIDs: Set<String> {
        didSet {
            guard !isApplyingProfile else { return }
            defaults.set(Array(excludedBundleIDs).sorted(), forKey: "excludedBundleIDs")
            restartForExclusionChange()
        }
    }

    private let engine = AudioTapEngine()
    /// Keeps recently replaced kernels alive so the audio thread's reference
    /// release is never the final one (final release may free memory, which is
    /// forbidden on the real-time thread).
    private var retiredKernels: [EQKernel] = []
    private var pollTimer: Timer?
    private let defaults = UserDefaults.standard
    /// Suppresses persistence/kernel rebuilds while a device profile is being applied.
    private var isApplyingProfile = false
    /// UID of the device whose profile is currently loaded into the published state.
    private var activeProfileUID: String?

    init() {
        let storedGains = defaults.array(forKey: "bandGains") as? [Double]
        gains = storedGains?.count == Self.bands.count
            ? storedGains!
            : Array(repeating: 0.0, count: Self.bands.count)
        manualPreampDB = defaults.object(forKey: "preampDB") as? Double ?? 0.0
        autoPreampEnabled = defaults.object(forKey: "autoPreampEnabled") as? Bool ?? true
        eqEnabled = defaults.object(forKey: "eqEnabled") as? Bool ?? true
        mode = EQMode(rawValue: defaults.string(forKey: "eqMode") ?? "") ?? .graphic
        limiterEnabled = defaults.object(forKey: "limiterEnabled") as? Bool ?? true
        // Parametric state persists in the native APO config.txt format.
        if let storedConfig = defaults.string(forKey: "parametricConfig"),
           let preset = try? parseAPOConfig(storedConfig) {
            parametricFilters = preset.filters
        } else {
            parametricFilters = []
        }

        excludedBundleIDs = Set(defaults.stringArray(forKey: "excludedBundleIDs") ?? [])
        bufferFrames = defaults.object(forKey: "bufferFrames") as? Int ?? 0
        launchAtLogin = SMAppService.mainApp.status == .enabled

        engine.onDefaultOutputDeviceChanged = { [weak self] in
            self?.handleDeviceChange()
        }
        engine.onProcessListChanged = { [weak self] in
            self?.scheduleExclusionRecheck()
        }
    }

    // MARK: - Exclude list

    /// Core Audio process objects whose *responsible app* is excluded.
    ///
    /// Browser/Electron audio comes from helper processes (WebKit GPU, Chrome
    /// Helper) whose own bundle IDs never match the app the user excluded, so each
    /// audio process is attributed to the app responsible for it (the same mapping
    /// Activity Monitor uses) before checking the exclude set.
    private func resolveExcludedAudioProcesses() -> (objects: [AudioObjectID], pids: [pid_t]) {
        guard !excludedBundleIDs.isEmpty else { return ([], []) }
        var objects: [AudioObjectID] = []
        var pids: [pid_t] = []
        do {
            for object in try audioProcessObjectIDs() {
                let processPID = try pid(ofAudioProcess: object)
                guard processPID > 0 else { continue }
                let responsiblePID = responsibility_get_pid_responsible_for_pid(processPID)
                let bundleID = NSRunningApplication(processIdentifier: responsiblePID)?.bundleIdentifier
                    ?? NSRunningApplication(processIdentifier: processPID)?.bundleIdentifier
                if let bundleID, excludedBundleIDs.contains(bundleID) {
                    objects.append(object)
                    pids.append(processPID)
                }
            }
        } catch {
            errorMessage = "Exclude-list resolution failed: \(error)"
        }
        return (objects, pids)
    }

    private func restartForExclusionChange() {
        guard isRunning else { return }
        stop()
        start()
    }

    private var lastExcludedPIDs: [pid_t] = []
    private var exclusionRecheck: DispatchWorkItem?

    /// Core Audio's process list changed. If the resolved excluded process set
    /// differs from what the tap was built with, rebuild it (debounced — process
    /// churn is bursty and each rebuild briefly interrupts audio).
    private func scheduleExclusionRecheck() {
        guard isRunning, !excludedBundleIDs.isEmpty else { return }
        exclusionRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            let current = self.resolveExcludedAudioProcesses().pids.sorted()
            if current != self.lastExcludedPIDs {
                self.restartForExclusionChange()
            }
        }
        exclusionRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func start() {
        errorMessage = nil
        do {
            let excluded = resolveExcludedAudioProcesses()
            engine.excludedProcessObjects = excluded.objects
            lastExcludedPIDs = excluded.pids.sorted()
            engine.preferredBufferFrames = UInt32(max(bufferFrames, 0))
            try engine.start()
            isRunning = true
            loadProfileForCurrentDevice()
            rebuildKernel()
            startPolling()
        } catch {
            errorMessage = String(describing: error)
            engine.stop()
            isRunning = false
            writeStatusSnapshot()
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
        guard !isApplyingProfile else { return }
        persist()
        saveProfileForCurrentDevice()
        rebuildKernel()
    }

    // MARK: - Per-device profiles

    private func storedProfiles() -> [String: DeviceProfile] {
        guard let data = defaults.data(forKey: "deviceProfiles") else { return [:] }
        do {
            return try JSONDecoder().decode([String: DeviceProfile].self, from: data)
        } catch {
            // Corrupt store: surface it, keep running with empty profiles.
            errorMessage = "Failed to decode device profiles: \(error)"
            return [:]
        }
    }

    private func saveProfileForCurrentDevice() {
        guard let uid = engine.status?.outputDeviceUID else { return }
        var profiles = storedProfiles()
        profiles[uid] = DeviceProfile(
            gains: gains,
            mode: mode.rawValue,
            parametricConfig: serializeAPOConfig(EQPreset(preampDB: manualPreampDB, filters: parametricFilters)),
            manualPreampDB: manualPreampDB,
            autoPreampEnabled: autoPreampEnabled,
            eqEnabled: eqEnabled
        )
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: "deviceProfiles")
        } catch {
            errorMessage = "Failed to encode device profiles: \(error)"
        }
    }

    /// Applies the stored profile for the active output device, if any. Without a
    /// stored profile the current settings carry over (and become that device's
    /// profile on the next change).
    private func loadProfileForCurrentDevice() {
        guard let uid = engine.status?.outputDeviceUID, uid != activeProfileUID else { return }
        activeProfileUID = uid
        guard let profile = storedProfiles()[uid] else { return }
        isApplyingProfile = true
        defer { isApplyingProfile = false }
        if profile.gains.count == Self.bands.count {
            gains = profile.gains
        }
        mode = EQMode(rawValue: profile.mode) ?? .graphic
        manualPreampDB = profile.manualPreampDB
        autoPreampEnabled = profile.autoPreampEnabled
        eqEnabled = profile.eqEnabled
        if let preset = try? parseAPOConfig(profile.parametricConfig) {
            parametricFilters = preset.filters
        }
    }

    private func persist() {
        defaults.set(gains, forKey: "bandGains")
        defaults.set(manualPreampDB, forKey: "preampDB")
        defaults.set(autoPreampEnabled, forKey: "autoPreampEnabled")
        defaults.set(eqEnabled, forKey: "eqEnabled")
        defaults.set(mode.rawValue, forKey: "eqMode")
        defaults.set(limiterEnabled, forKey: "limiterEnabled")
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

    /// Imports an APO/AutoEQ preset file (ParametricEQ.txt, config.txt) chosen
    /// in an open panel. Parse errors surface via configParseError + errorMessage.
    func importPresetFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Equalizer APO / AutoEQ preset (.txt)"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            applyConfigText(text)
            if let parseError = configParseError {
                errorMessage = "Import failed — \(parseError)"
            }
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error)"
        }
    }

    /// Exports the current parametric chain as an APO config.txt file.
    func exportPresetToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MacEQ Preset.txt"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try currentConfigText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error)"
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
        guard let kernel = EQKernel(
            cascade: cascade, preampDB: preamp, sampleRate: sampleRate, maxChannels: 2,
            limiterEnabled: limiterEnabled
        ) else {
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

    // MARK: - Spectrum display

    static let spectrumBands = logSpacedFrequencies(from: 20, to: 20000, count: 48)
    private let analyzer = SpectrumAnalyzer(fftSize: 2048)
    private var spectrumTimer: Timer?

    /// ~30 fps spectrum updates; runs only while a curve view is visible.
    func startSpectrum() {
        guard spectrumTimer == nil else { return }
        spectrumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let analyzer = self.analyzer, self.isRunning else { return }
                self.spectrumDB = analyzer.bandMagnitudesDB(
                    samples: self.engine.captureRing.latest(analyzer.fftSize),
                    sampleRate: self.currentSampleRate,
                    bandFrequencies: Self.spectrumBands
                )
            }
        }
    }

    func stopSpectrum() {
        spectrumTimer?.invalidate()
        spectrumTimer = nil
        spectrumDB = []
    }

    // MARK: - CPU usage

    private var lastCPUTime: Double = 0
    private var lastCPUSample: Date?

    /// Process CPU%: rusage user+system delta over wall-clock delta.
    private func updateCPUUsage() {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = Date()
        if let lastSample = lastCPUSample {
            let wall = now.timeIntervalSince(lastSample)
            if wall > 0 {
                cpuPercent = max((seconds - lastCPUTime) / wall * 100, 0)
            }
        }
        lastCPUTime = seconds
        lastCPUSample = now
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
        updateCPUUsage()
        let stats = engine.stats
        let peakDB: Double = stats.lastPeak > 0 ? Double(20 * log10(stats.lastPeak)) : -120
        statusSummary = String(
            format: "%@ · %.0f kHz · %.1f ms · CPU %.1f%%",
            status.outputDeviceName,
            status.sampleRate / 1000,
            Double(status.bufferFrameSize) / status.sampleRate * 1000,
            cpuPercent
        )
        diagnosticLines = [
            "Tap format: \(status.tapFormatDescription)",
            String(format: "IO buffer: %u frames (~%.1f ms)", status.bufferFrameSize, Double(status.bufferFrameSize) / status.sampleRate * 1000),
            String(format: "Peak: %.1f dBFS", peakDB),
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
        let processTable = audioProcessTable().joined(separator: "\n")
        try? (snapshot + "\nexcluded: \(excludedBundleIDs.sorted())\naudio processes:\n" + processTable)
            .write(toFile: "/tmp/maceq-spike-status.txt", atomically: true, encoding: .utf8)
    }

    /// Debug: how each live audio process attributes to an app, for diagnosing
    /// exclude-list matching.
    private func audioProcessTable() -> [String] {
        guard let objects = try? audioProcessObjectIDs() else { return ["<process list unavailable>"] }
        return objects.compactMap { object in
            guard let processPID = try? pid(ofAudioProcess: object) else { return nil }
            let coreBundle = (try? bundleID(ofAudioProcess: object)) ?? "-"
            let directBundle = NSRunningApplication(processIdentifier: processPID)?.bundleIdentifier ?? "-"
            let responsiblePID = responsibility_get_pid_responsible_for_pid(processPID)
            let responsibleBundle = NSRunningApplication(processIdentifier: responsiblePID)?.bundleIdentifier ?? "-"
            return "  pid=\(processPID) core=\(coreBundle) direct=\(directBundle) responsible(\(responsiblePID))=\(responsibleBundle)"
        }
    }
}
