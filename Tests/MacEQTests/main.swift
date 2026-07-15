import Foundation
import MacEQCore

// Minimal test runner: the Command Line Tools toolchain ships neither XCTest nor
// swift-testing, so tests are a plain executable. Run with: swift run maceq-tests
// Exits 1 if any expectation fails.

var failureCount = 0
var expectationCount = 0

func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    expectationCount += 1
    if !condition {
        failureCount += 1
        let fileName = (file as NSString).lastPathComponent
        print("FAIL \(fileName):\(line): \(message)")
    }
}

func expectClose(
    _ actual: Double, _ expected: Double, tolerance: Double, _ label: String,
    file: String = #file, line: Int = #line
) {
    expect(
        abs(actual - expected) < tolerance,
        "\(label): \(actual) != \(expected) (tolerance \(tolerance))",
        file: file, line: line
    )
}

func expectCoefficients(
    _ actual: BiquadCoefficients, _ expected: [Double],
    file: String = #file, line: Int = #line
) {
    let tolerance = 1e-9
    expectClose(actual.b0, expected[0], tolerance: tolerance, "b0", file: file, line: line)
    expectClose(actual.b1, expected[1], tolerance: tolerance, "b1", file: file, line: line)
    expectClose(actual.b2, expected[2], tolerance: tolerance, "b2", file: file, line: line)
    expectClose(actual.a1, expected[3], tolerance: tolerance, "a1", file: file, line: line)
    expectClose(actual.a2, expected[4], tolerance: tolerance, "a2", file: file, line: line)
}

// MARK: - RBJ peaking coefficients vs independent Python-computed references

func testPeakingCoefficientReferences() {
    expectCoefficients(
        peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: 6.0),
        [1.043953086990, -1.895320723937, 0.867722284760, -1.895320723937, 0.911675371750]
    )
    expectCoefficients(
        peakingCoefficients(sampleRate: 48000, frequency: 31.5, q: 2.2, gainDB: -12.0),
        [0.998602485205, -1.996250408025, 0.997664893001, -1.996250408025, 0.996267378206]
    )
    expectCoefficients(
        peakingCoefficients(sampleRate: 44100, frequency: 16000, q: 2.2, gainDB: 12.0),
        [1.237257245133, 1.198259601429, 0.603566949272, 1.198259601429, 0.840824194405]
    )
    expectCoefficients(
        peakingCoefficients(sampleRate: 96000, frequency: 125, q: 0.5, gainDB: 3.0),
        [1.002820317669, -1.986260502412, 0.983506659325, -1.986260502412, 0.986326976994]
    )
}

// MARK: - Magnitude response

func testMagnitudeResponse() {
    let peak6 = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: 6.0)
    expectClose(
        magnitudeDB(of: [peak6], sampleRate: 48000, frequency: 1000),
        6.0, tolerance: 1e-6, "magnitude at Fc equals gain"
    )
    expectClose(
        magnitudeDB(of: [peak6], sampleRate: 48000, frequency: 8000),
        0.084432, tolerance: 1e-5, "magnitude far from Fc (Python reference)"
    )

    let flat = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 2.2, gainDB: 0.0)
    for frequency in [20.0, 100.0, 1000.0, 10000.0, 20000.0] {
        expectClose(
            magnitudeDB(of: [flat], sampleRate: 48000, frequency: frequency),
            0.0, tolerance: 1e-9, "zero-gain band is identity at \(frequency) Hz"
        )
    }

    let boost = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: 6.0)
    let cut = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: -6.0)
    expectClose(
        magnitudeDB(of: [boost, cut], sampleRate: 48000, frequency: 1000),
        0.0, tolerance: 1e-6, "opposite gains at same Fc cancel"
    )
}

// MARK: - Auto-preamp

func testAutoPreamp() {
    let bands = [
        peakingCoefficients(sampleRate: 48000, frequency: 63, q: 2.2, gainDB: 8.0),
        peakingCoefficients(sampleRate: 48000, frequency: 4000, q: 2.2, gainDB: 3.0),
    ]
    let preamp = autoPreampDB(of: bands, sampleRate: 48000)
    expect(preamp <= -8.0, "preamp \(preamp) must negate at least the largest band gain")
    expect(preamp > -12.0, "preamp \(preamp) unreasonably large for +8 dB max boost")

    let frequencies = logSpacedFrequencies(from: 20, to: 20000, count: 512)
    expect(frequencies.count == 512, "frequency grid has requested count")
    let maxAfter = frequencies
        .map { magnitudeDB(of: bands, sampleRate: 48000, frequency: $0) + preamp }
        .max()
    expect(maxAfter != nil && abs(maxAfter!) < 0.01, "preamp brings response peak to 0 dB, got \(String(describing: maxAfter))")

    let cutsOnly = [peakingCoefficients(sampleRate: 48000, frequency: 250, q: 2.2, gainDB: -6.0)]
    expectClose(
        autoPreampDB(of: cutsOnly, sampleRate: 48000),
        0.0, tolerance: 1e-9, "cuts-only chain needs no preamp"
    )
}

