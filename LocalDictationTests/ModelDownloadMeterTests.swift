import Foundation
import XCTest
@testable import Witness

/// The first run's download, as a number rather than a spinner.
///
/// The thing being tested is not cosmetic. The weights are 1.64 GB over
/// twenty-four files, one of which is 1.27 GB, so WhisperKit's own progress —
/// finished files over wanted files — reaches about a half in the first seconds
/// and then sits still for the rest of the download. The bar the first run
/// showed was that fraction. Everything here exists so the bar follows bytes,
/// and so the estimate over it is either measured or absent.
final class ModelDownloadMeterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Stands in for the download folder. Single-threaded by construction: the
    /// meter reads it synchronously from the actor that owns the download.
    private final class Counter: @unchecked Sendable {
        var bytes: Int64 = 0
        var reads = 0

        func read() -> Int64 {
            reads += 1
            return bytes
        }
    }

    private func meter(total: Int64, counter: Counter) -> ModelDownloadMeter {
        ModelDownloadMeter(totalBytes: total) { counter.read() }
    }

    func testTheBarFollowsTheBytes() {
        let counter = Counter()
        counter.bytes = 250
        var meter = meter(total: 1000, counter: counter)

        let progress = meter.progress(now: start)

        XCTAssertEqual(progress.completedBytes, 250)
        XCTAssertEqual(progress.remainingBytes, 750)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(progress.percent, 25)
    }

    /// A total listed by a repository can be stale by the time the bytes land.
    /// A bar at 103% is a visible bug; a bar that reaches its end a moment early
    /// is the approximation it always was.
    func testTheBarNeverGoesPastItsEnd() {
        let counter = Counter()
        counter.bytes = 1_500
        var meter = meter(total: 1000, counter: counter)

        let progress = meter.progress(now: start)

        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.remainingBytes, 0)
    }

    /// Nothing is said about the time left until a rate has actually been
    /// watched. The opening seconds are handshakes and metadata requests, and an
    /// estimate made from them is a fabricated one.
    func testTheFirstSecondsQuoteNoTime() {
        let counter = Counter()
        var meter = meter(total: 600_000_000, counter: counter)

        XCTAssertNil(meter.progress(now: start).remainingSeconds)
        counter.bytes = 500_000
        XCTAssertNil(meter.progress(now: start.addingTimeInterval(0.5)).remainingSeconds)
        counter.bytes = 1_000_000
        XCTAssertNil(meter.progress(now: start.addingTimeInterval(1)).remainingSeconds)
    }

    /// Bytes an interrupted attempt left on disk arrived on some earlier
    /// connection. Counting them as this second's throughput would announce a
    /// download finishing in moments and then let the figure collapse.
    func testBytesAlreadyOnDiskAreNotThroughput() {
        let counter = Counter()
        counter.bytes = 900
        var meter = meter(total: 1000, counter: counter)

        let progress = meter.progress(now: start)

        XCTAssertEqual(progress.completedBytes, 900)
        XCTAssertNil(progress.remainingSeconds)
    }

    func testASteadyTransferIsEstimatedFromItsOwnRate() throws {
        let counter = Counter()
        var meter = meter(total: 600_000_000, counter: counter)

        // One megabyte a second, sampled twice a second for eight seconds.
        var progress = meter.progress(now: start)
        for step in 1...16 {
            counter.bytes = Int64(step) * 500_000
            progress = meter.progress(now: start.addingTimeInterval(Double(step) * 0.5))
        }

        let seconds = try XCTUnwrap(progress.remainingSeconds)
        // 592 MB left at 1 MB/s. The bound is wide on purpose: what matters is
        // that the figure comes from the measured rate rather than from a guess,
        // and the exponential average is not meant to be exact.
        XCTAssertEqual(seconds, 592, accuracy: 30)
        XCTAssertEqual(progress.completedBytes, 8_000_000)
    }

    /// A stalled transfer produces no progress callbacks at all, which is why
    /// the meter is read from the model state on a timer. The figure it had
    /// before the stall must not go on being shown.
    func testAStalledTransferStopsQuotingATime() throws {
        let counter = Counter()
        var meter = meter(total: 600_000_000, counter: counter)

        var progress = meter.progress(now: start)
        for step in 1...16 {
            counter.bytes = Int64(step) * 500_000
            progress = meter.progress(now: start.addingTimeInterval(Double(step) * 0.5))
        }
        XCTAssertNotNil(progress.remainingSeconds)

        // The bytes stop arriving. The percentage stays where it was, honestly,
        // and the estimate goes away.
        for step in 17...60 {
            progress = meter.progress(now: start.addingTimeInterval(Double(step) * 0.5))
        }

        XCTAssertNil(progress.remainingSeconds)
        XCTAssertEqual(progress.completedBytes, 8_000_000)
    }

    /// The menu asks for the model state every 400 ms and the panel asks again;
    /// walking the folder for each of them would be work nobody sees.
    func testTheFolderIsNotWalkedForEveryAsk() {
        let counter = Counter()
        counter.bytes = 100
        var meter = meter(total: 1000, counter: counter)

        _ = meter.progress(now: start)
        counter.bytes = 500
        let second = meter.progress(now: start.addingTimeInterval(0.2))

        XCTAssertEqual(counter.reads, 1)
        XCTAssertEqual(second.completedBytes, 100)

        let third = meter.progress(now: start.addingTimeInterval(0.8))
        XCTAssertEqual(counter.reads, 2)
        XCTAssertEqual(third.completedBytes, 500)
    }

    // MARK: - What the user reads

    func testTheLabelNamesTheSizeLeftAndTheTimeLeft() throws {
        let download = ModelDownloadProgress(
            completedBytes: 500_000_000,
            totalBytes: 1_000_000_000,
            remainingSeconds: 240
        )
        let label = TranscriptionModelState.preparing(
            ModelPreparation(phase: .downloading, download: download)
        ).label

        XCTAssertTrue(label.contains("50%"), label)
        XCTAssertTrue(label.contains(download.remainingSizeText), label)
        XCTAssertTrue(label.contains(try XCTUnwrap(download.remainingTimeText)), label)
        // The size in the sentence is what is left, not what has arrived, and
        // with half a gigabyte of each the two would be indistinguishable if it
        // were not asserted.
        XCTAssertEqual(download.remainingBytes, 500_000_000)
    }

    /// Without a rate the sentence keeps the part that is measured and drops the
    /// part that is not.
    func testTheLabelDropsTheTimeItCannotMeasure() {
        let download = ModelDownloadProgress(
            completedBytes: 200_000_000,
            totalBytes: 1_000_000_000,
            remainingSeconds: nil
        )
        let label = TranscriptionModelState.preparing(
            ModelPreparation(phase: .downloading, download: download)
        ).label

        XCTAssertTrue(label.contains("20%"), label)
        XCTAssertTrue(label.contains(download.remainingSizeText), label)
    }

    func testTheLastMinuteIsNotCountedDownInSeconds() {
        let almostThere = ModelDownloadProgress(completedBytes: 990, totalBytes: 1000, remainingSeconds: 12)
        XCTAssertEqual(almostThere.remainingTimeText, L10n.string("less than a minute"))

        let aWhile = ModelDownloadProgress(completedBytes: 0, totalBytes: 1000, remainingSeconds: 130)
        // Rounded up to the whole minute rather than printed to the second.
        XCTAssertNotNil(aWhile.remainingTimeText)
        XCTAssertNotEqual(aWhile.remainingTimeText, almostThere.remainingTimeText)
    }

    /// A press during the download is answered with the same numbers the menu
    /// bar is showing, because the panel is where the person who pressed is
    /// looking.
    func testAPressDuringTheDownloadIsToldHowMuchIsLeft() throws {
        let download = ModelDownloadProgress(
            completedBytes: 800_000_000,
            totalBytes: 1_000_000_000,
            remainingSeconds: 180
        )
        let notice = SpeechModelNotice.preparing(
            ModelPreparation(phase: .downloading, download: download),
            hotkey: "⌥Space"
        )

        XCTAssertTrue(notice.message.contains("80%"), notice.message)
        XCTAssertTrue(notice.message.contains(download.remainingSizeText), notice.message)
        XCTAssertTrue(notice.message.contains(try XCTUnwrap(download.remainingTimeText)), notice.message)
        XCTAssertTrue(notice.message.contains("⌥Space"), notice.message)
        // The log gets the number and none of the sentence.
        XCTAssertEqual(notice.logLabel, "model:downloading 80%")
    }

    /// Nothing promises a size anywhere except from one measured constant. The
    /// copy used to say "about 600 MB" while the pinned variant weighed three
    /// times that, and a bar dividing by its own separate figure would let the
    /// same two numbers drift apart again.
    func testTheSizeTheUserIsToldIsTheSizeTheBarDividesBy() {
        XCTAssertEqual(
            SpeechModelDownloadSize.pinnedVariantSizeText,
            ModelDownloadProgress.sizeText(SpeechModelDownloadSize.pinnedVariantBytes)
        )
        XCTAssertGreaterThan(SpeechModelDownloadSize.pinnedVariantBytes, 1_500_000_000)
    }

    // MARK: - The total

    func testTheTotalIsSummedFromTheRepositoryListing() {
        let listing = Data("""
        [
          {"type": "directory", "path": "openai_whisper/AudioEncoder.mlmodelc"},
          {"type": "file", "path": "openai_whisper/config.json", "size": 1149},
          {"type": "file", "path": "openai_whisper/weight.bin", "size": 134,
           "lfs": {"size": 1273974400}}
        ]
        """.utf8)

        XCTAssertEqual(SpeechModelDownloadSize.total(ofListing: listing), 1_273_975_549)
    }

    func testAnAnswerThatCannotBeTrustedIsNoTotalAtAll() {
        XCTAssertNil(SpeechModelDownloadSize.total(ofListing: Data("[]".utf8)))
        XCTAssertNil(SpeechModelDownloadSize.total(ofListing: Data("<html>404</html>".utf8)))
        XCTAssertNil(
            SpeechModelDownloadSize.total(
                ofListing: Data(#"[{"type": "directory", "path": "x"}]"#.utf8)
            )
        )
    }

    // MARK: - Where the bytes land

    /// The layout the count walks, built by hand: files that have arrived sit in
    /// the model folder, and the one still coming in is a `.incomplete` file in
    /// the Hub's download cache beside it. Both count, or the bar would drop back
    /// every time a 1.27 GB file was finally moved into place.
    ///
    /// It descends into `.mlmodelc`, which is where all but a few kilobytes of
    /// this model live, and it ignores another variant in the same repository.
    func testTheCountFollowsBothPlacesBytesLand() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "witness-meter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let variant = WhisperKitTranscriptionService.defaultModelVariant
        let repo = base.appending(path: "models/argmaxinc/whisperkit-coreml")
        let arrived = repo.appending(path: "\(variant)/TextDecoder.mlmodelc/weights/weight.bin")
        let arriving = repo
            .appending(path: ".cache/huggingface/download/\(variant)")
            .appending(path: "AudioEncoder.mlmodelc/weights/weight.bin.5f2a.incomplete")
        let elsewhere = repo.appending(path: "openai_whisper-tiny/weights/weight.bin")

        for (file, bytes) in [(arrived, 300), (arriving, 700), (elsewhere, 9_000)] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: file)
        }

        XCTAssertEqual(
            WhisperKitTranscriptionService.downloadedByteCount(variant: variant, downloadBase: base),
            1_000
        )
        XCTAssertEqual(
            WhisperKitTranscriptionService.downloadedByteCount(variant: "openai_whisper-tiny", downloadBase: base),
            9_000
        )
    }

    /// A download that has not created its folder yet is at nothing, not at an
    /// error, and neither is one whose Application Support is missing.
    func testNothingOnDiskIsNoBytesRatherThanAFailure() {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "witness-absent-\(UUID().uuidString)")

        XCTAssertEqual(
            WhisperKitTranscriptionService.downloadedByteCount(
                variant: WhisperKitTranscriptionService.defaultModelVariant,
                downloadBase: nowhere
            ),
            0
        )
    }

    /// Renaming a source string drops its translation silently: the key stops
    /// matching and German falls back to English. These four are new, and the
    /// download is the screen a German first run spends its first minutes on.
    func testTheDownloadSentencesArrivedWithTheirGerman() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "de", ofType: "lproj"))
        let german = try XCTUnwrap(Bundle(path: path))

        for key in [
            "Downloading the speech model… %lld%%. %@ left, %@.",
            "Downloading the speech model… %lld%%. %@ left.",
            "about %@",
            "less than a minute"
        ] {
            XCTAssertNotEqual(german.localizedString(forKey: key, value: nil, table: nil), key, key)
        }
    }
}
