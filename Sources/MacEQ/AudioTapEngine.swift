import CoreAudio
import Foundation

/// Stats written by the real-time IO thread and polled by the UI.
///
/// Real-time safety note: the IO thread does plain word-sized stores into these
/// fields and the UI timer reads them. On arm64 aligned 64-bit loads/stores do
/// not tear, and stale-by-one-callback values are harmless for a status display,
/// so no locking is used (locks are forbidden on the audio thread).
final class IOStats {
    var callbackCount: UInt64 = 0
    var framesProcessed: UInt64 = 0
    var lastPeakBits: UInt32 = 0
    var lastRMSBits: UInt32 = 0
    var consecutiveZeroBuffers: UInt64 = 0

    var lastPeak: Float { Float(bitPattern: lastPeakBits) }
    var lastRMS: Float { Float(bitPattern: lastRMSBits) }
}

/// Debug instrumentation for Milestone 0: captures the buffer layout seen by the
/// first IO callback, and a test-tone switch that writes a sine directly to the
/// output buffers (bypassing tap input) to isolate output-path failures from
/// tap-input failures. Same word-sized-store rationale as IOStats.
final class DebugProbe {
    var layoutCaptured: Bool = false
    var inputBufferCount: UInt32 = 0
    var outputBufferCount: UInt32 = 0
    var inputChannels: UInt32 = 0
    var inputByteSize: UInt32 = 0
    var outputChannels: UInt32 = 0
    var outputByteSize: UInt32 = 0
    /// First 8 raw Float samples of the first input buffer, refreshed every callback.
    let firstSamples = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    /// Largest absolute sample value seen since start.
    var maxSampleEverBits: UInt32 = 0

    /// UI writes, audio thread reads: replace passthrough with a 440 Hz sine at -20 dBFS.
    var toneEnabled: Bool = false
    /// Callbacks handled in tone mode, proving the IOProc stays alive there.
    var toneCallbackCount: UInt64 = 0
    /// Sine phase, touched only by the audio thread.
    var tonePhase: Double = 0

    init() {
        firstSamples.initialize(repeating: 0, count: 8)
    }

    deinit {
        firstSamples.deallocate()
    }
}

/// Snapshot of the running audio path, for display.
struct EngineStatus {
    let outputDeviceName: String
    let sampleRate: Double
    let tapFormatDescription: String
    let bufferFrameSize: UInt32
}

/// Milestone 0 engine: muted global process tap + private aggregate device with a
/// straight passthrough IOProc. No DSP yet — the goal is to prove the audio path.
///
/// Interfaces Core Audio (external system), hence a class managing lifecycle state.
final class AudioTapEngine {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.jatingrewal.maceq.io", qos: .userInteractive)

    let stats = IOStats()
    let probe = DebugProbe()
    private(set) var status: EngineStatus?

    var isRunning: Bool { ioProcID != nil }

    /// Builds the full path: tap -> private aggregate (real output as main sub-device
    /// + tap in the tap list) -> passthrough IOProc -> start.
    func start() throws {
        precondition(!isRunning, "AudioTapEngine.start() called while already running")

        // 1. Muted global tap: captures the entire system mix, silences the original
        //    so audio is heard exactly once (through our IOProc's output writes).
        //    Our own process MUST be excluded: a muted global tap that includes us
        //    mutes our EQ'd playback and feeds it back into the tap input.
        //    Do not touch isExclusive afterwards.
        let selfProcessObject = try processObjectID(forPID: getpid())
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [selfProcessObject]
        )
        tapDescription.name = "MacEQ System Tap"
        tapDescription.muteBehavior = .muted
        tapDescription.isPrivate = true

        try checkOSStatus(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            "AudioHardwareCreateProcessTap"
        )

        do {
            let outputDevice = try defaultOutputDeviceID()
            let outputUID = try deviceUID(of: outputDevice)
            let outputName = try deviceName(of: outputDevice)
            let sampleRate = try nominalSampleRate(of: outputDevice)

            // 2. Private aggregate: the real output device anchors the clock and
            //    receives our output; the tap feeds the input side. TapAutoStart is
            //    required or the tap delivers zero samples.
            let aggregateUID = UUID().uuidString
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacEQ Aggregate",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            try checkOSStatus(
                AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                "AudioHardwareCreateAggregateDevice"
            )

            let tapFormat = try tapStreamFormat(of: tapID)
            let bufferFrames = try bufferFrameSize(of: aggregateID)

