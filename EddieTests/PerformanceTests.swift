import XCTest
@testable import Eddie

/// The things that keep editing smooth: only real changes rebuild playback, autosave writes in the
/// background (in order), the preview can render smaller, and the clock doesn't flood the UI.
@MainActor
final class PerformanceTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/clip.mov")

    func testOnlyRealChangesRebuildPlayback() {
        var p = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 4)])
        p.titles = [TitleItem(text: "Hi", start: 0, duration: 1, style: .title)]
        let key = EditorModel.StructureKey(p)
        var moved = p
        moved.titles[0].start = 2
        moved.effects = [EffectItem(kind: .blur, start: 1)]
        moved.clips[0].recipe.exposure = 0.5
        XCTAssertEqual(EditorModel.StructureKey(moved), key, "titles, effects and grades are drawn live")
        var trimmed = p
        trimmed.clips[0].sourceEnd = 3
        XCTAssertNotEqual(EditorModel.StructureKey(trimmed), key, "a trim needs a new composition")
        var louder = p
        louder.clips[0].volume = 0.5
        XCTAssertNotEqual(EditorModel.StructureKey(louder), key)
    }

    func testBackgroundAutosaveStaysInOrder() throws {
        let lib = ProjectLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent("EddieLib-\(UUID().uuidString)"))
        let info = try lib.create()
        var p = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 4)])
        for i in 1...5 {
            p.clips[0].sourceEnd = Double(4 + i)
            try lib.save(p, id: info.id, background: true)
        }
        XCTAssertEqual(try lib.read(info.id), p, "reading waits for pending background writes")
        try lib.save(p, id: info.id, background: true)
        try lib.rename(info.id, to: "Renamed")
        let reopened = ProjectLibrary(root: lib.root)
        XCTAssertEqual(reopened.info(info.id)?.name, "Renamed", "an autosave queued earlier doesn't undo a rename")
        try lib.save(p, id: info.id, background: true)
        try lib.delete(info.id)
        XCTAssertNil(ProjectLibrary(root: lib.root).info(info.id), "a queued autosave doesn't bring a deleted project back")
    }

    func testPreviewQualityShrinksTheViewerOnly() async throws {
        let blue = Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")!
        let model = EditorModel()
        _ = await AgentTools.handle("new_project", ["name": "Perf \(UUID().uuidString.prefix(4))"], model: model)
        _ = await AgentTools.handle("add_media", ["paths": [blue.path], "as": "clip"], model: model)
        let full = model.renderSize
        model.previewQuality = .half
        XCTAssertEqual(model.renderSize.width, (full.width / 4).rounded() * 2, accuracy: 2)
        XCTAssertEqual(model.projectSize, full, "the project (and export) stay full size")
        model.previewQuality = .full
        XCTAssertEqual(model.renderSize, full)
    }

    func testDragChangesAreShownOncePerFrame() async throws {
        let model = EditorModel()
        _ = await AgentTools.handle("new_project", ["name": "Drag \(UUID().uuidString.prefix(4))"], model: model)
        let blue = Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")!
        _ = await AgentTools.handle("add_media", ["paths": [blue.path], "as": "clip"], model: model)
        model.mutate { $0.titles.append(TitleItem(text: "Hi", start: 0, duration: 1, style: .title)) }
        let id = try XCTUnwrap(model.project.titles.first?.id)
        var redraws = 0
        let sub = model.objectWillChange.sink { redraws += 1 }
        model.beginInteraction()
        for i in 1...50 { model.updateTitle(id, undo: .none) { $0.start = Double(i) / 10 } }
        XCTAssertLessThanOrEqual(redraws, 2, "50 mouse moves in one frame don't redraw 50 times")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.project.titles.first?.start, 5, "the latest change shows on the next frame")
        model.updateTitle(id, undo: .none) { $0.start = 6 }
        model.endInteraction()
        XCTAssertEqual(model.project.titles.first?.start, 6, "ending the drag applies what's pending")
        model.undo()
        XCTAssertNotEqual(model.project.titles.first?.start, 6, "the whole drag is one undo step")
        sub.cancel()
    }

    func testCoarseClockThrottlesWhilePlaying() {
        let clock = PlaybackClock()
        var fired = 0
        let sub = clock.coarse.objectWillChange.sink { fired += 1 }
        for i in 0..<30 { clock.time = Double(i) / 30 }
        XCTAssertEqual(fired, 30, "paused (scrubbing): every change shows")
        XCTAssertEqual(clock.coarse.time, 29.0 / 30)
        sub.cancel()
    }
}
