import Accelerate
import Foundation

/// Uniform partitioned FFT convolution: overlap-save with a frequency-domain
/// delay line. Runs long FIR filters (room-correction impulse responses of tens
/// of thousands of taps) at a flat per-block cost instead of O(taps) per sample.
///
/// The impulse response is split into `blockSize`-sample partitions whose spectra
/// are precomputed in `init`. Each input block is FFT'd once into a ring of past
/// input spectra; the output block is the inverse FFT of the sum over partitions
/// of (past input spectrum x partition spectrum). Latency is exactly one block:
/// the output ring is primed with `blockSize` zeros so `process` always produces
/// as many samples as it consumes.
///
/// Real-time safety: `process` allocates nothing and takes no locks; every buffer
/// and FFT setup is created in `init`. State is touched only by the audio thread.
///
/// Interfaces vDSP setups and raw buffers with manual lifetime, hence a class.
public final class FIRConvolver {
    public let blockSize: Int
    public let partitionCount: Int
    public let irFrameCount: Int
    /// Samples of delay this convolver adds to the signal path.
    public var latencyFrames: Int { blockSize }

    private let maxChannels: Int
    private let irChannelCount: Int
    /// FFT length is 2*blockSize real samples = blockSize complex bins (packed:
    /// DC in real[0], Nyquist in imag[0]).
    private let binCount: Int
    private let ringCapacity: Int

    private let forwardDFT: vDSP_DFT_Setup
    private let inverseDFT: vDSP_DFT_Setup

    /// Partition spectra of the IR, [irChannel][partition][bin], scale pre-applied.
    private let irReal: UnsafeMutablePointer<Float>
    private let irImag: UnsafeMutablePointer<Float>
    /// Frequency-domain delay line of past input spectra, [channel][slot][bin].
    private let fdlReal: UnsafeMutablePointer<Float>
    private let fdlImag: UnsafeMutablePointer<Float>
    /// Previous input block per channel (overlap-save needs the last 2B samples).
    private let previousBlock: UnsafeMutablePointer<Float>
    /// Input accumulation per channel, filled to blockSize before each FFT.
    private let inputAccumulator: UnsafeMutablePointer<Float>
    /// Output FIFO per channel, primed with blockSize zeros.
    private let outputRing: UnsafeMutablePointer<Float>
    /// Scratch: split-complex workspace and 2B time-domain samples.
    private let scratchReal: UnsafeMutablePointer<Float>
    private let scratchImag: UnsafeMutablePointer<Float>
    private let accumulatorReal: UnsafeMutablePointer<Float>
    private let accumulatorImag: UnsafeMutablePointer<Float>
    private let timeDomain: UnsafeMutablePointer<Float>

    private var fillCount = 0
    private var ringReadIndex = 0
    private var ringWriteIndex: Int
    private var fdlSlot = 0

