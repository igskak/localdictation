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
            Label(
                "LocalDictation",
                systemImage: StatusPresentation(state: coordinator.state, binding: coordinator.binding).systemImage
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
        }
    }
}