            // 3. Passthrough IOProc on the aggregate. Must stay real-time safe:
            //    no allocation, no locks, no Objective-C/Swift runtime calls that lock.
            let stats = self.stats
            let probe = self.probe
            try checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                    _, inInputData, _, outOutputData, _ in
                    if probe.toneEnabled {
                        writeTestTone(output: outOutputData, sampleRate: sampleRate, probe: probe)
                    } else {
                        passthrough(input: inInputData, output: outOutputData, stats: stats, probe: probe)
                    }
                },
                "AudioDeviceCreateIOProcIDWithBlock"
            )

            guard let ioProcID else {
                throw CoreAudioError(call: "AudioDeviceCreateIOProcIDWithBlock returned nil proc ID", status: noErr)
            }
            try checkOSStatus(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")

            status = EngineStatus(
                outputDeviceName: outputName,
                sampleRate: sampleRate,
                tapFormatDescription: describe(format: tapFormat),
                bufferFrameSize: bufferFrames
            )
        } catch {
            // Unwind anything built before the failure so a retry starts clean.
            stop()
            throw error
        }
    }

    /// Introspects the live aggregate: which sub-devices actually activated, whether
    /// the aggregate exposes an output stream, and whether IO is really running.
    /// Any error is returned as a line rather than thrown — this is a diagnostic view.
    func diagnostics() -> [String] {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return [] }
        var lines: [String] = []
        do {
            let subDeviceIDs = try activeSubDeviceIDs(of: aggregateID)
            let names = try subDeviceIDs.map { try deviceName(of: $0) }
            lines.append("Active sub-devices: \(names.isEmpty ? "NONE" : names.joined(separator: ", "))")
            lines.append("Aggregate output streams: \(try outputStreamCount(of: aggregateID))")
            lines.append("Aggregate running: \(try deviceIsRunning(aggregateID))")
        } catch {
            lines.append("Diagnostics failed: \(error)")
        }
        return lines
    }

    /// Teardown in the required order: stop -> destroy IOProc -> destroy aggregate -> destroy tap.
    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        status = nil
    }

    deinit {
        stop()
    }
}

/// Copies tapped input buffers verbatim to the output buffers and updates stats.
/// Runs on the real-time audio thread — free function, no captures beyond `stats`.
private func passthrough(
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    stats: IOStats,
    probe: DebugProbe
) {
    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

    if !probe.layoutCaptured {
        probe.inputBufferCount = UInt32(inputBuffers.count)
        probe.outputBufferCount = UInt32(outputBuffers.count)
        if let first = inputBuffers.first {
            probe.inputChannels = first.mNumberChannels
            probe.inputByteSize = first.mDataByteSize
        }
        if let first = outputBuffers.first {
            probe.outputChannels = first.mNumberChannels
            probe.outputByteSize = first.mDataByteSize
        }
        probe.layoutCaptured = true
    }

    if let first = inputBuffers.first, let data = first.mData {
        let samples = data.assumingMemoryBound(to: Float.self)
        let available = min(8, Int(first.mDataByteSize) / MemoryLayout<Float>.size)
        for i in 0..<available {
            probe.firstSamples[i] = samples[i]
        }
    }

    var peak: Float = 0
    var sumOfSquares: Float = 0
    var sampleCount = 0
    var framesThisCallback: UInt64 = 0

    for bufferIndex in 0..<min(inputBuffers.count, outputBuffers.count) {
        let inBuffer = inputBuffers[bufferIndex]
        let outBuffer = outputBuffers[bufferIndex]
        guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

        let byteCount = Int(min(inBuffer.mDataByteSize, outBuffer.mDataByteSize))
        memcpy(outData, inData, byteCount)

        let samples = inData.assumingMemoryBound(to: Float.self)
        let count = byteCount / MemoryLayout<Float>.size
        for i in 0..<count {
            let value = abs(samples[i])
            if value > peak { peak = value }
            sumOfSquares += value * value
        }
        sampleCount += count
        let channels = max(inBuffer.mNumberChannels, 1)
        framesThisCallback += UInt64(count) / UInt64(channels)
    }

    if peak > Float(bitPattern: probe.maxSampleEverBits) {
        probe.maxSampleEverBits = peak.bitPattern
    }

    stats.callbackCount &+= 1
    stats.framesProcessed &+= framesThisCallback
    stats.lastPeakBits = peak.bitPattern
    stats.lastRMSBits = (sampleCount > 0 ? (sumOfSquares / Float(sampleCount)).squareRoot() : 0).bitPattern
    if peak == 0 {
        stats.consecutiveZeroBuffers &+= 1
    } else {
        stats.consecutiveZeroBuffers = 0
    }
}

/// Debug: fills every output buffer with a 440 Hz sine at -20 dBFS, ignoring input.
/// Isolates the aggregate -> output-device path from the tap -> input path.
private func writeTestTone(
    output: UnsafeMutablePointer<AudioBufferList>,
    sampleRate: Double,
    probe: DebugProbe
) {
    probe.toneCallbackCount &+= 1
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    let phaseIncrement = 2.0 * Double.pi * 440.0 / sampleRate
    let amplitude: Float = 0.1

    for buffer in outputBuffers {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let channels = Int(max(buffer.mNumberChannels, 1))
        var phase = probe.tonePhase
        var index = 0
        while index + channels <= sampleCount {
            let value = amplitude * Float(sin(phase))
            for channel in 0..<channels {
                samples[index + channel] = value
            }
            phase += phaseIncrement
            index += channels
        }
        probe.tonePhase = phase.truncatingRemainder(dividingBy: 2.0 * Double.pi)
    }
}

/// Current IO buffer size in frames, which dominates round-trip latency.
private func bufferFrameSize(of deviceID: AudioDeviceID) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var frames: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames),
        "AudioObjectGetPropertyData(kAudioDevicePropertyBufferFrameSize, device \(deviceID))"
    )
    return frames
}

private func describe(format: AudioStreamBasicDescription) -> String {
    let interleaving = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        ? "non-interleaved" : "interleaved"
    return String(
        format: "%.0f Hz, %u ch, %@, Float32: %@",
        format.mSampleRate,
        format.mChannelsPerFrame,
        interleaving,
        (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "yes" : "NO"
    )
}