// MARK: - Frequency grid

func testLogSpacedFrequencies() {
    let grid = logSpacedFrequencies(from: 20, to: 20000, count: 4)
    expect(grid.count == 4, "grid count")
    if grid.count == 4 {
        expectClose(grid[0], 20, tolerance: 1e-9, "grid start")
        expectClose(grid[3], 20000, tolerance: 1e-6, "grid end")
        expectClose(grid[1] / grid[0], grid[2] / grid[1], tolerance: 1e-9, "log spacing has constant ratio")
    }
}

// MARK: - EQKernel end-to-end behavior

/// RMS of one channel of an interleaved stereo buffer, skipping a settle prefix.
private func channelRMS(_ samples: [Float], channel: Int, channelCount: Int, skipFrames: Int) -> Double {
    var sum = 0.0
    var count = 0
    var index = skipFrames * channelCount + channel
    while index < samples.count {
        sum += Double(samples[index]) * Double(samples[index])
        count += 1
        index += channelCount
    }
    return (sum / Double(count)).squareRoot()
}

func testKernelAppliesBandGainToSine() {
    let sampleRate = 48000.0
    let frameCount = 48000
    let frequency = 1000.0
    let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: frequency, q: 1.0, gainDB: 6.0)]
    guard let kernel = EQKernel(cascade: cascade, preampDB: 0, sampleRate: sampleRate, maxChannels: 2) else {
        expect(false, "kernel construction failed")
        return
    }

    var buffer = [Float](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let value = Float(sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate)) * 0.25
        buffer[frame * 2] = value
        buffer[frame * 2 + 1] = value
    }
    let inputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: 4800)

    buffer.withUnsafeMutableBufferPointer { pointer in
        kernel.process(interleaved: pointer.baseAddress!, frameCount: frameCount, channelCount: 2)
    }

    for channel in 0..<2 {
        let outputRMS = channelRMS(buffer, channel: channel, channelCount: 2, skipFrames: 4800)
        let gainDB = 20.0 * log10(outputRMS / inputRMS)
        expectClose(gainDB, 6.0, tolerance: 0.05, "sine at Fc gains +6 dB (channel \(channel))")
    }
}

/// Regression check for low-band audibility: Float32 biquad state at very low
/// Fc/48 kHz is numerically delicate, so measure the real kernel gain there.
func testKernelLowBandsApplyGain() {
    let sampleRate = 48000.0
    let frameCount = 144000  // 3 s, so even a 31.5 Hz filter fully settles
    let skip = 48000
    for (frequency, q) in [(31.5, 2.2), (63.0, 2.2), (125.0, 2.2)] {
        let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: frequency, q: q, gainDB: 12.0)]
        guard let kernel = EQKernel(cascade: cascade, preampDB: 0, sampleRate: sampleRate, maxChannels: 2) else {
            expect(false, "kernel construction failed for \(frequency) Hz")
            continue
        }
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let value = Float(sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate)) * 0.1
            buffer[frame * 2] = value
            buffer[frame * 2 + 1] = value
        }
        let inputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: skip)
        buffer.withUnsafeMutableBufferPointer { pointer in
            kernel.process(interleaved: pointer.baseAddress!, frameCount: frameCount, channelCount: 2)
        }
        let outputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: skip)
        let gainDB = 20.0 * log10(outputRMS / inputRMS)
        expectClose(gainDB, 12.0, tolerance: 0.1, "+12 dB band at \(frequency) Hz delivers +12 dB")
    }
}

func testKernelPreampScales() {
    let sampleRate = 48000.0
    let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 1.0, gainDB: 0.0)]
    guard let kernel = EQKernel(cascade: cascade, preampDB: -6.0, sampleRate: sampleRate, maxChannels: 2) else {
        expect(false, "kernel construction failed")
        return
    }
    var buffer = [Float](repeating: 0.5, count: 512 * 2)
    buffer.withUnsafeMutableBufferPointer { pointer in
        kernel.process(interleaved: pointer.baseAddress!, frameCount: 512, channelCount: 2)
    }
    // DC through a flat band settles fast; check the tail.
    let tail = Double(buffer[1000])
    expectClose(tail, 0.5 * pow(10.0, -6.0 / 20.0), tolerance: 0.001, "preamp -6 dB scales amplitude")
}

testPeakingCoefficientReferences()
testMagnitudeResponse()
testAutoPreamp()
testLogSpacedFrequencies()
testKernelAppliesBandGainToSine()
testKernelLowBandsApplyGain()
testKernelPreampScales()

if failureCount > 0 {
    print("\(failureCount) of \(expectationCount) expectations FAILED")
    exit(1)
}
print("All \(expectationCount) expectations passed")
