import Foundation

/// The ten knobs of the editor. Every value is a change from neutral (0 = untouched),
/// so a recipe can be scaled by an intensity factor.
struct GradeRecipe: Codable, Equatable {
    var exposure: Double = 0      // EV, -2...2
    var contrast: Double = 0      // -100...100
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0   // negative = cooler/blue, positive = warmer/yellow
    var tint: Double = 0          // negative = green, positive = magenta
    var vibrance: Double = 0
    var saturation: Double = 0

    static let neutral = GradeRecipe()

    struct Knob {
        let key: WritableKeyPath<GradeRecipe, Double>
        let name: String
        let label: String
        let range: ClosedRange<Double>
        let help: String
    }

    static let knobs: [Knob] = [
        Knob(key: \.exposure, name: "exposure", label: "Exposure", range: -2...2,
             help: "Overall brightness in stops (EV), applied in linear light. +1 doubles the light."),
        Knob(key: \.contrast, name: "contrast", label: "Contrast", range: -100...100,
             help: "S-curve around mid-gray. Positive = punchier, negative = flatter."),
        Knob(key: \.highlights, name: "highlights", label: "Highlights", range: -100...100,
             help: "Brightness of bright areas (upper mids). Negative recovers sky/highlight detail."),
        Knob(key: \.shadows, name: "shadows", label: "Shadows", range: -100...100,
             help: "Brightness of dark areas (lower mids). Positive opens up shadows."),
        Knob(key: \.whites, name: "whites", label: "Whites", range: -100...100,
             help: "White point. Positive makes the brightest tones brighter, negative pulls them down."),
        Knob(key: \.blacks, name: "blacks", label: "Blacks", range: -100...100,
             help: "Black point. Negative deepens blacks, positive lifts/fades them."),
        Knob(key: \.temperature, name: "temperature", label: "Temperature", range: -100...100,
             help: "White balance blue↔yellow. Negative = cooler, positive = warmer."),
        Knob(key: \.tint, name: "tint", label: "Tint", range: -100...100,
             help: "White balance green↔magenta. Negative = greener, positive = more magenta."),
        Knob(key: \.vibrance, name: "vibrance", label: "Vibrance", range: -100...100,
             help: "Saturation that mostly affects muted colors and protects already-saturated ones."),
        Knob(key: \.saturation, name: "saturation", label: "Saturation", range: -100...100,
             help: "Uniform saturation of all colors. -100 = black and white."),
    ]

    /// Every knob multiplied by `factor` (intensity), then clamped.
    func scaled(by factor: Double) -> GradeRecipe {
        var r = self
        for k in Self.knobs { r[keyPath: k.key] = self[keyPath: k.key] * factor }
        return r.clamped()
    }

    func clamped() -> GradeRecipe {
        var r = self
        for k in Self.knobs {
            let v = r[keyPath: k.key]
            r[keyPath: k.key] = v.isFinite ? min(max(v, k.range.lowerBound), k.range.upperBound) : 0
        }
        return r
    }

    var isNeutral: Bool { self == .neutral }

    /// Compact one-line description, e.g. for the log.
    var summary: String {
        Self.knobs.compactMap { k in
            let v = self[keyPath: k.key]
            guard abs(v) > 0.0001 else { return nil }
            return k.name == "exposure" ? String(format: "%@ %+.2f", k.name, v) : String(format: "%@ %+.0f", k.name, v)
        }.joined(separator: ", ").ifEmpty("neutral")
    }

    func jsonString(pretty: Bool = false) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension GradeRecipe {
    /// Adds another recipe's values (a preset's adjustments) on top, then clamps.
    func adding(_ other: GradeRecipe) -> GradeRecipe {
        var r = self
        for k in Self.knobs { r[keyPath: k.key] += other[keyPath: k.key] }
        return r.clamped()
    }
}

/// A one-click look, applied on top of the current grade.
struct Preset: Identifiable {
    let name: String
    let adjust: GradeRecipe
    var id: String { name }

    private static func make(_ name: String, _ build: (inout GradeRecipe) -> Void) -> Preset {
        var r = GradeRecipe()
        build(&r)
        return Preset(name: name, adjust: r)
    }

    static let all: [Preset] = [
        make("Warm") { $0.temperature = 18; $0.tint = 3 },
        make("Cool") { $0.temperature = -18 },
        make("Bright") { $0.exposure = 0.35; $0.shadows = 10 },
        make("Punchy") { $0.contrast = 25; $0.vibrance = 15; $0.blacks = -8 },
        make("Soft") { $0.contrast = -18; $0.highlights = -15; $0.shadows = 12 },
        make("Vivid") { $0.vibrance = 30; $0.saturation = 10 },
        make("Moody") { $0.exposure = -0.3; $0.contrast = 18; $0.saturation = -18; $0.blacks = -12; $0.temperature = -6 },
        make("Cinematic") { $0.contrast = 20; $0.highlights = -20; $0.blacks = -10; $0.saturation = -10; $0.temperature = 8 },
        make("Golden") { $0.temperature = 30; $0.tint = 6; $0.exposure = 0.1; $0.vibrance = 10 },
        make("Faded") { $0.blacks = 25; $0.contrast = -15; $0.saturation = -15 },
        make("Mono") { $0.saturation = -100; $0.contrast = 15 },
    ]
}
