import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the AI answers each round.
struct GradeResponse: Codable {
    var analysis: String
    var satisfied: Bool
    var recipe: GradeRecipe
}

/// Drives the AI: shows it frames + measurements, gets knob values back, checks its own result.
struct GradingAgent {
    var model: VisionModel
    var renderer: GradeRenderer = .shared
    var maxRounds = 3
    /// False for footage that isn't D-Log M.
    var applyLUT = true

    enum Event {
        case status(String)
        case analysis(round: Int, text: String, recipe: GradeRecipe)
    }

    // MARK: Public

    /// Full auto grade: one proposal round, then self-check rounds until satisfied.
    func autoGrade(frames: [CIImage], lut: CubeLUT, events: @MainActor (Event) -> Void) async throws -> GradeRecipe {
        await events(.status("Looking at \(frames.count) frames with \(model.displayName)…"))
        let base = prepare(frames, recipe: .neutral, lut: lut)
        var answer = try await ask(Prompts.firstRound(stats: base.stats), images: base.jpegs)
        var recipe = answer.recipe.clamped()
        await events(.analysis(round: 1, text: answer.analysis, recipe: recipe))

        for round in 2...max(2, maxRounds) {
            try Task.checkCancellation()
            await events(.status("Checking the result (round \(round))…"))
            let graded = prepare(frames, recipe: recipe, lut: lut)
            answer = try await ask(Prompts.review(recipe: recipe, stats: graded.stats, baseStats: base.stats), images: graded.jpegs)
            if answer.satisfied {
                await events(.status("The AI is happy with the grade."))
                break
            }
            recipe = answer.recipe.clamped()
            await events(.analysis(round: round, text: answer.analysis, recipe: recipe))
        }
        return recipe
    }

    /// One change request in plain words ("warmer", "more contrast", "moodier").
    func refine(frames: [CIImage], lut: CubeLUT, current: GradeRecipe, instruction: String,
                events: @MainActor (Event) -> Void) async throws -> GradeRecipe {
        await events(.status("Asking for: “\(instruction)”…"))
        let graded = prepare(frames, recipe: current, lut: lut)
        let answer = try await ask(Prompts.refine(recipe: current, stats: graded.stats, instruction: instruction),
                                   images: graded.jpegs)
        let recipe = answer.recipe.clamped()
        await events(.analysis(round: 0, text: answer.analysis, recipe: recipe))
        return recipe
    }

    // MARK: Internals

    struct Prepared {
        var jpegs: [Data]
        var stats: [FrameStats]
    }

    func prepare(_ frames: [CIImage], recipe: GradeRecipe, lut: CubeLUT) -> Prepared {
        var jpegs: [Data] = [], stats: [FrameStats] = []
        for frame in frames {
            let graded = renderer.render(frame, recipe: recipe, lut: lut, mode: .graded, applyLUT: applyLUT)
            let small = renderer.rgba8(graded, maxWidth: 320)
            stats.append(FrameStats(rgba: small.pixels, width: small.width, height: small.height))
            let big = renderer.rgba8(graded, maxWidth: 1024)
            if let jpeg = Self.jpeg(rgba: big.pixels, width: big.width, height: big.height) { jpegs.append(jpeg) }
        }
        return Prepared(jpegs: jpegs, stats: stats)
    }

    private func ask(_ text: String, images: [Data]) async throws -> GradeResponse {
        let raw = try await model.complete(VisionRequest(system: Prompts.system, text: text, images: images, schema: Prompts.schema))
        guard let data = JSONExtraction.object(in: raw) else { throw VisionModelError.invalidJSON(raw) }
        do {
            return try JSONDecoder().decode(GradeResponse.self, from: data)
        } catch {
            throw VisionModelError.invalidJSON(raw)
        }
    }

