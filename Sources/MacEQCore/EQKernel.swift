import Accelerate
import Foundation

/// A built, immutable EQ processing chain: one vDSP biquad cascade applied per
/// channel (stereo-linked coefficients, independent filter state) plus a preamp.
///
/// Build on a non-real-time thread; `process` is real-time safe (no allocation,
/// no locks — the delay buffers are preallocated and owned by the kernel).
/// Wraps vDSP (external system interface), hence a class with managed lifetime.
public final class EQKernel {
    private let setup: vDSP_biquad_Setup
    private let sectionCount: Int
    private let preampLinear: Float
    /// vDSP delay state: 2 * sections + 2 floats per channel.
    private let delays: [UnsafeMutablePointer<Float>]
    private let maxChannels: Int

    public let sampleRate: Double

    /// - Parameters:
    ///   - cascade: biquad sections applied in series (identical for all channels).
    ///   - preampDB: gain applied after filtering, in dB.
    ///   - sampleRate: rate the coefficients were computed for.
    ///   - maxChannels: number of independent channel states to allocate.
    public init?(cascade: [BiquadCoefficients], preampDB: Double, sampleRate: Double, maxChannels: Int) {
        guard !cascade.isEmpty, maxChannels > 0 else { return nil }
        var flattened: [Double] = []
        flattened.reserveCapacity(cascade.count * 5)
        for section in cascade {
            flattened.append(contentsOf: [section.b0, section.b1, section.b2, section.a1, section.a2])
        }
        guard let setup = vDSP_biquad_CreateSetup(flattened, vDSP_Length(cascade.count)) else {
            return nil
        }
        self.setup = setup
        self.sectionCount = cascade.count
        self.preampLinear = Float(pow(10.0, preampDB / 20.0))
        self.sampleRate = sampleRate
        self.maxChannels = maxChannels
        let delayLength = 2 * cascade.count + 2
        self.delays = (0..<maxChannels).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: delayLength)
            pointer.initialize(repeating: 0, count: delayLength)
            return pointer
        }
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
        for pointer in delays {
            pointer.deallocate()
        }
    }

    /// Filters interleaved Float32 audio in place. Real-time safe.
    public func process(interleaved samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        guard frameCount > 0, channelCount > 0 else { return }
        let channels = min(channelCount, maxChannels)
        for channel in 0..<channels {
            vDSP_biquad(
                setup,
                delays[channel],
                samples + channel,
                vDSP_Stride(channelCount),
                samples + channel,
                vDSP_Stride(channelCount),
                vDSP_Length(frameCount)
            )
        }
        var gain = preampLinear
        let totalSamples = vDSP_Length(frameCount * channelCount)
        vDSP_vsmul(samples, 1, &gain, samples, 1, totalSamples)
    }
}