    public init?(impulseResponse: [[Float]], blockSize: Int, maxChannels: Int) {
        guard blockSize >= 16,
              blockSize & (blockSize - 1) == 0,
              maxChannels >= 1,
              !impulseResponse.isEmpty,
              impulseResponse.count == 1 || impulseResponse.count == maxChannels,
              let irLength = impulseResponse.first?.count,
              irLength > 0,
              impulseResponse.allSatisfy({ $0.count == irLength })
        else { return nil }

        let fftLength = 2 * blockSize
        guard
            let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftLength), .FORWARD),
            let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftLength), .INVERSE)
        else { return nil }

        self.blockSize = blockSize
        self.maxChannels = maxChannels
        self.irChannelCount = impulseResponse.count
        self.irFrameCount = irLength
        self.binCount = blockSize
        self.ringCapacity = 2 * blockSize
        self.partitionCount = (irLength + blockSize - 1) / blockSize
        self.forwardDFT = forward
        self.inverseDFT = inverse

        let irPlaneSize = irChannelCount * partitionCount * binCount
        let fdlPlaneSize = maxChannels * partitionCount * binCount
        irReal = .allocate(capacity: irPlaneSize)
        irImag = .allocate(capacity: irPlaneSize)
        fdlReal = .allocate(capacity: fdlPlaneSize)
        fdlImag = .allocate(capacity: fdlPlaneSize)
        previousBlock = .allocate(capacity: maxChannels * blockSize)
        inputAccumulator = .allocate(capacity: maxChannels * blockSize)
        outputRing = .allocate(capacity: maxChannels * ringCapacity)
        scratchReal = .allocate(capacity: binCount)
        scratchImag = .allocate(capacity: binCount)
        accumulatorReal = .allocate(capacity: binCount)
        accumulatorImag = .allocate(capacity: binCount)
        timeDomain = .allocate(capacity: fftLength)

        fdlReal.initialize(repeating: 0, count: fdlPlaneSize)
        fdlImag.initialize(repeating: 0, count: fdlPlaneSize)
        previousBlock.initialize(repeating: 0, count: maxChannels * blockSize)
        inputAccumulator.initialize(repeating: 0, count: maxChannels * blockSize)
        outputRing.initialize(repeating: 0, count: maxChannels * ringCapacity)
        // Priming the ring with one block of zeros keeps production and consumption
        // in lockstep: the ring can never underflow, at the cost of blockSize latency.
        ringWriteIndex = blockSize

        // Precompute partition spectra. The scale folds in the vDSP conventions:
        // zrop forward is 2x the mathematical DFT (applied to both the signal and
        // the IR) and zrop inverse is fftLength/2... the combined round-trip factor
        // is 4 * fftLength, verified by the delta-identity test.
        var scale = Float(1.0) / (4.0 * Float(fftLength))
        for channel in 0..<irChannelCount {
            for partition in 0..<partitionCount {
                let start = partition * blockSize
                let length = min(blockSize, irLength - start)
                timeDomain.update(repeating: 0, count: fftLength)
                impulseResponse[channel].withUnsafeBufferPointer { source in
                    timeDomain.update(from: source.baseAddress! + start, count: length)
                }
                let destinationReal = irReal + (channel * partitionCount + partition) * binCount
                let destinationImag = irImag + (channel * partitionCount + partition) * binCount
                forwardTransform(into: destinationReal, imag: destinationImag)
                vDSP_vsmul(destinationReal, 1, &scale, destinationReal, 1, vDSP_Length(binCount))
                vDSP_vsmul(destinationImag, 1, &scale, destinationImag, 1, vDSP_Length(binCount))
            }
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardDFT)
        vDSP_DFT_DestroySetup(inverseDFT)
        irReal.deallocate()
        irImag.deallocate()
        fdlReal.deallocate()
        fdlImag.deallocate()
        previousBlock.deallocate()
        inputAccumulator.deallocate()
        outputRing.deallocate()
        scratchReal.deallocate()
        scratchImag.deallocate()
        accumulatorReal.deallocate()
        accumulatorImag.deallocate()
        timeDomain.deallocate()
    }

    /// Convolves interleaved samples in place. Channels beyond `maxChannels` pass
    /// through untouched. Any frame count works; blocks are assembled internally.
    public func process(
        interleaved buffer: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int
    ) {
        let channels = min(channelCount, maxChannels)
        guard channels > 0, frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let base = frame * channelCount
            for channel in 0..<channels {
                inputAccumulator[channel * blockSize + fillCount] = buffer[base + channel]
            }
            fillCount += 1
            if fillCount == blockSize {
                for channel in 0..<channels {
                    runBlock(channel: channel)
                }
                fdlSlot = (fdlSlot + 1) % partitionCount
                ringWriteIndex = (ringWriteIndex + blockSize) % ringCapacity
                fillCount = 0
            }
            for channel in 0..<channels {
                buffer[base + channel] = outputRing[channel * ringCapacity + ringReadIndex]
            }
            ringReadIndex = (ringReadIndex + 1) % ringCapacity
        }
    }

    /// One overlap-save block for one channel: FFT the last 2B input samples into
    /// the delay line, multiply-accumulate against the partition spectra, inverse
    /// FFT, and keep the valid last B samples.
    private func runBlock(channel: Int) {
        let accumulated = inputAccumulator + channel * blockSize
        let previous = previousBlock + channel * blockSize
        timeDomain.update(from: previous, count: blockSize)
        (timeDomain + blockSize).update(from: accumulated, count: blockSize)
        previous.update(from: accumulated, count: blockSize)

        let slotReal = fdlReal + (channel * partitionCount + fdlSlot) * binCount
        let slotImag = fdlImag + (channel * partitionCount + fdlSlot) * binCount
        forwardTransform(into: slotReal, imag: slotImag)

        vDSP_vclr(accumulatorReal, 1, vDSP_Length(binCount))
        vDSP_vclr(accumulatorImag, 1, vDSP_Length(binCount))
        let irChannel = min(channel, irChannelCount - 1)
        // Bin 0 is packed (DC in real, Nyquist in imag): both are real-valued
        // products, accumulated separately because vDSP_zvma would cross-multiply.
        var dcSum: Float = 0
        var nyquistSum: Float = 0
        for partition in 0..<partitionCount {
            let slot = (fdlSlot - partition + partitionCount) % partitionCount
            let historyReal = fdlReal + (channel * partitionCount + slot) * binCount
            let historyImag = fdlImag + (channel * partitionCount + slot) * binCount
            let partitionReal = irReal + (irChannel * partitionCount + partition) * binCount
            let partitionImag = irImag + (irChannel * partitionCount + partition) * binCount
            dcSum += historyReal[0] * partitionReal[0]
            nyquistSum += historyImag[0] * partitionImag[0]
            var history = DSPSplitComplex(realp: historyReal, imagp: historyImag)
            var spectrum = DSPSplitComplex(realp: partitionReal, imagp: partitionImag)
            var accumulator = DSPSplitComplex(realp: accumulatorReal, imagp: accumulatorImag)
            vDSP_zvma(&history, 1, &spectrum, 1, &accumulator, 1, &accumulator, 1, vDSP_Length(binCount))
        }
        accumulatorReal[0] = dcSum
        accumulatorImag[0] = nyquistSum

        vDSP_DFT_Execute(inverseDFT, accumulatorReal, accumulatorImag, scratchReal, scratchImag)
        var split = DSPSplitComplex(realp: scratchReal, imagp: scratchImag)
        timeDomain.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { packed in
            vDSP_ztoc(&split, 1, packed, 2, vDSP_Length(binCount))
        }
        // ringWriteIndex is always block-aligned (it starts at blockSize and moves
        // by blockSize in a 2*blockSize ring), so this copy never wraps.
        (outputRing + channel * ringCapacity + ringWriteIndex)
            .update(from: timeDomain + blockSize, count: blockSize)
    }

    /// Forward real FFT of `timeDomain` (2B samples) into packed split-complex.
    private func forwardTransform(
        into real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>
    ) {
        var split = DSPSplitComplex(realp: scratchReal, imagp: scratchImag)
        timeDomain.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { packed in
            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(binCount))
        }
        vDSP_DFT_Execute(forwardDFT, scratchReal, scratchImag, real, imag)
    }
}
