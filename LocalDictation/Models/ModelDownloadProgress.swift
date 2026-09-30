import Foundation

/// A model download measured in bytes, which is the only unit that can carry a
/// size and a time.
///
/// WhisperKit reports its progress over files: one unit per file, twenty-four
/// files, and one of them (`AudioEncoder.mlmodelc/weights/weight.bin`) holds
/// three quarters of the bytes. That fraction runs to roughly a half in the
/// first seconds and then does not move for minutes, which is the bar the first
/// run actually showed. A bar that stops is worse than no bar: it reads as a
/// hang, and the first run is where this app loses people.
///
/// So these numbers come from the bytes on disk instead. Every field is
/// non-content: two byte counts and a duration.
struct ModelDownloadProgress: Sendable, Equatable {
    /// Bytes of this model already on disk, the file still arriving included,
    /// and with it whatever an earlier interrupted attempt left behind.
    var completedBytes: Int64
    /// What the whole model weighs.
    var totalBytes: Int64
    /// Seconds left at the recently measured rate, or nil while there is no rate
    /// worth quoting: the opening seconds of a transfer, and a stall. An
    /// estimate is a promise, and inventing one is exactly what the phases in
    /// `ModelPreparation` were built to avoid.
    var remainingSeconds: TimeInterval?

    var remainingBytes: Int64 { max(0, totalBytes - completedBytes) }

    /// `0...1`, and never outside it. A total learned from the repository can be
    /// stale by the time the bytes land, and a bar past its own end is a visible
    /// bug where an approximate total is not.
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var percent: Int { Int((fraction * 100).rounded()) }

    /// "620 MB", in the user's locale and in the decimal units Finder shows.
    var remainingSizeText: String { Self.sizeText(remainingBytes) }

    /// "about 4 minutes", "less than a minute", or nil while nothing can be said
    /// honestly.
    var remainingTimeText: String? {
        guard let remainingSeconds, remainingSeconds.isFinite, remainingSeconds >= 0 else { return nil }
        guard remainingSeconds >= 60 else { return L10n.string("less than a minute") }
        // Rounded up to the whole minute. A figure that counts down in seconds
        // invites somebody to watch it, and its last digit is noise: the rate it
        // came from is an average over the last few seconds of one connection.
        let minutes = (remainingSeconds / 60).rounded(.up)
        let duration = Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2, zeroValueUnits: .hide)
        )
        return L10n.format("about %@", duration)
    }

    static func sizeText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
