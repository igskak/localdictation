import Foundation

/// Decides whether a file's rows get automatic speaker numbers.
///
/// They do not, until the release gate in docs/FILE_TRANSCRIPTION_PLAN.md
/// (F2) has measurements to stand on: at least ten consented two- and
/// three-person interviews and ten scored minutes per language, speaker error
/// at or below the 20% `DiarizationQualityGate` threshold. No such recordings
/// exist yet, so an ordinary build hands the session no diarizer, and the
/// person assigns `Speaker 1…8` to passages by hand. A build that wants to
/// look at the automatic result sets `FILE_SPEAKER_LABELS`.
enum FileSpeakerPolicy {
    static func diarizer() -> (any StreamingSpeakerDiarizationService)? {
        #if FILE_SPEAKER_LABELS
        ProductionDiarizationFactory.make()
        #else
        nil
        #endif
    }
}
