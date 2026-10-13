import XCTest
@testable import Eddie

final class EditExecutorTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/a.mov")
    let song = URL(fileURLWithPath: "/tmp/s.mp3")

    func project() -> Project {
        Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 4), ClipItem(url: url, sourceStart: 0, sourceEnd: 6)],
                music: [MusicItem(url: song, start: 0, sourceEnd: 10)],
                titles: [TitleItem(text: "Hi", start: 1)])
    }

    func run(_ actions: [EditAction], on p: Project? = nil) -> EditExecutor.Result {
        let p = p ?? project()
        return EditExecutor.apply(actions, to: p, labels: TimelineLabels(p), playhead: 2, sourceDuration: { _ in 60 })
    }

    func testCuttingArrangingAndSpeed() {
        let p = project()
        let r = run([
            EditAction(type: "split", at: 2),
            EditAction(type: "trim", clip: "c2", keep_from: 1, keep_to: 3),     // labels are from before the split
            EditAction(type: "move", clip: "c2", to_position: 1),
            EditAction(type: "speed", clip: "c1", speed: 2),
            EditAction(type: "clip_volume", clip: "all", volume: 50),
        ], on: p)
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(r.project.clips.count, 3)
        XCTAssertEqual(r.project.clips[0].id, p.clips[1].id, "c2 moved first")
        XCTAssertEqual(r.project.clips[0].sourceStart, 1)
        XCTAssertEqual(r.project.clips[0].sourceEnd, 3)
        XCTAssertTrue(r.project.clips.allSatisfy { $0.volume == 0.5 })
        XCTAssertEqual(r.project.clips.first { $0.id == p.clips[0].id }?.speed, 2)
    }

    func testTitlesMusicPresetsColorAndErrors() {
        let r = run([
            EditAction(type: "add_title", at: 0, duration: 2, text: "Day 1", style: "lowerThird", x: 0.2, y: 0.8, size: 1.5, font: "Georgia", color: "#ffcc00"),
            EditAction(type: "edit_title", title: "t1", text: "Hello", rotation: -10),
            EditAction(type: "music", music: "m1", volume: 0.5, starts_at: 20, fade_in: 0),
            EditAction(type: "preset", clip: "all", preset: "warm"),
            EditAction(type: "color", clip: "c1", instruction: "cinematic"),
            EditAction(type: "delete", target: "c9"),
            EditAction(type: "teleport"),
        ])
        XCTAssertEqual(r.project.titles.count, 2)
        let added = r.project.titles[1]
        XCTAssertEqual(added.text, "Day 1"); XCTAssertEqual(added.style, .lowerThird); XCTAssertEqual(added.x, 0.2)
        XCTAssertEqual(added.font, "Georgia"); XCTAssertEqual(added.color, "#FFCC00"); XCTAssertEqual(added.size, 1.5)
        XCTAssertEqual(r.project.titles[0].text, "Hello"); XCTAssertEqual(r.project.titles[0].rotation, -10)
        XCTAssertEqual(r.project.music[0].volume, 0.5); XCTAssertEqual(r.project.music[0].sourceStart, 20)
        XCTAssertEqual(r.project.music[0].duration, 10, accuracy: 1e-9, "same length on the timeline")
        XCTAssertTrue(r.project.clips.allSatisfy { $0.recipe.temperature > 0 })
        XCTAssertEqual(r.color, [ColorRequest(clipIDs: [project().clips[0].id].map { _ in r.project.clips[0].id }, instruction: "cinematic")])
        XCTAssertEqual(r.errors.count, 2, "unknown label and unknown action are reported back to the AI")
    }

    func testDescriptionUsesLabels() {
        let d = TimelineDescriber.describe(project(), playhead: 1)
        XCTAssertTrue(d.contains("c1:") && d.contains("c2:") && d.contains("t1:") && d.contains("m1 ("))
        XCTAssertTrue(d.contains("10.00 s long"))
    }
}

final class EditingAgentLoopTests: XCTestCase {
    func plan(_ reply: String, _ actions: String, done: Bool) -> String {
        #"{"reply":"\#(reply)","actions":\#(actions),"done":\#(done)}"#
    }

    func testRoundsUntilDone() async throws {
        let p = Project(clips: [ClipItem(url: URL(fileURLWithPath: "/tmp/a.mov"), sourceStart: 0, sourceEnd: 4)])
        let model = ScriptedModel([
            plan("Splitting.", #"[{"type":"split","at":2},{"type":"delete","target":"c7"}]"#, done: false),
            plan("Done — split in two.", "[]", done: true),
        ])
        let step = try await EditingAgent(model: model).run(request: "split it", project: p, playhead: 0, frames: [],
                                                            sourceDuration: { _ in 4 }, progress: { _ in })
        XCTAssertEqual(step.project.clips.count, 2)
        XCTAssertEqual(step.reply, "Done — split in two.")
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertTrue(model.requests[1].text.contains("c2:"), "second round sees the updated timeline")
        XCTAssertTrue(model.requests[1].text.contains("Error: delete: unknown c7"), "and the errors")
    }

    @MainActor
    func testAskThroughTheEditorIsOneUndoStep() async throws {
        let model = EditorModel()
        model.open(Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!)
        for _ in 0..<100 where model.player.currentItem == nil { try await Task.sleep(for: .milliseconds(50)) }
        let before = model.project
        model.makeVisionModel = {
            ScriptedModel([
                #"{"reply":"Split it and added a title.","actions":[{"type":"split","at":1},{"type":"add_title","text":"Day 1","at":0}],"done":true}"#,
            ])
        }
        model.ask("split at 1s and add a Day 1 title")
        for _ in 0..<100 where model.busy || model.assistantReply == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.project.clips.count, 2)
        XCTAssertEqual(model.project.titles.first?.text, "Day 1")
        XCTAssertEqual(model.assistantReply, "Split it and added a title.")
        model.undo()
        XCTAssertEqual(model.project, before, "one undo puts everything back")
    }
}

/// Opt-in: a real editing request through DeepSeek. TEST_RUNNER_EDDIE_DEEPSEEK_KEY=… xcodebuild … -only-testing:EddieTests/LiveEditingTests
final class LiveEditingTests: XCTestCase {
    func testRealEditRequest() async throws {
        guard let key = ProcessInfo.processInfo.environment["EDDIE_DEEPSEEK_KEY"] else { throw XCTSkip("no key") }
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        let p = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 10), ClipItem(url: url, sourceStart: 20, sourceEnd: 26)])
        let agent = EditingAgent(model: OpenAICompatibleProvider.deepSeek(apiKey: key, model: "deepseek-flash"))
        let step = try await agent.run(
            request: "Cut the first clip at 4 seconds and delete the part after the cut, put the second clip first, make it play at 2x, add a yellow lower third that says Day 1 at the very start for 3 seconds, and warm everything up.",
            project: p, playhead: 0, frames: [], sourceDuration: { _ in 60 }, progress: { print("[progress]", $0) })
        print("[reply]", step.reply)
        print("[log]", step.log.joined(separator: " | "))
        print("[timeline]\n" + TimelineDescriber.describe(step.project, playhead: 0))
        XCTAssertEqual(step.project.clips.count, 2)
        XCTAssertEqual(step.project.clips[0].speed, 2)
        XCTAssertEqual(step.project.titles.first?.text, "Day 1")
    }
}
