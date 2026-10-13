import AppKit
import SwiftUI

/// Plays a scripted edit in the real app and records the window — the demo video in the README.
///
/// Launch with:
///   open Eddie.app --env EDDIE_DEMO_OUT=/path/demo.mov --env EDDIE_DEMO_CLIP=… --env EDDIE_DEMO_OVERLAY=… --env EDDIE_DEMO_MUSIC=…
/// Eddie needs Screen Recording permission (it records only its own window). The pointer is drawn by Eddie.
@MainActor
final class DemoDirector {
    static var requested: Bool { ProcessInfo.processInfo.environment["EDDIE_DEMO_OUT"] != nil }

    private let model = EditorModel.shared
    private let env = ProcessInfo.processInfo.environment
    private var window: NSWindow!
    private let pointer = DemoPointer()
    private let recorder = WindowRecorder()
    private var marks: [[String: Any]] = []
    private var startTime = Date()

    static func startIfRequested() {
        guard requested else { return }
        let director = DemoDirector()
        Task { @MainActor in
            await director.run()
            NSApp.terminate(nil)
        }
    }

    /// Progress notes next to the output file (demo.log), for when something goes wrong.
    private func log(_ text: String) {
        guard let out = env["EDDIE_DEMO_OUT"] else { return }
        let url = URL(fileURLWithPath: out).deletingLastPathComponent().appendingPathComponent("demo.log")
        let line = "\(Date()) \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    private func mark(_ name: String) {
        marks.append(["name": name, "t": Date().timeIntervalSince(startTime)])
    }

    // MARK: Script

    private func run() async {
        guard let out = env["EDDIE_DEMO_OUT"], let clip = env["EDDIE_DEMO_CLIP"],
              let overlay = env["EDDIE_DEMO_OVERLAY"], let music = env["EDDIE_DEMO_MUSIC"] else { return }
        let outURL = URL(fileURLWithPath: out)
        log("demo starting; screen capture allowed: \(CGPreflightScreenCaptureAccess())")

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "Allow Eddie to record its window"
            alert.informativeText = "Turn on Eddie in System Settings → Privacy & Security → Screen & System Audio Recording, then run the demo again."
            log("no screen recording permission")
            alert.runModal()
            return
        }

