import AVFoundation
import SwiftUI

/// The video, centered on the neutral viewer background. In Split mode a draggable divider
/// shows the camera original on the left and the grade on the right.
struct ViewerView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        let size = model.renderSize
        GeometryReader { geo in
            let fitted = fit(size, in: geo.size)
            ZStack {
                PlayerLayerView(player: model.player)
                if model.compare {
                    WipeOverlay(split: $model.split)
                }
                OverlayCanvas(clock: model.clock, size: fitted)
                TitleCanvas(clock: model.clock, size: fitted)
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                ExportBar()
                RecordingBar(recorder: model.recorder, clock: model.clock)
            }
            .animation(.easeOut(duration: 0.2), value: model.exportProgress == nil)
        }
        .padding(20)
        .background(Color.black)
    }

    private func fit(_ content: CGSize, in box: CGSize) -> CGSize {
        let scale = min(max(1, box.width) / content.width, max(1, box.height) / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
}

/// Direct manipulation of titles on the video: drag to move (snaps to the center lines),
/// corner handles to resize, the top handle to rotate (snaps to straight angles), click to select.
struct TitleCanvas: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject var clock: PlaybackClock
    let size: CGSize
    @State private var origin: TitleItem?
    @State private var startDistance: CGFloat = 1
    @State private var centerGuideX = false
    @State private var centerGuideY = false
    @State private var hovered: UUID?
    @GestureState private var dragActive = false

    var body: some View {
        let render = model.renderSize
        let scale = size.width / max(1, render.width)
        ZStack {
            if centerGuideX {
                Rectangle().fill(Color.yellow).frame(width: 1, height: size.height).position(x: size.width / 2, y: size.height / 2)
            }
            if centerGuideY {
                Rectangle().fill(Color.yellow).frame(width: size.width, height: 1).position(x: size.width / 2, y: size.height / 2)
            }
            ForEach(model.project.titles.filter { clock.time >= $0.start && clock.time < $0.end }) { title in
                box(title, render: render, scale: scale)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "canvas")
        // A drag the system cancels still ends the edit.
        .onChange(of: dragActive) { _, active in if !active, origin != nil { end() } }
    }

    private func center(_ t: TitleItem, render: CGSize) -> CGPoint {
        let n = TitleRenderer.normalizedCenter(t, renderSize: render)
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }

    private func box(_ title: TitleItem, render: CGSize, scale: CGFloat) -> some View {
        let selected = model.selection == title.id
        let s = TitleRenderer.boxSize(title, renderSize: render)
        let w = max(20, s.width * scale), h = max(14, s.height * scale)
        return ZStack {
            // Outline only when selected; a faint one on hover so you can find the title.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(selected ? 0.9 : (hovered == title.id ? 0.35 : 0)), lineWidth: 1))
                .gesture(moveGesture(title, render: render))
                .onTapGesture { model.selection = title.id }
                .onHover { hovered = $0 ? title.id : (hovered == title.id ? nil : hovered) }
                .pointerStyle(origin?.id == title.id ? .grabActive : .grabIdle)
            if selected {
                ForEach(0..<4, id: \.self) { corner in
                    handle()
                        .padding(5)   // bigger target than the visible square
                        .contentShape(Rectangle())
                        .position(x: corner % 2 == 0 ? 0 : w, y: corner < 2 ? 0 : h)
                        .gesture(resizeGesture(title, render: render))
                        .pointerStyle(.frameResize(position: Self.cornerPosition(corner)))
                }
                // Rotation handle above the top edge.
                Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1, height: 18).position(x: w / 2, y: -9)
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
                    .contentShape(Circle())
                    .position(x: w / 2, y: -20)
                    .gesture(rotateGesture(title, render: render))
                    .pointerStyle(.image(Image(nsImage: Self.rotateCursor), hotSpot: .center))
            }
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(title.rotation))
        .position(center(title, render: render))
    }

    /// Corners in order: top-left, top-right, bottom-left, bottom-right.
    static func cornerPosition(_ corner: Int) -> FrameResizePosition {
        switch corner {
        case 0: return .topLeading
        case 1: return .topTrailing
        case 2: return .bottomLeading
        default: return .bottomTrailing
        }
    }

    /// A circular-arrow cursor (black with a white outline, readable on any footage).
    static let rotateCursor: NSImage = {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        if let symbol = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90", accessibilityDescription: "Rotate")?
            .withSymbolConfiguration(config) {
            let r = NSRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                           width: symbol.size.width, height: symbol.size.height)
            func tinted(_ color: NSColor) -> NSImage {
                let t = NSImage(size: symbol.size)
                t.lockFocus()
                symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                color.set()
                NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
                t.unlockFocus()
                return t
            }
            let halo = tinted(.white), ink = tinted(.black)
            for dx in [-1.5, 0, 1.5] { for dy in [-1.5, 0, 1.5] { halo.draw(in: r.offsetBy(dx: dx, dy: dy)) } }
            ink.draw(in: r)
        }
        image.unlockFocus()
        return image
    }()

    private func handle() -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.5), radius: 2)
    }

    private func begin(_ title: TitleItem) {
        guard origin == nil else { return }
        origin = title
        model.selection = title.id
        model.beginInteraction()
    }

    private func end() {
        origin = nil
        centerGuideX = false
        centerGuideY = false
        model.endInteraction()
    }

    private func moveGesture(_ title: TitleItem, render: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { v in
                begin(title)
                guard let o = origin else { return }
                let c = center(o, render: render)
                var x = (c.x + v.translation.width) / size.width
                var y = (c.y + v.translation.height) / size.height
                // Snap to the frame's center lines.
                centerGuideX = abs(x - 0.5) * size.width < 6
                centerGuideY = abs(y - 0.5) * size.height < 6
                if centerGuideX { x = 0.5 }
                if centerGuideY { y = 0.5 }
                let nx = Double(min(max(x, 0), 1)), ny = Double(min(max(y, 0), 1))
                model.updateTitle(title.id, undo: .none) { $0.x = nx; $0.y = ny }
            }
            .onEnded { _ in end() }
    }

    private func resizeGesture(_ title: TitleItem, render: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { v in
                if origin == nil {
                    begin(title)
                    let c = center(title, render: render)
                    startDistance = max(1, hypot(v.startLocation.x - c.x, v.startLocation.y - c.y))
                }
                guard let o = origin else { return }
                let c = center(o, render: render)
                let d = hypot(v.location.x - c.x, v.location.y - c.y)
                let newSize = min(max(o.size * Double(d / startDistance), 0.3), 4)
                let n = TitleRenderer.normalizedCenter(o, renderSize: render)
                model.updateTitle(title.id, undo: .none) { t in
                    t.size = newSize
                    t.x = Double(n.x); t.y = Double(n.y)   // keep it centered where it is
                }
            }
            .onEnded { _ in end() }
    }

    private func rotateGesture(_ title: TitleItem, render: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { v in
                begin(title)
                guard let o = origin else { return }
                let c = center(o, render: render)
                var deg = Double(atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi) + 90
                if deg > 180 { deg -= 360 }
                // Snap to straight angles.
                for snap in [-180.0, -90, 0, 90, 180] where abs(deg - snap) < 4 { deg = snap == -180 ? 180 : snap }
                let n = TitleRenderer.normalizedCenter(o, renderSize: render)
                model.updateTitle(title.id, undo: .none) { t in
                    t.rotation = deg
                    t.x = Double(n.x); t.y = Double(n.y)
                }
            }
            .onEnded { _ in end() }
    }
}

