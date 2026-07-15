import AVFoundation
import Foundation

/// Error loading an impulse response file, with enough context to debug.
public struct ImpulseResponseError: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { "ImpulseResponseError: \(message)" }
}

/// Upper bound on IR length after resampling (~21 s at 48 kHz). Room-correction
/// impulse responses are far shorter; anything bigger is the wrong file, and
/// admitting it would allocate hundreds of MB of partition spectra.
public let maxImpulseResponseFrames = 1 << 20

/// Loads an impulse response audio file (WAV/AIFF/CAF — anything AVAudioFile
/// reads) as one Float32 array per channel, resampled to `sampleRate` when the
/// file's rate differs. Mono or stereo only.
public func loadImpulseResponse(url: URL, sampleRate: Double) throws -> [[Float]] {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw ImpulseResponseError(
            message: "cannot read \(url.lastPathComponent): \(error.localizedDescription)"
        )
    }
    let fileFormat = file.processingFormat
    let channelCount = Int(fileFormat.channelCount)
    guard channelCount == 1 || channelCount == 2 else {
        throw ImpulseResponseError(
            message: "\(url.lastPathComponent) has \(channelCount) channels; only mono or stereo impulse responses are supported"
        )
    }
    guard file.length > 0 else {
        throw ImpulseResponseError(message: "\(url.lastPathComponent) contains no audio")
    }
    let resampledLength = Double(file.length) * sampleRate / fileFormat.sampleRate
    guard resampledLength <= Double(maxImpulseResponseFrames) else {
        throw ImpulseResponseError(
            message: "\(url.lastPathComponent) is \(file.length) frames (\(String(format: "%.1f", Double(file.length) / fileFormat.sampleRate)) s) — too long for an impulse response (max \(maxImpulseResponseFrames) frames)"
        )
    }

    guard let readBuffer = AVAudioPCMBuffer(
        pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(file.length)
    ) else {
        throw ImpulseResponseError(
            message: "buffer allocation failed for \(file.length) frames of \(url.lastPathComponent)"
        )
    }
    do {
        try file.read(into: readBuffer)
    } catch {
        throw ImpulseResponseError(
            message: "reading \(url.lastPathComponent) failed: \(error.localizedDescription)"
        )
    }

    if fileFormat.sampleRate == sampleRate {
        return channelArrays(from: readBuffer)
    }

    guard
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: fileFormat.channelCount,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: fileFormat, to: targetFormat),
        let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(resampledLength) + 4096
        )
    else {
        throw ImpulseResponseError(
            message: "resampler construction failed (\(fileFormat.sampleRate) Hz -> \(sampleRate) Hz, \(channelCount) ch)"
        )
    }

    var inputConsumed = false
    var conversionError: NSError?
    let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
        if inputConsumed {
            inputStatus.pointee = .endOfStream
            return nil
        }
        inputConsumed = true
        inputStatus.pointee = .haveData
        return readBuffer
    }
    guard status != .error else {
        throw ImpulseResponseError(
            message: "resampling \(url.lastPathComponent) from \(fileFormat.sampleRate) Hz to \(sampleRate) Hz failed: \(conversionError?.localizedDescription ?? "unknown error")"
        )
    }
    guard convertedBuffer.frameLength > 0 else {
        throw ImpulseResponseError(
            message: "resampling \(url.lastPathComponent) produced no frames"
        )
    }
    return channelArrays(from: convertedBuffer)
}

private func channelArrays(from buffer: AVAudioPCMBuffer) -> [[Float]] {
    guard let channelData = buffer.floatChannelData else { return [] }
    let frameCount = Int(buffer.frameLength)
    return (0..<Int(buffer.format.channelCount)).map { channel in
        Array(UnsafeBufferPointer(start: channelData[channel], count: frameCount))
    }
}