        // A clean window at a fixed size.
        await sleep(1.5)
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            log("no window; windows: \(NSApp.windows.map { "\($0.className) visible=\($0.isVisible)" })")
            return
        }
        window = w
        let screen = w.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1400, screen.width - 40), height: min(860, screen.height - 40))
        w.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.createProject()
        // Heavy footage (4K/8K) gets its playback copy before recording, so nothing rebuilds mid-demo.
        log("preparing playback copy")
        _ = try? await MediaCache.makeProxy(for: URL(fileURLWithPath: clip))
        log("playback copy ready")
        await sleep(1.0)
        pointer.show(at: center(of: w.frame))

        do {
            try await recorder.start(window: w, extra: [pointer.window], to: outURL)
        } catch {
            log("recording failed: \(error)")
            return
        }
        startTime = Date()
        log("recording")
        mark("start")
        await sleep(0.8)

        // 1. Open a clip.
        await clickAnchor("open-video") { [self] in model.addClips([URL(fileURLWithPath: clip)]) }
        await waitUntil(15) { [self] in !model.project.clips.isEmpty && !model.clipThumbs.isEmpty }
        await sleep(1.2)

        // 2. Auto Grade with AI.
        mark("ai-start")
        await clickAnchor("auto-grade") { [self] in model.autoGrade() }
        await waitUntil(150) { [self] in !model.busy }
        mark("ai-end")
        await sleep(1.5)

        // 3. Before / after.
        model.compare = true
        model.split = 0.5
        await sleep(0.6)
        if let v = frame("viewer") {
            let y = v.minY + v.height * 0.5
            await drag(from: CGPoint(x: v.minX + v.width * 0.5, y: y), to: CGPoint(x: v.minX + v.width * 0.22, y: y), duration: 0.9) { [self] p in
                model.split = 0.5 - 0.28 * p
            }
            await drag(from: CGPoint(x: v.minX + v.width * 0.22, y: y), to: CGPoint(x: v.minX + v.width * 0.78, y: y), duration: 1.3) { [self] p in
                model.split = 0.22 + 0.56 * p
            }
        }
        await sleep(0.4)
        model.compare = false
        await sleep(0.8)

        // 4. A picture-in-picture overlay: move it, resize it, rotate it on the video.
        mark("overlay")
        model.seek(to: 3)
        await clickAnchor("tool-addOverlay") { [self] in model.addOverlay(URL(fileURLWithPath: overlay), pictureInPicture: true) }
        await waitUntil(10) { [self] in !model.project.overlays.isEmpty }
        if let o = model.project.overlays.first {
            model.selection = o.id
            await sleep(0.8)
            // Into the bottom-right corner, then small, then a slight tilt.
            await dragOverlay(o.id, to: (x: 0.33, y: 0.29), duration: 1.4)
            await resizeOverlay(o.id, to: 0.17, duration: 1.0)
            await rotateOverlay(o.id, to: -10, duration: 0.9)
        }
        await sleep(0.6)

        // 5. A title: type it, then drag it into place.
        mark("title")
        await clickAnchor("tool-title") { [self] in model.addTitle() }
        await sleep(0.5)
        if let t = model.selectedTitle {
            if let field = frame("title-text") { await moveTo(CGPoint(x: field.minX + 40, y: field.midY), duration: 0.5) }
            for (i, _) in "Golden hour".enumerated() {
                let text = String("Golden hour".prefix(i + 1))
                model.updateTitle(t.id, undo: .none) { $0.text = text }
                await sleep(0.07)
            }
            await sleep(0.5)
            // A serif font, then yellow.
            await clickAnchor("title-font") { [self] in model.updateTitle(t.id, undo: .push) { $0.font = "Georgia" } }
            await sleep(0.7)
            await clickAnchor("title-color") { [self] in model.updateTitle(t.id, undo: .push) { $0.color = "#FFD60A" } }
            await sleep(0.7)
            await dragTitle(t.id, to: CGPoint(x: 0.5, y: 0.22), duration: 1.3)
        }
        await sleep(0.6)

        // 6. Music, then drag its fade in longer.
        mark("music-add")
        await clickAnchor("tool-music") { [self] in model.addMusic(URL(fileURLWithPath: music)) }
        await waitUntil(15) { [self] in !model.project.music.isEmpty }
        await sleep(0.8)
        mark("music-ready")
        await sleep(0.4)
        if let m = model.project.music.first {
            model.selection = m.id
            await sleep(0.4)
            await dragFade(block: "music-\(m.id)", duration: m.duration, from: m.fadeIn, to: min(3.5, m.duration / 2.5), atStart: true) { [self] v in
                model.updateMusic(m.id, undo: .none) { $0.fadeIn = v }
            }
        }

        // 7. Fade the picture in from black and out to black.
        mark("fades")
        if let c = model.project.clips.first {
            model.updateClip(c.id, undo: .push) { $0.transitionIn = Transition(kind: .dipToBlack, duration: 0.05) }
            model.setFadeOut(0.05)
            await sleep(0.4)
            let fade = min(1.5, c.duration / 4)
            await dragFade(block: "clip-\(c.id)", duration: c.duration, from: 0.05, to: fade, atStart: true) { [self] v in
                model.updateClip(c.id, undo: .none) { $0.transitionIn = Transition(kind: .dipToBlack, duration: v) }
            }
            await dragFade(block: "clip-\(c.id)", duration: c.duration, from: 0.05, to: fade, atStart: false) { [self] v in
                model.mutate(.none) { $0.fadeOut = v }
            }
        }
        model.selection = model.project.clips.first?.id
        await sleep(0.8)

        // 8. Play it.
        model.seek(to: 0)
        await clickAnchor("play") { [self] in model.togglePlay() }
        mark("play")
        await sleep(min(7.5, model.project.duration + 0.8))
        if model.clock.playing { model.togglePlay() }
        await sleep(1.0)
        mark("end")

        await recorder.stop()
        pointer.hide()
        if let data = try? JSONSerialization.data(withJSONObject: marks, options: .prettyPrinted) {
            try? data.write(to: outURL.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    // MARK: Gestures

    private func dragOverlay(_ id: UUID, to target: (x: Double, y: Double), duration: Double) async {
        guard let o = model.project.overlays.first(where: { $0.id == id }), let v = frame("viewer") else { return }
        let start = o.clip.transform
        let from = overlayCenter(o.clip.transform, source: model.sourceSize(of: o.clip), viewer: v)
        var end = start
        end.x = target.x
        end.y = target.y
        let to = overlayCenter(end, source: model.sourceSize(of: o.clip), viewer: v)
        model.beginInteraction()
        await drag(from: from, to: to, duration: duration) { [self] p in
            model.setFraming(undo: .none) { t in t.x = start.x + (target.x - start.x) * p; t.y = start.y + (target.y - start.y) * p }
        }
        model.endInteraction()
    }

    private func resizeOverlay(_ id: UUID, to scale: Double, duration: Double) async {
        guard let o = model.project.overlays.first(where: { $0.id == id }), let v = frame("viewer") else { return }
        let t0 = o.clip.transform
        let src = model.sourceSize(of: o.clip) ?? model.renderSize
        func corner(_ t: Transform2D) -> CGPoint {
            let g = OverlayCanvas.geometry(source: src, transform: t, render: model.renderSize, view: v.size)
            return CGPoint(x: v.minX + g.center.x + g.size.width / 2, y: v.minY + g.center.y + g.size.height / 2)
        }
        var t1 = t0
        t1.scale = scale
        await moveTo(corner(t0), duration: 0.5)
        model.beginInteraction()
        await drag(from: corner(t0), to: corner(t1), duration: duration) { [self] p in
            model.setFraming(undo: .none) { $0.scale = t0.scale + (scale - t0.scale) * p }
        }
        model.endInteraction()
    }

    private func rotateOverlay(_ id: UUID, to degrees: Double, duration: Double) async {
        guard let o = model.project.overlays.first(where: { $0.id == id }), let v = frame("viewer") else { return }
        let t0 = o.clip.transform
        let src = model.sourceSize(of: o.clip) ?? model.renderSize
        func handle(_ t: Transform2D) -> CGPoint {
            let g = OverlayCanvas.geometry(source: src, transform: t, render: model.renderSize, view: v.size)
            let r = (g.size.height / 2 + 20)
            let a = t.rotation * .pi / 180
            return CGPoint(x: v.minX + g.center.x + r * sin(a), y: v.minY + g.center.y - r * cos(a))
        }
        var t1 = t0
        t1.rotation = degrees
        await moveTo(handle(t0), duration: 0.5)
        model.beginInteraction()
        await drag(from: handle(t0), to: handle(t1), duration: duration) { [self] p in
            model.setFraming(undo: .none) { $0.rotation = t0.rotation + (degrees - t0.rotation) * p }
        }
        model.endInteraction()
    }

    private func dragTitle(_ id: UUID, to target: CGPoint, duration: Double) async {
        guard let t = model.project.titles.first(where: { $0.id == id }), let v = frame("viewer") else { return }
        let n = TitleRenderer.normalizedCenter(t, renderSize: model.renderSize)
        let from = CGPoint(x: v.minX + n.x * v.width, y: v.minY + n.y * v.height)
        let to = CGPoint(x: v.minX + target.x * v.width, y: v.minY + target.y * v.height)
        model.beginInteraction()
        await drag(from: from, to: to, duration: duration) { [self] p in
            model.updateTitle(id, undo: .none) {
                $0.x = Double(n.x + (target.x - n.x) * p)
                $0.y = Double(n.y + (target.y - n.y) * p)
            }
        }
        model.endInteraction()
    }

    /// Drags the fade dot at the top of a timeline block.
    private func dragFade(block: String, duration: Double, from: Double, to: Double, atStart: Bool,
                          set: @escaping (Double) -> Void) async {
        guard let b = frame(block) else { return }
        let pps = b.width / CGFloat(max(0.1, duration))
        func dot(_ v: Double) -> CGPoint {
            let x = atStart ? b.minX + max(16, CGFloat(v) * pps) : b.maxX - max(16, CGFloat(v) * pps)
            return CGPoint(x: x, y: b.minY + 6)
        }
        await moveTo(dot(from), duration: 0.6)
        model.beginInteraction()
        await drag(from: dot(from), to: dot(to), duration: 1.0) { p in set(((from + (to - from) * p) * 10).rounded() / 10) }
        model.endInteraction()
        await sleep(0.3)
    }

    // MARK: Pointer

    private func overlayCenter(_ t: Transform2D, source: CGSize?, viewer v: CGRect) -> CGPoint {
        let g = OverlayCanvas.geometry(source: source ?? model.renderSize, transform: t, render: model.renderSize, view: v.size)
        return CGPoint(x: v.minX + g.center.x, y: v.minY + g.center.y)
    }

    private func frame(_ key: String) -> CGRect? { DemoAnchors.shared.frames[key] }

    /// SwiftUI global (window content, top-left) → screen.
    private func screenPoint(_ p: CGPoint) -> CGPoint {
        guard let content = window.contentView else { return p }
        let inWindow = content.convert(NSPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y), to: nil)
        return window.convertPoint(toScreen: inWindow)
    }

    private func center(of r: NSRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    private var pointerAt = CGPoint.zero

    private func moveTo(_ p: CGPoint, duration: Double) async {
        let target = screenPoint(p)
        let start = pointer.position
        let steps = max(1, Int(duration * 60))
        for i in 1...steps {
            let e = ease(Double(i) / Double(steps))
            pointer.move(to: CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e))
            await sleep(1.0 / 60)
        }
    }

    private func drag(from a: CGPoint, to b: CGPoint, duration: Double, progress: (Double) -> Void) async {
        await moveTo(a, duration: 0.5)
        pointer.press(true)
        await sleep(0.12)
        let sa = screenPoint(a), sb = screenPoint(b)
        let steps = max(1, Int(duration * 60))
        for i in 1...steps {
            let e = ease(Double(i) / Double(steps))
            pointer.move(to: CGPoint(x: sa.x + (sb.x - sa.x) * e, y: sa.y + (sb.y - sa.y) * e))
            progress(e)
            await sleep(1.0 / 60)
        }
        await sleep(0.1)
        pointer.press(false)
    }

    private func clickAnchor(_ key: String, action: () -> Void) async {
        if let f = frame(key) {
            await moveTo(CGPoint(x: f.midX, y: f.midY), duration: 0.7)
            await sleep(0.15)
            pointer.click()
            await sleep(0.15)
        } else {
            log("no anchor \(key)")
        }
        action()
    }

    private func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { await sleep(0.1) }
    }
}

