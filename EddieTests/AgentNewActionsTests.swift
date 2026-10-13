import XCTest
@testable import Eddie

/// The AI's tools for captions, looks, sound and motion (shared by "Ask Eddie" and MCP agents).
final class AgentNewActionsTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/clip.mov")

    func project() -> Project {
        var p = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 4), ClipItem(url: url, sourceStart: 4, sourceEnd: 8)])
        p.clips[1].id = UUID()
        p.overlays = [OverlayItem(clip: ClipItem(url: url, sourceStart: 0, sourceEnd: 2), start: 1)]
        p.music = [MusicItem(url: url, start: 0, sourceEnd: 6)]
        var cap = TitleItem(text: "hello there", start: 0.5, duration: 1.5, style: .caption)
        cap.isCaption = true
        p.titles = [cap]
        return p
    }

    func run(_ actions: [EditAction], on p: Project) -> EditExecutor.Result {
        EditExecutor.apply(actions, to: p, labels: TimelineLabels(p), playhead: 1, sourceDuration: { _ in 8 })
    }

    func testTimedEffects() {
        var glitch = EditAction(type: "effect"); glitch.kind = "glitch"; glitch.at = 2; glitch.duration = 1.5
        var r = run([glitch], on: project())
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.project.effects.map(\.start), [2]); XCTAssertEqual(r.project.effects.map(\.duration), [1.5])
        XCTAssertTrue(TimelineDescriber.describe(r.project, playhead: 0).contains("e1: glitch"))
        var move = EditAction(type: "effect"); move.target = "e1"; move.at = 5; move.amount = 0.3
        r = run([move], on: r.project)
        XCTAssertEqual(r.project.effects.first?.start, 5); XCTAssertEqual(r.project.effects.first?.amount, 0.3)
        XCTAssertEqual(r.project.effects.first?.kind, .glitch)
        var del = EditAction(type: "delete"); del.target = "e1"
        XCTAssertEqual(run([del], on: r.project).project.effects, [])
        // Overlays still take their own effects.
        var o = EditAction(type: "effect"); o.target = "o1"; o.kind = "blur"
        let ro = run([o], on: project())
        XCTAssertEqual(ro.project.overlays[0].clip.effects.map(\.kind), [.blur]); XCTAssertEqual(ro.project.effects, [])
    }

    func testCaptionActions() {
        var a = EditAction(type: "caption_style"); a.preset = "Highlight"
        var b = EditAction(type: "add_caption"); b.text = "Second line"; b.at = 3; b.duration = 1
        var c = EditAction(type: "translate_captions"); c.language = "Spanish"; c.bilingual = true
        let r = run([a, b, c, EditAction(type: "remove_fillers"), { var x = EditAction(type: "remove_pauses"); x.duration = 1.2; return x }()], on: project())
        XCTAssertEqual(r.errors, [])
        let caps = r.project.captions
        XCTAssertEqual(caps.count, 2)
        XCTAssertTrue(caps.allSatisfy(\.wordHighlight), "the new caption takes the captions' look")
        XCTAssertEqual(r.jobs, [.translateCaptions(language: "Spanish", bilingual: true), .removeFillers, .removePauses(minimum: 1.2)])

        var script = EditAction(type: "captions_from_text"); script.text = "One\nTwo\nThree"
        let r2 = run([script], on: project())
        XCTAssertEqual(r2.project.captions.map(\.text), ["One", "Two", "Three"], "replaces the old captions by default")
    }

    func testLookActions() {
        var effect = EditAction(type: "effect"); effect.clip = "c1"; effect.kind = "vhs"; effect.amount = 0.8
        var mask = EditAction(type: "mask"); mask.clip = "o1"; mask.kind = "circle"; mask.size = 0.5; mask.feather = 0.3
        var key = EditAction(type: "green_screen"); key.clip = "o1"; key.amount = 0.5
        var blend = EditAction(type: "blend"); blend.target = "o1"; blend.kind = "screen"
        var cut = EditAction(type: "remove_background"); cut.clip = "o1"
        var lane = EditAction(type: "lane"); lane.target = "titles"; lane.kind = "hide"
        var title = EditAction(type: "add_title"); title.text = "Big"; title.outline = 0.1; title.glow = 0.6; title.animation = "pop"
        var fmt = EditAction(type: "format"); fmt.aspect = "portrait"; fmt.fill = false
        let r = run([effect, mask, key, blend, cut, lane, title, fmt], on: project())
        XCTAssertEqual(r.errors, [])
        let p = r.project
        XCTAssertEqual(p.effects.first?.kind, .vhs, "effects go on the effects lane")
        XCTAssertEqual(p.effects.first?.start, 0); XCTAssertEqual(p.effects.first?.duration, 4, "spanning c1")
        XCTAssertEqual(p.effects.first?.amount, 0.8)
        XCTAssertEqual(p.overlays[0].clip.mask?.width, 0.5)
        XCTAssertEqual(p.overlays[0].clip.chromaKey?.tolerance, 0.5)
        XCTAssertEqual(p.overlays[0].blend, .screen)
        XCTAssertTrue(p.overlays[0].clip.removeBackground)
        XCTAssertTrue(p.hiddenLanes.contains("titles"))
        let t = p.titles.first { $0.text == "Big" }!
        XCTAssertEqual(t.outline, 0.1); XCTAssertEqual(t.glow, 0.6); XCTAssertEqual(t.animation, .pop)
        var off = EditAction(type: "effect"); off.clip = "c1"; off.kind = "none"
        XCTAssertEqual(run([off], on: p).project.effects, [])
    }

    func testSoundAndMotionActions() {
        var vp = EditAction(type: "volume_point"); vp.target = "m1"; vp.at = 2; vp.volume = 0.3
        var ramp = EditAction(type: "speed_ramp"); ramp.clip = "c2"; ramp.kind = "bullet"
        var voice = EditAction(type: "voice_effect"); voice.target = "m1"; voice.kind = "robot"
        var speech = EditAction(type: "speech"); speech.text = "Welcome"; speech.at = 0.5
        var sticker = EditAction(type: "sticker"); sticker.text = "🔥"; sticker.at = 2
        var track = EditAction(type: "track"); track.target = "o1"; track.at = 1.2
        var extract = EditAction(type: "extract_audio"); extract.clip = "c1"
        var steady = EditAction(type: "stabilize"); steady.clip = "c1"
        var reframe = EditAction(type: "reframe"); reframe.clip = "c1"
        let p0 = project()
        let r = run([vp, ramp, voice, speech, sticker, track, extract, steady, reframe], on: p0)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.project.music[0].volumePoints.first?.level, 0.3)
        XCTAssertEqual(r.project.clips.count, 4, "the bullet ramp splits c2 into three")
        XCTAssertEqual(r.jobs.count, 7)
        XCTAssertTrue(r.jobs.contains(.voiceEffect(p0.music[0].id, .robot)))
        XCTAssertTrue(r.jobs.contains(.track(p0.overlays[0].id, from: 1.2)))
        XCTAssertTrue(r.jobs.contains(.extractAudio(p0.clips[0].id)))
    }

    func testBadActionsAreReported() {
        var a = EditAction(type: "effect"); a.clip = "c1"; a.kind = "sparkles"
        var b = EditAction(type: "speed_ramp"); b.clip = "c1"; b.kind = "warp"
        let r = run([a, b], on: project())
        XCTAssertEqual(r.errors.count, 2)
        XCTAssertTrue(r.errors[0].contains("blur"), "the error lists the valid kinds")
    }

    func testSchemaAndGuideCoverEveryAction() {
        let guide = EditActionSchema.guide
        for type in EditActionSchema.types {
            XCTAssertTrue(guide.contains("- \(type):") || guide.contains("\(type):") , "\(type) is documented")
        }
        let props = (EditActionSchema.action(strict: true)["properties"] as? [String: Any]) ?? [:]
        for field in ["outline", "glow", "animation", "word_highlight", "amount", "feather", "invert", "voice", "language"] {
            XCTAssertNotNil(props[field], field)
        }
    }
}
