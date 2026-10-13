import CoreImage
import XCTest
@testable import Eddie

/// Opt-in: runs a real Auto Grade with the configured AI provider on a real clip and saves
/// before/after frames. Skipped unless EDDIE_LIVE_CLIP is set, e.g.
///   TEST_RUNNER_EDDIE_LIVE_CLIP=/path/clip.MP4 TEST_RUNNER_EDDIE_LIVE_OUT=/tmp/out \
///   xcodebuild ... test -only-testing:EddieTests/LiveGradeTests
final class LiveGradeTests: XCTestCase {
    @MainActor
    func testLiveAutoGrade() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["EDDIE_LIVE_CLIP"] else { throw XCTSkip("EDDIE_LIVE_CLIP not set") }
        let outDir = URL(fileURLWithPath: env["EDDIE_LIVE_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let clip = try await VideoClip.load(URL(fileURLWithPath: path))
        let frames = try await FrameSampler.frames(of: clip, at: FrameSampler.evenTimes(count: 6, duration: clip.duration)).map(\.image)
        let agent = GradingAgent(model: AISettings.makeModel())
        let start = Date()
        let recipe = try await agent.autoGrade(frames: frames, lut: .djiAction4) { event in
            switch event {
            case let .status(s): print("[status] \(s)")
            case let .analysis(round, text, r): print("[round \(round)] \(text)\n    \(r.summary)")
            }
        }
        print("[final] \(recipe.jsonString(pretty: true))")
        print(String(format: "[time] %.1f s", Date().timeIntervalSince(start)))

        for (i, frame) in frames.enumerated() {
            for (name, mode, r) in [("log", ViewMode.original, GradeRecipe.neutral), ("lut", .lutOnly, .neutral), ("graded", .graded, recipe)] {
                let img = GradeRenderer.shared.render(frame, recipe: r, lut: .djiAction4, mode: mode)
                let px = GradeRenderer.shared.rgba8(img, maxWidth: 960)
                try GradingAgent.jpeg(rgba: px.pixels, width: px.width, height: px.height)?
                    .write(to: outDir.appendingPathComponent("frame\(i + 1)_\(name).jpg"))
            }
        }
        XCTAssertFalse(recipe.isNeutral)
    }
}
