import AppKit
import SwiftUI
import XCTest
@testable import Eddie

/// Opt-in: renders the main window offscreen to PNGs so the UI can be reviewed without a screen.
///   TEST_RUNNER_EDDIE_SNAPSHOT_OUT=/tmp/shots xcodebuild ... test -only-testing:EddieTests/SnapshotTests
/// The video layer itself is not captured by offscreen rendering; everything else is.
final class SnapshotTests: XCTestCase {
    @MainActor
    func testRenderWindow() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["EDDIE_SNAPSHOT_OUT"] else { throw XCTSkip("EDDIE_SNAPSHOT_OUT not set") }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        UserDefaults.standard.removeObject(forKey: "inspector.framingOpen")
        let model = EditorModel()
        try snapshot(model, to: dir.appendingPathComponent("1_empty.png"))

        let clipURL = env["EDDIE_LIVE_CLIP"].map(URL.init(fileURLWithPath:))
            ?? Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        model.open(clipURL)
        try await waitUntil { !model.clipThumbs.isEmpty && !model.presetThumbs.isEmpty }
        try snapshot(model, to: dir.appendingPathComponent("2_opened.png"))

        // Build a small edit: a second copy of the clip, split it, speed one piece up, add a song.
        model.addClips([clipURL])
        try await waitUntil { model.project.clips.count == 2 }
        model.seek(to: model.project.duration * 0.75)
        model.splitAtPlayhead()
        model.setSpeed(2)
        let music = Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        model.seek(to: 2)
        model.addMusic(music)
        try await waitUntil { !model.project.music.isEmpty }
        model.selection = model.project.clips[0].id
        try await waitUntil { model.clipThumbs.count == model.project.clips.count }

        model.makeVisionModel = {
            ScriptedModel(["""
            {"analysis":"Dim indoor night scene with a blue-lavender cast. I brightened it, opened the shadows and neutralized the walls.","satisfied":true,\
            "recipe":{"exposure":0.45,"contrast":10,"highlights":-12,"shadows":15,"whites":5,"blacks":0,"temperature":45,"tint":-30,"vibrance":18,"saturation":4}}
            """])
        }
        model.refine("make it natural")
        try await waitUntil { !model.busy && model.note != nil }
        model.compare = true
        model.split = 0.4
        model.seek(to: model.clock.duration * 0.3)
        try await Task.sleep(for: .seconds(1.5))
        try snapshot(model, to: dir.appendingPathComponent("3_graded.png"))

        model.apply(Preset.all.first { $0.name == "Mono" }!)
        try await Task.sleep(for: .seconds(1.2))
        try snapshot(model, to: dir.appendingPathComponent("5_mono.png"))
        model.apply(Preset.all.first { $0.name == "Mono" }!)

        // Mid-request: a slow model so the loading state can be captured.
        model.seek(to: 4)
        model.compare = false
        model.addTitle(style: .title)
        if let id = model.selectedTitle?.id {
            model.updateTitle(id, undo: .push) { t in t.text = "Day 1"; t.x = 0.3; t.y = 0.3; t.rotation = -8; t.font = "Georgia"; t.italic = true }
        }
        try await Task.sleep(for: .seconds(1))
        try snapshot(model, to: dir.appendingPathComponent("6_title.png"))
        model.selection = model.project.clips[0].id

        model.makeVisionModel = { SlowModel() }
        model.refine("Make it a bit more cinematic")
        try await Task.sleep(for: .seconds(1))
        try snapshot(model, to: dir.appendingPathComponent("4_busy.png"))
        model.cancelAI()

        model.assistantReply = String(repeating: "I added two titles — “Casa Jardín” over the first shot and “Una tarde en el jardín” later — and kept the original sound. ", count: 8)
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(model, to: dir.appendingPathComponent("8_long_reply.png"))
        model.assistantReply = nil

        // The mid-tier editor: media bin, overlay PiP, transitions, markers, audio lanes, framing.
        UserDefaults.standard.set(true, forKey: "showMediaBin")
        UserDefaults.standard.set(true, forKey: "inspector.framingOpen")
        let blue = Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")!
        let photo = Bundle(for: Self.self).url(forResource: "photo_test", withExtension: "jpg")!
        model.importToBin([blue, photo, music])
        model.seek(to: 1)
        model.addOverlay(blue, pictureInPicture: true)
        try await waitUntil { !model.project.overlays.isEmpty }
        model.setTransition(Transition(kind: .crossDissolve, duration: 0.8), for: model.project.clips[1].id)
        model.setFadeOut(1.5)
        model.setTransition(Transition(kind: .dipToBlack, duration: 0.4), for: model.project.clips[0].id)
        model.updateClip(model.project.clips[1].id, undo: .push) { $0.audioFadeIn = 0.3; $0.audioFadeOut = 0.4 }
        model.seek(to: 3); model.addMarker()
        model.seek(to: 5); model.addMarker()
        model.addMusic(music, at: 1, kind: .effect)
        try await waitUntil { model.project.music.count == 2 }
        model.updateMusic(model.project.music[0].id, undo: .push) { $0.beats = stride(from: 0.0, to: 6, by: 0.5).map { $0 } }
        model.seek(to: 1.5)
        model.selection = model.project.overlays[0].id
        try await Task.sleep(for: .seconds(1.5))
        try snapshot(model, to: dir.appendingPathComponent("9_editor.png"))
        model.selection = nil
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(model, to: dir.appendingPathComponent("10_project.png"))
        // A smaller window with the media panel and inspector open: everything fits, nothing is cut off.
        model.selection = model.project.clips[0].id
        try await Task.sleep(for: .milliseconds(300))
        try snapshot(model, to: dir.appendingPathComponent("12_small.png"), size: NSSize(width: 1146, height: 726))
        try snapshot(model, to: dir.appendingPathComponent("13_min.png"), size: NSSize(width: 980, height: 640))
        // Trimming keeps the timeline's scale: the edit gets shorter on screen instead of stretching to fill.
        let first = model.project.clips[0]
        model.trimClip(first.id, end: first.sourceStart + first.duration * 0.4)
        model.toggleLaneMute(Project.clipSoundLane)
        try await Task.sleep(for: .milliseconds(800))
        try snapshot(model, to: dir.appendingPathComponent("11_trimmed.png"))
        UserDefaults.standard.removeObject(forKey: "showMediaBin")
        UserDefaults.standard.removeObject(forKey: "inspector.framingOpen")

        try await Task.sleep(for: .seconds(1))
        model.saveNow()
        _ = try? model.library.duplicate(model.currentProjectID!)
        model.showProjects()
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(model, to: dir.appendingPathComponent("7_projects.png"))
    }

    @MainActor
    private func snapshot(_ model: EditorModel, to url: URL, size: NSSize = NSSize(width: 1440, height: 900)) throws {
        let controller = NSHostingController(rootView: ContentView().environmentObject(model))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let frameView = window.contentView!.superview!
        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
    }

    @MainActor
    private func waitUntil(timeout: Double = 20, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Never answers within the test's time frame.
final class SlowModel: VisionModel {
    let displayName = "Slow"
    func complete(_ request: VisionRequest) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "{}"
    }
}
