import CoreML
import Foundation

/// Hands back the encoder output it already computed when it is asked to
/// encode exactly the same input again, within one utterance.
///
/// A mixed-language utterance runs Whisper's encoder twice over the same
/// thirty seconds: once so the language can be detected, and once more inside
/// the decode. Both build the first window the same way — the opening of the
/// recording, padded with zeros to thirty seconds — so both produce the same
/// mel spectrogram and, from it, the same encoder output. The second pass is
/// about 0.6 seconds on an M1 that buys nothing.
///
/// This is deliberately not an optimization of what the language detector
/// sees. 0.6.6 saved the same 0.6 seconds by giving the detector less audio,
/// and a Russian dictation came back as an English translation. Here the
/// detector and the decoder receive the encoder's output for the full window,
/// the same numbers they received before; only the recomputation is gone.
///
/// Correctness does not rest on anybody's reading of WhisperKit. An output is
/// reused only when the new input matches the remembered one byte for byte,
/// shape and layout included. If a future WhisperKit builds the two windows
/// differently, the comparison fails and the encoder simply runs again: the
/// failure mode is the old speed, never somebody else's numbers.
///
/// Armed per utterance and cleared at its end. Between utterances it holds
/// nothing, so no audio-derived tensor outlives the dictation it came from.
final class EncoderOutputReuse: @unchecked Sendable {
    private struct Remembered {
        let bytes: Data
        let shape: [NSNumber]
        let strides: [NSNumber]
        let dataType: MLMultiArrayDataType
        let output: MLMultiArray
    }

    private let lock = NSLock()
    private var isArmed = false
    private var remembered: Remembered?
    private var reuses = 0

    /// Starts remembering. Anything left from before is dropped first.
    func beginUtterance() {
        lock.withLock {
            isArmed = true
            remembered = nil
            reuses = 0
        }
    }

    /// Stops remembering, releases the tensors, and reports how many encoder
    /// passes this utterance was spared.
    @discardableResult
    func endUtterance() -> Int {
        lock.withLock {
            isArmed = false
            remembered = nil
            defer { reuses = 0 }
            return reuses
        }
    }

    /// The output already computed for exactly this input during this
    /// utterance, or nil when the encoder has to run.
    ///
    /// Synchronous on purpose, with `remember` as its other half. The encoder
    /// call between them is asynchronous and belongs to the caller, so no
    /// tensor ever crosses a concurrency boundary through this type.
    func reusedOutput(for input: MLMultiArray) -> MLMultiArray? {
        lock.withLock { lookup(input) }
    }

    /// Keeps `output` as the answer for `input`, if an utterance is running.
    func remember(_ output: MLMultiArray, for input: MLMultiArray) {
        lock.withLock { store(input, output) }
    }

    private func lookup(_ input: MLMultiArray) -> MLMultiArray? {
        guard isArmed, let remembered else { return nil }
        guard
            input.dataType == remembered.dataType,
            input.shape == remembered.shape,
            input.strides == remembered.strides
        else { return nil }
        // `memcmp` rather than a generic element walk: the mel input is about
        // 768 KB, and this runs on the path the user is waiting on.
        let matches = input.withUnsafeBytes { current in
            remembered.bytes.withUnsafeBytes { previous in
                current.count == previous.count
                    && (current.count == 0 || memcmp(current.baseAddress!, previous.baseAddress!, current.count) == 0)
            }
        }
        guard matches else { return nil }
        reuses += 1
        return remembered.output
    }

    private func store(_ input: MLMultiArray, _ output: MLMultiArray) {
        guard isArmed else { return }
        remembered = Remembered(
            bytes: input.withUnsafeBytes { Data($0) },
            shape: input.shape,
            strides: input.strides,
            dataType: input.dataType,
            output: output
        )
    }
}