    static func jpeg(rgba: [UInt8], width: Int, height: Int, quality: Double = 0.85) -> Data? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - Prompts

enum Prompts {
    static let system: String = {
        let knobs = GradeRecipe.knobs.map { k in
            "- \(k.name) (\(k.range.lowerBound.formatted())…\(k.range.upperBound.formatted())): \(k.help)"
        }.joined(separator: "\n")
        return """
        You are an expert colorist operating a simple color-grading engine. You never touch pixels \
        yourself: you set the engine's knobs, the engine renders, and you are shown the result.

        The footage was shot on a DJI Osmo Action 4 in D-Log M (10-bit). Before your knobs apply, \
        the engine converts it to normal Rec.709 with DJI's official D-Log M → Rec.709 LUT, so you \
        are looking at a technically correct starting point, not flat LOG.

        Knobs (0 = no change; all values are changes from the LUT result):
        \(knobs)

        Order of operations: white balance and exposure (in linear light) → highlights/shadows/\
        whites/blacks → contrast → vibrance/saturation.

        Goal: natural, pleasing, well-exposed footage that looks like a high-quality camera made it. \
        Correct problems first (exposure, white balance, clipped highlights, muddy or crushed shadows), \
        then add a tasteful look only if the user asked for one. Keep skin tones natural. Avoid \
        clipping (clipped highlights near 0 % unless there's sun or specular light) and avoid crushing \
        blacks. Typical good corrections are modest: exposure within ±0.7 EV and most other knobs \
        within ±40. The same recipe applies to every frame of the clip, so choose values that work for \
        all frames shown, not just one.

        You also get measurements for each frame (Rec.709 display values 0–1): luma percentiles, % \
        clipped highlights, % crushed shadows, mean RGB, the RGB of bright near-neutral pixels (a \
        white-balance hint: if R, G and B differ clearly, the whites have a color cast; the sky or \
        warm light can legitimately bias it), and mean saturation. The white-balance hint is also given \
        on the two knob axes: "warmth (R−B)" — positive means too warm (lower temperature), negative \
        means too blue (raise temperature); "green–magenta (G−avg(R,B))" — negative means pink, purple \
        or lavender whites (lower tint, i.e. add green), positive means green whites (raise tint). Fix \
        each axis with its own knob: a lavender cast is mostly a tint problem, and adding warmth to it \
        makes whites pink. For neutral whites aim for both values within about ±0.02, unless the light \
        is genuinely colored (sunset, tungsten, neon) and the mood depends on it. A well-exposed daylight shot usually \
        has median luma about 0.35–0.5 and p99 about 0.9–0.97.

        Always answer with a single JSON object, no other text:
        {"analysis": string, "satisfied": boolean, "recipe": {exposure, contrast, highlights, shadows, \
        whites, blacks, temperature, tint, vibrance, saturation}}
        "analysis" is 1–3 short sentences in plain language for someone who knows nothing about color \
        grading: what you see and what you changed. "recipe" is always the complete set of knob values.
        """
    }()

    static let schema: [String: Any] = {
        var knobProps: [String: Any] = [:]
        for k in GradeRecipe.knobs {
            knobProps[k.name] = ["type": "number", "description": k.help]
        }
        return [
            "type": "object",
            "properties": [
                "analysis": ["type": "string"],
                "satisfied": ["type": "boolean"],
                "recipe": [
                    "type": "object",
                    "properties": knobProps,
                    "required": GradeRecipe.knobs.map(\.name),
                    "additionalProperties": false,
                ],
            ],
            "required": ["analysis", "satisfied", "recipe"],
            "additionalProperties": false,
        ]
    }()

    static func statsBlock(_ stats: [FrameStats]) -> String {
        stats.enumerated().map { "Frame \($0.offset + 1): \($0.element.description)" }.joined(separator: "\n")
    }

    static func firstRound(stats: [FrameStats]) -> String {
        """
        Here are \(stats.count) frames from the clip, shown after the D-Log M → Rec.709 LUT with all knobs at 0.

        Measurements:
        \(statsBlock(stats))

        Choose the knob values that make this clip look its best. Set "satisfied" to false.
        """
    }

    static func review(recipe: GradeRecipe, stats: [FrameStats], baseStats: [FrameStats]) -> String {
        """
        These are the same frames rendered with your recipe:
        \(recipe.jsonString())

        Measurements after your recipe:
        \(statsBlock(stats))

        Measurements before any knobs (LUT only), for reference:
        \(statsBlock(baseStats))

        Look critically at the rendered frames. If they look right, set "satisfied" to true and return \
        the same recipe. Otherwise set "satisfied" to false and return the complete corrected recipe.
        """
    }

    static func refine(recipe: GradeRecipe, stats: [FrameStats], instruction: String) -> String {
        """
        These frames are rendered with the current recipe:
        \(recipe.jsonString())

        Measurements:
        \(statsBlock(stats))

        The user asked: "\(instruction)"

        Adjust the recipe to do what they asked while keeping the footage looking good. Return the \
        complete new recipe and set "satisfied" to true.
        """
    }
}
