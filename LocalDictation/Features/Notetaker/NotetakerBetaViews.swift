import SwiftUI

struct NotetakerBetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WitnessStyle.muted)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(WitnessStyle.raisedSurface, in: Capsule())
    }
}

struct NotetakerSpeakerLabelNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").accessibilityHidden(true)
            Text("Speaker labels may be inaccurate. Verify who spoke.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(WitnessStyle.muted)
    }
}