struct WipeOverlay: View {
    @Binding var split: Double
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * split
            ZStack(alignment: .top) {
                // Divider line
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 1, height: geo.size.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: x, y: geo.size.height / 2)
                // Grip: a slim glass pill with two small chevrons
                HStack(spacing: 3) {
                    Image(systemName: "chevron.compact.left")
                    Image(systemName: "chevron.compact.right")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 52)
                .glass(in: Capsule(), interactive: true)
                .scaleEffect(dragging ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
                .position(x: x, y: geo.size.height / 2)
                // Corner labels
                HStack {
                    tag("ORIGINAL")
                    Spacer()
                    tag("GRADED")
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    split = min(max(v.location.x / geo.size.width, 0), 1)
                }
                .onEnded { _ in dragging = false })
            .pointerStyle(.columnResize)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glass(in: Capsule())
    }
}

/// Direct manipulation of overlays (B-roll, photos, picture-in-picture) on the video, like titles:
/// drag to move (snaps to the center lines), corners to resize, the top handle to rotate.
/// Edits the framing at the playhead, so animated (keyframed) overlays get a keyframe there.
struct OverlayCanvas: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject var clock: PlaybackClock
    let size: CGSize
    @State private var origin: Transform2D?
    @State private var startDistance: CGFloat = 1
    @State private var guideX = false
    @State private var guideY = false
    @State private var hovered: UUID?
    @GestureState private var dragActive = false

    var body: some View {
        ZStack {
            ForEach(model.project.overlays.filter { clock.time >= $0.start && clock.time < $0.end }) { item in
                box(item)
            }
            if guideX {
                Rectangle().fill(Color.yellow).frame(width: 1, height: size.height).position(x: size.width / 2, y: size.height / 2)
            }
            if guideY {
                Rectangle().fill(Color.yellow).frame(width: size.width, height: 1).position(x: size.width / 2, y: size.height / 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "overlayCanvas")
        .onChange(of: dragActive) { _, active in if !active, origin != nil { end() } }
    }

    private func transform(_ item: OverlayItem) -> Transform2D {
        item.clip.transform(at: min(max(0, clock.time - item.start), item.clip.duration))
    }

    private func geometry(_ item: OverlayItem, _ t: Transform2D) -> (center: CGPoint, size: CGSize) {
        Self.geometry(source: model.sourceSize(of: item.clip) ?? model.renderSize, transform: t, render: model.renderSize, view: size)
    }

    /// An overlay's picture on screen: center and size in viewer points (same math as the renderer's `place`, fit mode).
    static func geometry(source: CGSize, transform t: Transform2D, render: CGSize, view: CGSize) -> (center: CGPoint, size: CGSize) {
        let w = max(1, source.width * CGFloat(max(0.05, 1 - t.cropLeft - t.cropRight)))
        let h = max(1, source.height * CGFloat(max(0.05, 1 - t.cropTop - t.cropBottom)))
        let base = min(render.width / w, render.height / h)
        let s = base * CGFloat(t.scale) * view.width / max(1, render.width)
        return (CGPoint(x: (0.5 + CGFloat(t.x)) * view.width, y: (0.5 + CGFloat(t.y)) * view.height),
                CGSize(width: w * s, height: h * s))
    }

    private func box(_ item: OverlayItem) -> some View {
        let selected = model.selection == item.id
        let t = transform(item)
        let g = geometry(item, t)
        let w = max(16, g.size.width), h = max(16, g.size.height)
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(selected ? 0.9 : (hovered == item.id ? 0.35 : 0)), lineWidth: 1))
                .gesture(moveGesture(item))
                .onTapGesture { model.selection = item.id }
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                .pointerStyle(origin != nil ? .grabActive : .grabIdle)
            if selected {
                ForEach(0..<4, id: \.self) { corner in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(5)
                        .contentShape(Rectangle())
                        .position(x: corner % 2 == 0 ? 0 : w, y: corner < 2 ? 0 : h)
                        .gesture(resizeGesture(item))
                        .pointerStyle(.frameResize(position: TitleCanvas.cornerPosition(corner)))
                }
                Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1, height: 18).position(x: w / 2, y: -9)
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
                    .contentShape(Circle())
                    .position(x: w / 2, y: -20)
                    .gesture(rotateGesture(item))
                    .pointerStyle(.image(Image(nsImage: TitleCanvas.rotateCursor), hotSpot: .center))
            }
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(t.rotation))
        .position(g.center)
    }

    private func begin(_ item: OverlayItem) {
        guard origin == nil else { return }
        origin = transform(item)
        model.selection = item.id
        model.beginInteraction()
    }

    private func end() {
        origin = nil
        guideX = false
        guideY = false
        model.endInteraction()
    }

    private func moveGesture(_ item: OverlayItem) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("overlayCanvas"))
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { v in
                begin(item)
                guard let o = origin else { return }
                var x = o.x + Double(v.translation.width / size.width)
                var y = o.y + Double(v.translation.height / size.height)
                // Snap its center to the frame's center lines.
                guideX = abs(x) * size.width < 6
                guideY = abs(y) * size.height < 6
                if guideX { x = 0 }
                if guideY { y = 0 }
                let nx = min(max(x, -1), 1), ny = min(max(y, -1), 1)
                model.setFraming(undo: .none) { $0.x = nx; $0.y = ny }
            }
            .onEnded { _ in end() }
    }

    private func resizeGesture(_ item: OverlayItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("overlayCanvas"))
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { v in
                if origin == nil {
                    begin(item)
                    let c = geometry(item, transform(item)).center
                    startDistance = max(1, hypot(v.startLocation.x - c.x, v.startLocation.y - c.y))
                }
                guard let o = origin else { return }
                let c = geometry(item, o).center
                let d = hypot(v.location.x - c.x, v.location.y - c.y)
                let scale = min(max(o.scale * Double(d / startDistance), 0.05), 5)
                model.setFraming(undo: .none) { $0.scale = scale }
            }
            .onEnded { _ in end() }
    }

    private func rotateGesture(_ item: OverlayItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("overlayCanvas"))
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { v in
                begin(item)
                guard let o = origin else { return }
                let c = geometry(item, o).center
                var deg = Double(atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi) + 90
                if deg > 180 { deg -= 360 }
                for snap in [-180.0, -90, 0, 90, 180] where abs(deg - snap) < 4 { deg = snap == -180 ? 180 : snap }
                model.setFraming(undo: .none) { $0.rotation = deg }
            }
            .onEnded { _ in end() }
    }
}

