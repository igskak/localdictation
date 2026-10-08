import Foundation

/// How fast a download is moving, smoothed enough to be quotable.
///
/// The instantaneous rate between two samples swings by a factor of several
/// either way on a normal connection, and an estimate built on it alternates
/// between "2 minutes" and "20 minutes" twice a second, which is less useful
/// than saying nothing. An exponential average over the recent samples is what
/// makes the figure hold still while the transfer is steady and still fall away
/// when it stops.
struct ModelDownloadRate: Sendable, Equatable {
    /// Samples closer together than this say more about the polling than about
    /// the connection, so they are folded into the next one instead.
    private static let minimumInterval: TimeInterval = 0.5
    /// How long a transfer has to have been watched before its rate is quoted.
    /// The first seconds are the TLS handshake, the metadata requests and a
    /// window that has not opened yet.
    private static let warmup: TimeInterval = 3
    /// Below this the transfer has stalled rather than slowed, and dividing by
    /// it would quote hours for a download that is about to resume.
    private static let stallFloor: Double = 8 * 1024
    private static let smoothing = 0.25

    private var lastBytes: Int64?
    private var lastSampledAt: Date?
    private var watchedFor: TimeInterval = 0
    private var smoothed: Double?

    /// Bytes per second, or nil while there is nothing trustworthy to report.
    var bytesPerSecond: Double? {
        guard watchedFor >= Self.warmup, let smoothed, smoothed >= Self.stallFloor else { return nil }
        return smoothed
    }

    /// Folds one reading of "bytes on disk" into the average.
    ///
    /// The first reading only sets the baseline. Bytes an interrupted attempt
    /// left on disk arrived on some earlier connection, and counting them as
    /// this second's throughput would promise a download finishing in moments.
    mutating func observe(bytes: Int64, at now: Date) {
        guard let lastBytes, let lastSampledAt else {
            self.lastBytes = bytes
            self.lastSampledAt = now
            return
        }
        let interval = now.timeIntervalSince(lastSampledAt)
        guard interval >= Self.minimumInterval else { return }
        let instant = Double(max(0, bytes - lastBytes)) / interval
        smoothed = smoothed.map { $0 + (instant - $0) * Self.smoothing } ?? instant
        watchedFor += interval
        self.lastBytes = bytes
        self.lastSampledAt = now
    }
}

/// Measures a model download by what has landed on disk.
///
/// Injected as a closure rather than a folder so the arithmetic is testable
/// without a network, a download or a file system: `ModelDownloadMeterTests`
/// drives it with a clock and a counter. `WhisperKitTranscriptionService` is
/// where the closure counts real bytes, because the layout it walks is the
/// Hugging Face cache's and belongs to that engine.
struct ModelDownloadMeter: Sendable {
    /// Walking the folder is cheap but not free, and the menu asks for the model
    /// state two and a half times a second while the download runs.
    private static let minimumInterval: TimeInterval = 0.5

    let totalBytes: Int64
    private let measureBytes: @Sendable () -> Int64
    private var rate = ModelDownloadRate()
    private var latest: ModelDownloadProgress?
    private var measuredAt: Date?

    init(totalBytes: Int64, measureBytes: @escaping @Sendable () -> Int64) {
        self.totalBytes = totalBytes
        self.measureBytes = measureBytes
    }

    /// Where the download has got to, sampling the disk at most twice a second.
    mutating func progress(now: Date = Date()) -> ModelDownloadProgress {
        if let latest, let measuredAt, now.timeIntervalSince(measuredAt) < Self.minimumInterval {
            return latest
        }
        // Clamped to the total: the total is what the repository listed, and a
        // repository that has since gained a file would otherwise report 103%.
        let bytes = min(max(0, measureBytes()), totalBytes)
        rate.observe(bytes: bytes, at: now)
        let remaining = max(0, totalBytes - bytes)
        let progress = ModelDownloadProgress(
            completedBytes: bytes,
            totalBytes: totalBytes,
            remainingSeconds: rate.bytesPerSecond.map { Double(remaining) / $0 }
        )
        latest = progress
        measuredAt = now
        return progress
    }
}

/// What the speech model weighs, learned from the repository that serves it.
///
/// A bar needs a total, and before the first download nothing on this Mac knows
/// one. This is the same one-way request `docs/PRIVACY.md` already lists, to the
/// same host, carrying no identifier of the user or the Mac: a path and a query,
/// answered with a list of file names and sizes.
enum SpeechModelDownloadSize {
    /// What `openai_whisper-large-v3-v20240930_turbo` measured on 30.09.2026:
    /// 1,638,464,446 bytes across twenty-four files, of which
    /// `AudioEncoder.mlmodelc/weights/weight.bin` is 1.27 GB.
    ///
    /// Kept for the run that cannot ask — a first launch behind a captive portal
    /// that clears a minute later — and read by the copy that names the size, so
    /// the number a user is told and the number the bar divides by cannot drift
    /// apart the way the old "about 600 MB" had drifted from a model three times
    /// that size.
    static let pinnedVariantBytes: Int64 = 1_638_464_446

    /// "1.64 GB", for the copy that has to name the size before there is a
    /// download to measure.
    static var pinnedVariantSizeText: String {
        ModelDownloadProgress.sizeText(pinnedVariantBytes)
    }

    /// Sums the sizes the repository lists for one variant, or nil when the
    /// answer cannot be trusted.
    ///
    /// Never throws. A bar is a courtesy, and a size request that failed must
    /// not be what stops a download the user is waiting for.
    static func bytes(
        repo: String,
        variant: String,
        endpoint: String = "https://huggingface.co",
        session: URLSession = .shared
    ) async -> Int64? {
        guard var components = URLComponents(string: "\(endpoint)/api/models/\(repo)/tree/main/\(variant)") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = components.url else { return nil }

        // Short on purpose: this runs before the download starts, so every
        // second it waits is a second the user watches a bar that is not there.
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return total(ofListing: data)
        } catch {
            Log.transcription.info(
                "Could not ask for the speech model's size: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Parsed separately from the request so a test can hold the shape of the
    /// answer without reaching the network.
    static func total(ofListing data: Data) -> Int64? {
        struct Entry: Decodable {
            struct LFS: Decodable { let size: Int64? }
            let type: String
            let size: Int64?
            let lfs: LFS?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        let total = entries
            .filter { $0.type == "file" }
            // An LFS entry carries the real size in `lfs`, and in some answers
            // `size` is the pointer file instead. The larger of the two is the
            // one that has to come down the wire.
            .reduce(Int64(0)) { $0 + max($1.size ?? 0, $1.lfs?.size ?? 0) }
        return total > 0 ? total : nil
    }
}
