import SwiftUI

/// Where named controls are on screen, so the demo can move its pointer to them.
/// Only active while a demo recording runs (`DemoAnchors.enabled`); otherwise it costs nothing.
@MainActor
final class DemoAnchors {
    static let shared = DemoAnchors()
    nonisolated(unsafe) static var enabled = false
    /// Frames in SwiftUI's global space (the window's content, top-left origin).
    var frames: [String: CGRect] = [:]
}

private struct DemoAnchor: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                let frame = g.frame(in: .global)
                Color.clear
                    .onAppear { DemoAnchors.shared.frames[key] = frame }
                    .onChange(of: frame) { _, f in DemoAnchors.shared.frames[key] = f }
            }
        )
    }
}

extension View {
    /// Names this view for the demo recording.
    @ViewBuilder
    func demoAnchor(_ key: String) -> some View {
        if DemoAnchors.enabled { modifier(DemoAnchor(key: key)) } else { self }
    }
}
