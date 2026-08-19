import OSLog

/// Privacy-safe logging categories.
///
/// Only non-content values may be logged: device names, formats, durations,
/// counters, and state names. PCM samples, transcripts, and clipboard contents
/// must never reach a logger.
enum Log {
    private static let subsystem = "com.localdictation.LocalDictation"

    static let application = Logger(subsystem: subsystem, category: "application")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let voiceActivity = Logger(subsystem: subsystem, category: "voice-activity")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    /// Insertion may log the identity of the target application — a bundle
    /// identifier is not content — and never the text that went into it.
    static let insertion = Logger(subsystem: subsystem, category: "insertion")
}
