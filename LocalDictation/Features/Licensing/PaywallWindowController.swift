import AppKit
import Combine
import SwiftUI

/// The price, shown at the moment the user asked for the product.
///
/// Until this existed the lock was passive: the hotkey stopped working, the
/// explanation sat in the menu bar window, and the offers sat in Settings
/// behind two clicks nobody had a reason to make. Somebody whose trial ended
/// could go a week thinking the app had broken, which is the same outcome as
/// never having priced it at all.
///
/// So the press is the trigger. A person pressing the dictation key is telling
/// you they want the product right now; that is the honest moment to say what
/// it costs, and it beats a calendar date nobody is thinking about.
///
/// It does **not** activate the app. `LanguageSetupWindowController` does,
/// because the question there has to be answered before the product can work
/// at all. This one arrives while somebody is in the middle of writing, and
/// taking their focus to show them a price is how a utility gets uninstalled.
/// Floating and ordered front is enough to be unmissable; the first click is
/// what hands it the keyboard.
@MainActor
final class PaywallWindowController: NSObject, NSWindowDelegate {
    private let coordinator: DictationCoordinator
    /// Internal so tests can drive and close it the way a user does.
    private(set) var window: NSWindow?
    private var requestObserver: AnyCancellable?
    private var entitlementObserver: AnyCancellable?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        super.init()

        // `dropFirst` because subscribing is not a request: the count carried
        // by a Mac that has been locked since launch is history, not a press.
        requestObserver = coordinator.$paywallRequests
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.present() }
            }

        // Activating or buying ends the lock, and a wall that stays up after
        // the wall is gone reads as a payment that did not register.
        entitlementObserver = coordinator.$entitlement
            .removeDuplicates()
            .sink { [weak self] state in
                guard state.lock == nil else { return }
                Task { @MainActor in self?.close() }
            }
    }

    /// Whether the price is on screen.
    var isShowing: Bool { window?.isVisible == true }

    /// Shows the offers, or brings them forward if they are already up.
    ///
    /// The telemetry is sent here and only on a fresh appearance, which is the
    /// whole point of the event: `paywall_shown` has to mean a person saw a
    /// price. A second press while the window is already in front of them is
    /// not a second showing.
    func present() {
        guard coordinator.entitlement.lock != nil else { return }

        if let window {
            window.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Witness"
        window.contentView = NSHostingView(
            rootView: PaywallView(
                coordinator: coordinator,
                openLicenseSettings: { [weak self] in self?.openLicenseSettings() },
                dismiss: { [weak self] in self?.close() }
            )
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Above the document being written, and on the Space being looked at:
        // an accessory app has no Dock icon to bounce, so a window that opens
        // behind a full-screen editor is a window that was never shown.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        self.window = window

        Log.licensing.info("Showing the paywall")
        window.orderFrontRegardless()
        coordinator.notePaywallShown()
    }

    func close() {
        window?.close()
    }

    /// Settings is where a pasted key and the device identifier live, and
    /// duplicating them here would mean two places to keep true.
    ///
    /// The selector is the one AppKit exposes for the SwiftUI `Settings` scene
    /// on macOS 14; if a future system renames it the button stops working
    /// rather than crashing, and this line is where to look.
    private func openLicenseSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            Log.application.error("Could not open Settings from the paywall")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// What the window draws.
///
/// Every string with a number in it comes from `LicensePresentation` or
/// `StoreFront`, so this file adds a layout and not a second opinion about the
/// commercial terms.
struct PaywallView: View {
    @ObservedObject var coordinator: DictationCoordinator
    let openLicenseSettings: () -> Void
    let dismiss: () -> Void

    @State private var email = ""
    @State private var isRequesting = false
    @State private var notice: String?

    private var presentation: LicensePresentation {
        LicensePresentation(state: coordinator.entitlement)
    }

    /// The same condition Settings uses, and it matters more here.
    ///
    /// A license is bought in a browser and issued for a Mac, so the address
    /// has to be handed over from inside the app afterwards. The paywall is
    /// exactly where somebody stands when they come back from paying — without
    /// the form they would find the offers they have already taken and no way
    /// in. It stays hidden while there is no service to ask, because a form
    /// that can only refuse is worse than no form.
    private var showsActivationForm: Bool {
        Self.showsActivationForm(presentation, canRequestActivation: coordinator.canRequestActivation)
    }

    /// Pulled out of the view so the rule can be asserted rather than
    /// eyeballed, the way `LicensePresentation` holds the copy for the same
    /// reason.
    static func showsActivationForm(_ presentation: LicensePresentation, canRequestActivation: Bool) -> Bool {
        presentation.showsActivation || (presentation.offersKeyRetrieval && canRequestActivation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            // Offers first when there are any: on an expired trial the thing
            // to do is buy, and the form under it is for the person who
            // already has. When there is nothing to buy yet the form is the
            // whole ask and the order does not arise.
            if presentation.showsOffers { offers }
            if showsActivationForm { activation }

            Divider()
            footer
        }
        .padding(24)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbol)
                .font(.title)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.headline)
                    .font(.title3.weight(.semibold))
                Text(presentation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var activation: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Which errand the form is running changes its title, its button
            // and the sentence under it, and all three come from
            // `LicensePresentation`: starting a trial and fetching a key
            // somebody has already paid for are one call and different words.
            Text(presentation.activationTitle)
                .font(.callout.weight(.medium))
            HStack {
                TextField("Email address", text: $email, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRequesting)
                Button(isRequesting ? "Sending…" : presentation.activationButtonTitle) {
                    Task { await requestActivation() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRequesting || email.isEmpty || !coordinator.canRequestActivation)
            }
            // A dead primary button with nothing beside it reads as a broken
            // app. Settings says this too; a paywall that omitted it would be
            // the one surface where the way forward is invisible.
            Text(
                coordinator.canRequestActivation
                    ? presentation.activationHint
                    : "This build has no activation service yet. Press “Enter a key…” and paste one instead — that path works offline and is what the app checks in either case."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var offers: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Above the buttons, because it is what turns them on. A disabled
            // Buy with its reason underneath is a puzzle.
            if StoreFront.isOpen { CheckoutConsent(coordinator: coordinator) }

            OfferRow(
                title: "Lifetime",
                price: StoreFront.lifetimePrice,
                detail: "Paid once. Covers two Macs and every update to this major version.",
                isBuyable: StoreFront.lifetimeCheckout != nil && coordinator.hasCheckoutConsent
            ) { coordinator.openCheckout(.lifetime) }

            OfferRow(
                title: "Annual",
                price: StoreFront.annualPrice,
                detail: "Renewed each year. Covers two Macs.",
                isBuyable: StoreFront.annualCheckout != nil && coordinator.hasCheckoutConsent
            ) { coordinator.openCheckout(.annual) }

            if !StoreFront.isOpen {
                Text("Checkout is not open yet. When it is, these buttons hand the purchase to Stripe in your browser — the app never sees a card number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Enter a key…", action: openLicenseSettings)
            Spacer()
            Button("Not now", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func requestActivation() async {
        isRequesting = true
        defer { isRequesting = false }
        notice = await coordinator.requestActivation(email: email)?.message
    }
}