/// The demo's mouse pointer: a small transparent window above Eddie that's included in the recording.
@MainActor
final class DemoPointer {
    let window: NSWindow
    private let arrow = NSImageView()
    private let ring = CAShapeLayer()
    private static let size: CGFloat = 80
    private(set) var position = CGPoint.zero

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        ring.path = CGPath(ellipseIn: CGRect(x: Self.size / 2 - 14, y: Self.size / 2 - 14, width: 28, height: 28), transform: nil)
        ring.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
        ring.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        view.layer?.addSublayer(ring)
        let image = NSCursor.arrow.image
        let hot = NSCursor.arrow.hotSpot
        let s = image.size
        arrow.image = image
        arrow.imageScaling = .scaleNone
        // Put the arrow's hot spot at the window's center.
        arrow.frame = NSRect(x: Self.size / 2 - hot.x, y: Self.size / 2 - (s.height - hot.y), width: s.width, height: s.height)
        view.addSubview(arrow)
        window.contentView = view
    }

    func show(at p: CGPoint) {
        move(to: p)
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }

    func move(to p: CGPoint) {
        position = p
        window.setFrameOrigin(NSPoint(x: p.x - Self.size / 2, y: p.y - Self.size / 2))
    }

    func press(_ down: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        ring.opacity = down ? 1 : 0
        ring.transform = down ? CATransform3DMakeScale(0.8, 0.8, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    func click() {
        press(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.press(false) }
    }
}
