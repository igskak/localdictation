import SwiftUI

struct NotetakerDemoBadge: View {
    var body: some View {
        Text("Demo")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WitnessStyle.muted)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(WitnessStyle.surface.opacity(0.8), in: Capsule())
    }
}

struct NotetakerDemoNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Notetaker is in demo", systemImage: "info.circle")
                .font(.callout.weight(.medium))
            Text("Speaker separation is still being improved. Speaker labels may be inaccurate; check them against the conversation.")
                .font(.caption).foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(padding: 12)
    }
}
