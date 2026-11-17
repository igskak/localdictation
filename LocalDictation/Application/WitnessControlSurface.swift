import SwiftUI

/// Glass belongs to navigation and controls; content keeps an opaque surface.
struct WitnessControlSurface: View {
    var cornerRadius: CGFloat = 13
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency {
            shape.fill(WitnessStyle.surface.opacity(0.82)).glassEffect(.regular, in: shape)
        } else {
            shape.fill(WitnessStyle.surface)
                .overlay { shape.stroke(WitnessStyle.line, lineWidth: 1) }
        }
    }
}

struct WitnessNavigationSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency { WitnessStyle.sidebar }
        else {
            WitnessStyle.sidebar.opacity(0.75)
                .background(.regularMaterial)
                .overlay(alignment: .topLeading) {
                    LinearGradient(colors: [WitnessStyle.accent.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
    }
}
