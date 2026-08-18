import AVFoundation

/// Converts device input buffers to mono Float32 PCM at 16 kHz.
///
/// One converter and one output buffer are allocated up front and reused, so the
/// audio callback performs no allocation in the common case.
///
/// The type is `@unchecked Sendable` because `AVAudioConverter` and
/// `AVAudioPCMBuffer` are not `Sendable`. The contract is single-threaded use:
/// exactly one capture session owns one converter, and only its tap thread calls
/// `convert`.
final class AudioFormatConverter: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter
    private var outputBuffer: AVAudioPCMBuffer
    /// Handed to the converter's input block during a single `convert` call.
    private var pendingInput: AVAudioPCMBuffer?

    init(
        inputFormat: AVAudioFormat,
        targetSampleRate: Double = AudioTargetFormat.sampleRate,
        maximumInputFrames: AVAudioFrameCount = 8192
    ) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.unsupportedInputFormat("\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        }

        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(AudioTargetFormat.channelCount),
            interleaved: false
        ) else {
            throw AudioCaptureError.converterUnavailable("target format could not be created")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw AudioCaptureError.converterUnavailable("no conversion path from the input format")
        }
        converter.downmix = true

        let ratio = targetSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(maximumInputFrames) * ratio).rounded(.up)) + 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            throw AudioCaptureError.converterUnavailable("output buffer could not be allocated")
        }

        self.inputFormat = inputFormat
        self.outputFormat = output
        self.converter = converter
        self.outputBuffer = buffer
    }

    /// Converts one input buffer. The returned pointer is owned by the converter
    /// and stays valid until the next `convert` call.
    func convert(_ input: AVAudioPCMBuffer) throws -> UnsafeBufferPointer<Float> {
        guard input.frameLength > 0 else { return UnsafeBufferPointer(start: nil, count: 0) }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let required = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        if outputBuffer.frameCapacity < required {
            // Only happens if the driver hands us larger buffers than expected.
            guard let grown = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: required) else {
                throw AudioCaptureError.converterUnavailable("output buffer could not be resized")
            }
            outputBuffer = grown
        }

        outputBuffer.frameLength = 0
        pendingInput = input
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { [self] _, inputStatus in
            guard let buffer = pendingInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            pendingInput = nil
            inputStatus.pointee = .haveData
            return buffer
        }
        pendingInput = nil

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw AudioCaptureError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        @unknown default:
            throw AudioCaptureError.conversionFailed("unexpected converter status")
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw AudioCaptureError.conversionFailed("output buffer has no float channel data")
        }
        return UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
    }

    /// Flushes the sample-rate converter's internal latency.
    ///
    /// A resampler holds back tens of milliseconds of output while it runs. Without
    /// draining at the end of an utterance, that tail — the last part of what the
    /// user said — would stay inside the converter and never reach the buffer.
    /// Called once per utterance from the stop path, never from the audio callback.
    func drain() throws -> UnsafeBufferPointer<Float> {
        outputBuffer.frameLength = 0
        pendingInput = nil
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw AudioCaptureError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        @unknown default:
            throw AudioCaptureError.conversionFailed("unexpected converter status")
        }

        guard outputBuffer.frameLength > 0, let channelData = outputBuffer.floatChannelData else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
    }

    /// Test-friendly variant that copies the converted frames out.
    func convertToArray(_ input: AVAudioPCMBuffer) throws -> [Float] {
        let frames = try convert(input)
        return Array(frames)
    }

    /// Test-friendly variant of `drain`.
    func drainToArray() throws -> [Float] {
        Array(try drain())
    }
}
