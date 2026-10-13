import SwiftUI

/// A slider that's one capsule: name inside on the left, value on the right, a white fill for the amount.
/// Drag anywhere on it (relative, so it never jumps), double-click to reset.
struct PillSlider: View {
    let label: String
    let value: String
    @Binding var amount: Double
    let range: ClosedRange<Double>
    var origin: Double? = nil
    var reset: Double? = nil
    var height: CGFloat = 28
    /// A faint color strip that shows what the slider does (temperature, tint…).
    var track: [Color]? = nil
    /// Show the value dimmed when it's at its default.
    var dimAtDefault = false
    @Environment(\.isEnabled) private var enabled
    @State private var start: Double?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let span = range.upperBound - range.lowerBound
            let frac = { (v: Double) in CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) }
            let o = frac(origin ?? range.lowerBound) * w, x = frac(amount) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                if let track {
                    Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)).opacity(0.22)
                }
                // The amount: filled from the origin (the middle for left/right style knobs).
                Rectangle()
                    .fill(Color.white.opacity(start == nil ? 0.2 : 0.28))
                    .frame(width: abs(x - o))
                    .offset(x: min(x, o))
                HStack {
                    Text(label).foregroundStyle(Ink.primary)
                    Spacer(minLength: 6)
                    Text(value)
                        .foregroundStyle(dimAtDefault && reset.map { abs(amount - $0) < span * 0.002 } == true ? Ink.tertiary : Ink.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 11)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    guard enabled else { return }
                    if start == nil { start = amount }
                    var v = (start ?? amount) + Double(g.translation.width / w) * span
                    v = min(max(v, range.lowerBound), range.upperBound)
                    if let r = reset, abs(v - r) < span * 0.012 { v = r }   // gentle snap to the default
                    amount = v
                }
                .onEnded { _ in start = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled, let r = reset { amount = r } })
            .pointerStyle(.columnResize)
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: start == nil)
        .help(reset != nil ? "Drag to adjust · double-click to reset" : "Drag to adjust")
    }
}

/// A group of related controls on a Liquid Glass card.
struct GlassCard<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Ink.tertiary)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Small glass button for actions inside cards (Keyframe, Slow zoom…).
struct GlassPillButton: View {
    let title: String
    let icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule(), interactive: true)
    }
}
