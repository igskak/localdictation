import SwiftUI

@main
struct LocalDictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator: DictationCoordinator

    init() {
        let coordinator = DictationCoordinator.makeLive()
        _coordinator = StateObject(wrappedValue: coordinator)
        // The delegate activates the coordinator once AppKit has finished
        // launching, so hotkey registration happens against a live event target.
        AppDelegate.coordinator = coordinator
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            // The indicator lives here because this is the one place that is on
            // screen whatever the user is doing. `MenuBarExtra` renders its
            // label as a template image, so the alert is the symbol itself
            // rather than a badge drawn over one.
            Label(
                "LocalDictation",
                systemImage: StatusPresentation(
                    state: coordinator.state,
                    binding: coordinator.binding,
                    attentionIsPending: coordinator.attentionIsPending,
                    silentResult: coordinator.silentResult
                ).systemImage
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
        }
    }
}
