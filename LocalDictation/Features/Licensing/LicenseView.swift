import SwiftUI

/// Settings → License. Where the whole commercial surface of the app lives.
///
/// It is one page rather than a wizard because there are only ever three things
/// a user wants here: what do I have, how do I get the next thing, and which
/// Mac is this. A flow that reveals them one at a time would hide the answer
/// from whoever already knows their question.
struct LicenseView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    @State private var email = ""
    @State private var key = ""
    @State private var isRequesting = false
    @State private var isReleasing = false
    @State private var notice: Notice?

    private enum Notice: Equatable {
        case failure(String)
        case success(String)
    }

    private var presentation: LicensePresentation {
        LicensePresentation(state: coordinator.entitlement)
    }

    var body: some View {
        Form {
            standing

            // The form appears when it is the thing to do, and also when the
            // user may be holding a license this Mac has not been given a key
            // for — but in the second case only if there is a service to ask,
            // because a form that can only refuse is worse than no form.
            if presentation.showsActivation || (presentation.offersKeyRetrieval && coordinator.canRequestActivation) {
                activation
            }

            manualKey

            if presentation.showsOffers {
                offers
            }

            thisMac
        }
        .formStyle(.grouped)
    }

    private var standing: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: presentation.symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.headline)
                        .font(.headline)
                    Text(presentation.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let notice {
                switch notice {
                case let .failure(message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case let .success(message):
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var activation: some View {
        Section(presentation.activationTitle) {
            TextField("Email address", text: $email, prompt: Text("you@example.com"))
                .textFieldStyle(.roundedBorder)
                .disabled(isRequesting)

            HStack {
                Button(isRequesting ? "Sending…" : presentation.activationButtonTitle) {
                    Task { await requestActivation() }
                }
                .disabled(isRequesting || email.isEmpty || !coordinator.canRequestActivation)

                if isRequesting {
                    ProgressView().controlSize(.small)
                }
            }

            Text(
                coordinator.canRequestActivation
                    ? presentation.activationHint
                    : "This build has no activation service yet. Paste a key below instead — that path works offline and is what the app checks in either case."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualKey: some View {
        Section("Enter a key") {
            TextField("License key", text: $key, prompt: Text("LD1.…"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            HStack {
                Button("Use this key") { useKey() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if coordinator.entitlement.license != nil {
                    Button(isReleasing ? "Removing…" : "Remove from this Mac") {
                        Task { await releaseFromThisMac() }
                    }
                    .disabled(isReleasing)
                }
            }

            if !coordinator.licenseAuthorityIsConfigured {
                Text("This is a development build: it carries no authority key, so no license can verify here. Only the ungated window applies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var offers: some View {
        Section("Licenses") {
            OfferRow(
                title: "Lifetime",
                price: StoreFront.lifetimePrice,
                detail: "Paid once. Covers two Macs and every update to this major version.",
                isOpen: StoreFront.lifetimeCheckout != nil
            ) { coordinator.openCheckout(.lifetime) }

            OfferRow(
                title: "Annual",
                price: StoreFront.annualPrice,
                detail: "Renewed each year. Covers two Macs.",
                isOpen: StoreFront.annualCheckout != nil
            ) { coordinator.openCheckout(.annual) }

            if !StoreFront.isOpen {
                Text("Checkout is not open yet. When it is, these buttons hand the purchase to Stripe in your browser — the app never sees a card number.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var thisMac: some View {
        Section("This Mac") {
            if let identifier = coordinator.deviceIdentifier {
                LabeledContent("Identifier", value: identifier)
                    .textSelection(.enabled)
            }
            if let location = coordinator.licenseRecordLocation {
                LabeledContent("Record", value: location)
                    .textSelection(.enabled)
            }
            if let error = coordinator.licenseStoreErrorDescription {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("The identifier is a one-way hash of this Mac's hardware UUID. It is what makes a license cover two Macs rather than any number of them, and it cannot be turned back into a serial number or matched against anything outside this app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func useKey() {
        if let error = coordinator.enterLicenseKey(key) {
            notice = .failure(error.message)
        } else {
            key = ""
            notice = .success("The key was accepted on this Mac.")
        }
    }

    /// Three outcomes, three sentences. The one that matters is the middle one:
    /// the license is gone from this Mac and the slot is not free, so the user
    /// has to be told what to do about it rather than left believing they have
    /// a Mac back.
    private func releaseFromThisMac() async {
        isReleasing = true
        defer { isReleasing = false }

        switch await coordinator.releaseLicenseFromThisMac() {
        case .releasedEverywhere:
            notice = .success(
                "The license was removed from this Mac and the Mac was released, so another one can take its place. "
                    + "The key itself is still good."
            )
        case .removedLocally:
            notice = .success(
                "The license was removed from this Mac. The key itself is still good — use it here again, or on another Mac."
            )
        case let .removedLocallyOnly(reason):
            notice = .failure(
                "Removed from this Mac, but the service could not be told, so this Mac still counts as one of your two. "
                    + "Keep the key from your email: enter it here again and press Remove when you are back online. (\(reason))"
            )
        }
    }

    private func requestActivation() async {
        // Read before the call: a successful one changes the state, and the
        // sentence afterwards has to describe the errand the user actually ran
        // rather than where they ended up.
        let wasRetrieval = presentation.offersKeyRetrieval
        isRequesting = true
        defer { isRequesting = false }
        if let error = await coordinator.requestActivation(email: email) {
            notice = .failure(error.message)
        } else {
            notice = .success(
                wasRetrieval
                    ? "The key for this Mac was accepted."
                    : "Activated. The trial runs for fourteen days from your first dictation."
            )
        }
    }
}

private struct OfferRow: View {
    let title: String
    let price: String
    let detail: String
    let isOpen: Bool
    let buy: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \(price)")
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Buy", action: buy)
                .disabled(!isOpen)
        }
    }
}