/// A bare AVPlayerLayer (no system controls; Eddie draws its own timeline).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// While a voiceover records: a big, always-visible Stop button over the video with the elapsed time.
struct RecordingBar: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject var recorder: VoiceRecorder
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        if recorder.isRecording {
            let elapsed = max(0, clock.time - model.recordStart)
            Button { model.toggleVoiceover() } label: {
                HStack(spacing: 10) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                        .opacity(Int(elapsed * 2) % 2 == 0 ? 1 : 0.35)
                    Text(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: 6 + CGFloat(min(1, recorder.level * 3)) * 40, height: 4)
                        .frame(width: 46, alignment: .leading)
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 11))
                        Text("Stop").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.red))
                }
                .foregroundStyle(.white)
                .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
                .glass(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop recording (Space or Esc)")
            .padding(.top, 28)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// While exporting: the file name, a progress bar with the percentage, and Cancel — at the top of the viewer.
struct ExportBar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        if let p = model.exportProgress {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Exporting \(model.exportingName ?? "video")")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(Int((p * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Ink.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Color.white).frame(width: max(4, geo.size.width * p))
                        }
                    }
                    .frame(height: 4)
                    .animation(.linear(duration: 0.25), value: p)
                }
                Button { model.cancelExport() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Cancel the export")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: 340)
            .glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
