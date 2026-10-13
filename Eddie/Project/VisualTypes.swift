import Foundation

/// A look applied to one clip or overlay, on top of its grade.
struct ClipEffect: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case blur, sharpen, vignette, grain, glitch, shake, vhs, lightLeak, pixelate, mirror
        var id: String { rawValue }
        var label: String {
            switch self {
            case .blur: return "Blur"
            case .sharpen: return "Sharpen"
            case .vignette: return "Vignette"
            case .grain: return "Film grain"
            case .glitch: return "Glitch"
            case .shake: return "Camera shake"
            case .vhs: return "VHS"
            case .lightLeak: return "Light leak"
            case .pixelate: return "Pixelate"
            case .mirror: return "Mirror"
            }
        }
        var icon: String {
            switch self {
            case .blur: return "drop"
            case .sharpen: return "triangle"
            case .vignette: return "circle.dashed"
            case .grain: return "circle.grid.3x3"
            case .glitch: return "waveform.path.ecg"
            case .shake: return "iphone.radiowaves.left.and.right"
            case .vhs: return "tv"
            case .lightLeak: return "sun.max"
            case .pixelate: return "square.grid.3x3.square"
            case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
            }
        }
    }
    var id = UUID()
    var kind: Kind
    /// 0…1.
    var amount = 0.5
}

/// A shape that cuts a clip or overlay (what's outside it is transparent).
struct ClipMask: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case circle, rectangle, linear
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    var shape = Shape.circle
    /// Center and size as fractions of the picture (y from the top).
    var centerX = 0.5
    var centerY = 0.5
    var width = 0.7
    var height = 0.7
    /// Degrees, clockwise.
    var rotation = 0.0
    /// Soft edge, 0…1.
    var feather = 0.15
    var invert = false
}

/// Green screen: makes one color transparent.
struct ChromaKey: Codable, Equatable {
    var color = "#00FF00"
    /// How far from the key color still counts as background, 0…1.
    var tolerance = 0.35
    /// How soft the edge is, 0…1.
    var softness = 0.15
    /// Pull the key color's tint out of the edges.
    var despill = true
}

/// How an overlay mixes with what's underneath.
enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, softLight, lighten, darken, difference, add
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .softLight: return "Soft light"
        case .lighten: return "Lighten"
        case .darken: return "Darken"
        case .difference: return "Difference"
        case .add: return "Add"
        }
    }
    /// The Core Image filter, or nil for normal.
    var filter: String? {
        switch self {
        case .normal: return nil
        case .multiply: return "CIMultiplyBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .darken: return "CIDarkenBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .add: return "CIAdditionCompositing"
        }
    }
}
