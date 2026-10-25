import AppKit
import Foundation

/// The single product gate for file transcription, in the same shape as
/// `NotetakerAvailability` and independent of it: a build can transcribe files
/// without being able to record a meeting.
enum FileTranscriptionAvailability: Sendable, Equatable {
    case disabled
    case enabled

    #if DEBUG || FILE_TRANSCRIPTION
    static let liveDefault: FileTranscriptionAvailability = .enabled
    #else
    static let liveDefault: FileTranscriptionAvailability = .disabled
    #endif
}

/// Owns the coordinator and the two windows it opens: the progress window and,
/// when a file is done, the library on its note.
@MainActor
final class FileTranscriptionFeature {
    let coordinator: FileTranscriptionCoordinator
    private let windowController: FileTranscriptionWindowController
    private let libraryModel: MeetingLibraryModel
    private let libraryController: MeetingLibraryWindowController

    init(
        host: any FileTranscriptionHost,
        status: FileTranscriptionStatus,
        store: any MeetingStoring = FileMeetingStore(),
        makeDiarizer: @escaping () -> (any StreamingSpeakerDiarizationService)? = { nil }
    ) {
        coordinator = FileTranscriptionCoordinator(host: host, store: store, makeDiarizer: makeDiarizer, status: status)
        windowController = FileTranscriptionWindowController(coordinator: coordinator)
        libraryModel = MeetingLibraryModel(store: store)
        libraryController = MeetingLibraryWindowController(
            model: libraryModel,
            startMeeting: nil,
            windowTitle: L10n.string("Witness Transcripts")
        )
        coordinator.showWindow = { [weak self] in self?.windowController.show() }
        coordinator.openResult = { [weak self] id in
            self?.windowController.close()
            self?.libraryController.show(selecting: id)
        }
    }

    /// The library without a new file, for finding earlier transcripts.
    func showLibrary() { libraryController.show() }
}
