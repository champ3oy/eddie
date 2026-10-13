import CoreImage
import XCTest
@testable import Eddie

final class ProviderTests: XCTestCase {
    let request = VisionRequest(system: "sys", text: "hello", images: [Data([1, 2, 3])], schema: Prompts.schema)

    func testGeminiBodyAndParse() throws {
        let body = GeminiProvider(apiKey: "k", model: "m").body(for: request)
        let parts = ((body["contents"] as! [[String: Any]])[0]["parts"]) as! [[String: Any]]
        XCTAssertEqual((parts[0]["inline_data"] as! [String: Any])["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(parts[1]["text"] as? String, "hello")
        let config = body["generationConfig"] as! [String: Any]
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(config["responseJsonSchema"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))

        let response: [String: Any] = ["candidates": [["content": ["parts": [
            ["text": "thinking…", "thought": true], ["text": "{\"a\":1}"],
        ]]]]]
        XCTAssertEqual(try GeminiProvider.text(from: response), "{\"a\":1}")
        XCTAssertThrowsError(try GeminiProvider.text(from: ["promptFeedback": ["blockReason": "SAFETY"]]))
    }

    func testOpenAIAndDeepSeekBodies() {
        let openAI = OpenAICompatibleProvider.openAI(apiKey: "k", model: "gpt").body(for: request)
        let format = openAI["response_format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["json_schema"] as! [String: Any])["strict"] as? Bool, true)
        let user = (openAI["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]]
        XCTAssertTrue(((user[0]["image_url"] as! [String: Any])["url"] as! String).hasPrefix("data:image/jpeg;base64,"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(openAI))

        let deepSeek = OpenAICompatibleProvider.deepSeek(apiKey: "k", model: "ds").body(for: request)
        XCTAssertEqual((deepSeek["response_format"] as! [String: Any])["type"] as? String, "json_object")
        XCTAssertEqual((deepSeek["thinking"] as! [String: Any])["type"] as? String, "enabled")
        XCTAssertNil(openAI["thinking"])

        let response: [String: Any] = ["choices": [["message": ["content": "{\"x\":2}"]]]]
        XCTAssertEqual(try OpenAICompatibleProvider.text(from: response, provider: "OpenAI"), "{\"x\":2}")
    }

    func testClaudeBodyAndParse() throws {
        let body = ClaudeProvider(apiKey: "k", model: "claude-opus-5").body(for: request)
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertEqual((body["thinking"] as! [String: Any])["type"] as? String, "adaptive")
        XCTAssertNotNil((body["output_config"] as! [String: Any])["format"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))

        let ok: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "{}"]]]
        XCTAssertEqual(try ClaudeProvider.text(from: ok), "{}")
        XCTAssertThrowsError(try ClaudeProvider.text(from: ["stop_reason": "refusal", "content": []]))
    }

    func testMissingKeyFailsFast() async {
        do {
            _ = try await GeminiProvider(apiKey: "", model: "m").complete(request)
            XCTFail("expected missing key error")
        } catch VisionModelError.missingAPIKey {
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testJSONExtraction() {
        let wrapped = "Sure!\n```json\n{\"analysis\":\"x\",\"n\":{\"a\":1}}\n```"
        let data = JSONExtraction.object(in: wrapped)!
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"analysis\":\"x\",\"n\":{\"a\":1}}")
        XCTAssertNil(JSONExtraction.object(in: "no json"))
    }

    func testSchemaListsEveryKnob() {
        let recipe = (Prompts.schema["properties"] as! [String: Any])["recipe"] as! [String: Any]
        XCTAssertEqual(Set(recipe["required"] as! [String]), Set(GradeRecipe.knobs.map(\.name)))
        XCTAssertTrue(Prompts.system.contains("temperature"))
    }
}

/// A fake model that answers from a script and records what it was sent.
final class ScriptedModel: VisionModel {
    var answers: [String]
    var requests: [VisionRequest] = []
    let displayName = "Scripted"

    init(_ answers: [String]) { self.answers = answers }

    func complete(_ request: VisionRequest) async throws -> String {
        requests.append(request)
        return answers.removeFirst()
    }
}

final class GradingAgentTests: XCTestCase {
    func frames() -> [CIImage] {
        (0..<3).map { i in
            GradeRenderer.shared.materialize(
                CIImage(color: CIColor(red: 0.3 + 0.1 * Double(i), green: 0.35, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36)))
        }
    }

    func answer(exposure: Double, satisfied: Bool) -> String {
        """
        {"analysis":"ok","satisfied":\(satisfied),"recipe":{"exposure":\(exposure),"contrast":10,"highlights":0,"shadows":0,\
        "whites":0,"blacks":0,"temperature":0,"tint":0,"vibrance":0,"saturation":0}}
        """
    }

    @MainActor
    func testAutoGradeStopsWhenSatisfied() async throws {
        let model = ScriptedModel([answer(exposure: 0.5, satisfied: false), answer(exposure: 0.5, satisfied: true)])
        var events: [GradingAgent.Event] = []
        let recipe = try await GradingAgent(model: model).autoGrade(frames: frames(), lut: .djiAction4) { events.append($0) }
        XCTAssertEqual(recipe.exposure, 0.5)
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(model.requests[0].images.count, 3)
        XCTAssertTrue(model.requests[0].text.contains("Frame 3"))
        XCTAssertTrue(model.requests[1].text.contains("\"exposure\":0.5"))
    }

    @MainActor
    func testAutoGradeUsesCorrectionAndClamps() async throws {
        let model = ScriptedModel([
            answer(exposure: 0.5, satisfied: false),
            answer(exposure: 9, satisfied: false),
            answer(exposure: 0.2, satisfied: false),
        ])
        let recipe = try await GradingAgent(model: model, maxRounds: 3).autoGrade(frames: frames(), lut: .djiAction4) { _ in }
        XCTAssertEqual(model.requests.count, 3)
        XCTAssertEqual(recipe.exposure, 0.2)
        XCTAssertTrue(model.requests[2].text.contains("\"exposure\":2"), "out-of-range value should be clamped before re-rendering")
    }

    @MainActor
    func testRefineSendsInstruction() async throws {
        let model = ScriptedModel([answer(exposure: 0.1, satisfied: true)])
        _ = try await GradingAgent(model: model).refine(frames: frames(), lut: .djiAction4, current: .neutral,
                                                         instruction: "make it warmer") { _ in }
        XCTAssertTrue(model.requests[0].text.contains("make it warmer"))
    }

    @MainActor
    func testBadAnswerIsReported() async {
        let model = ScriptedModel(["I think it looks great!"])
        do {
            _ = try await GradingAgent(model: model).autoGrade(frames: frames(), lut: .djiAction4) { _ in }
            XCTFail("expected an error")
        } catch VisionModelError.invalidJSON {
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testJPEGEncoding() {
        let px = [UInt8](repeating: 200, count: 16 * 9 * 4)
        let jpeg = GradingAgent.jpeg(rgba: px, width: 16, height: 9)
        XCTAssertNotNil(jpeg)
        XCTAssertEqual(jpeg?.prefix(2), Data([0xFF, 0xD8]))
    }
}

final class PresetBehaviorTests: XCTestCase {
    @MainActor
    func testPresetsReplaceEachOtherAndToggleOff() async throws {
        let model = EditorModel()
        model.open(Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!)
        for _ in 0..<100 where model.clip == nil { try await Task.sleep(for: .milliseconds(50)) }
        var base = GradeRecipe(); base.exposure = 0.3
        model.recipe = base

        let mono = Preset.all.first { $0.name == "Mono" }!
        let warm = Preset.all.first { $0.name == "Warm" }!
        model.apply(mono)
        XCTAssertEqual(model.activePreset, "Mono")
        XCTAssertEqual(model.recipe.saturation, -100)

        model.apply(warm)   // replaces Mono instead of stacking on it
        XCTAssertEqual(model.activePreset, "Warm")
        XCTAssertEqual(model.recipe, base.adding(warm.adjust))

        model.apply(warm)   // clicking the active preset removes it
        XCTAssertNil(model.activePreset)
        XCTAssertEqual(model.recipe, base)

        model.apply(mono)
        model.recipe.exposure = 1   // a manual edit makes this the new base
        XCTAssertNil(model.activePreset)
    }
}
