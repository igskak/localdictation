import AppKit
import Foundation

/// Owns the coordinator and the two windows it opens: the progress window and,
/// when a file is done, the library on its note.
@MainActor
final class FileTranscriptionFeature {
    let coordinator: FileTranscriptionCoordinator
    private let windowController: FileTranscriptionWindowController
    private let libraryController: MeetingLibraryWindowController

    init(
        host: any FileTranscriptionHost,
        engine: (any TranscriptionService)?,
        meetingIsActive: @escaping () -> Bool,
        store: any MeetingStoring = FileMeetingStore(rootURL: ApplicationSupportDirectory.subdirectory("Transcripts"))
    ) {
        let coordinator = FileTranscriptionCoordinator(host: host, store: store, engine: engine, meetingIsActive: meetingIsActive)
        self.coordinator = coordinator
        windowController = FileTranscriptionWindowController(coordinator: coordinator)
        libraryController = MeetingLibraryWindowController(
            model: MeetingLibraryModel(store: store),
            startMeeting: nil,
            startFile: { [weak coordinator] in coordinator?.presentWindow() },
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
