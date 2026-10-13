import CoreImage
import Foundation

/// Effects, masks, green screen and blend modes, drawn per frame by the compositor.
enum VisualEffects {
    // MARK: Effects

    /// Applies a clip's effects to its graded picture (in the picture's own coordinates). `time` drives the
    /// moving ones (grain, glitch, light leak).
    static func apply(_ effects: [ClipEffect], to image: CIImage, time: Double) -> CIImage {
        var out = image
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return image }
        for e in effects where e.amount > 0.001 {
            let a = e.amount
            switch e.kind {
            case .blur:
                out = out.clampedToExtent().applyingGaussianBlur(sigma: a * Double(extent.width) * 0.012).cropped(to: extent)
            case .sharpen:
                out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a * 2, "inputRadius": 2.5])
            case .vignette:
                // Bright in the middle, falling off to dark corners (multiplied in).
                let half = hypot(extent.width, extent.height) / 2
                let edge = CGFloat(1 - 0.85 * a)
                let shade = CIFilter(name: "CIRadialGradient", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    "inputRadius0": half * (0.55 - 0.2 * a), "inputRadius1": half,
                    "inputColor0": CIColor.white, "inputColor1": CIColor(red: edge, green: edge, blue: edge),
                ])!.outputImage!.cropped(to: extent)
                out = shade.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: out]).cropped(to: extent)
            case .grain:
                out = grain(out, amount: a, time: time)
            case .glitch:
                out = glitch(out, amount: a, time: time)
            case .shake:
                break   // a movement, applied when the picture is placed (see `shakeOffset`)
            case .vhs:
                out = vhs(out, amount: a, time: time)
            case .lightLeak:
                out = lightLeak(out, amount: a, time: time)
            case .pixelate:
                out = out.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: 2 + a * Double(extent.width) * 0.03,
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                ]).cropped(to: extent)
            case .mirror:
                // The left half reflected onto the right.
                let half = CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height)
                let left = out.cropped(to: half)
                let flipped = left.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                    .concatenating(CGAffineTransform(translationX: extent.minX * 2 + extent.width, y: 0)))
                out = flipped.composited(over: left)
            }
        }
        return out
    }

    /// Camera shake: how far to move the placed picture at this time (pixels).
    static func shakeOffset(_ effects: [ClipEffect], time: Double, size: CGSize) -> CGPoint {
        guard let e = effects.first(where: { $0.kind == .shake && $0.amount > 0.001 }) else { return .zero }
        let s = Double(min(size.width, size.height)) * 0.025 * e.amount
        // Smooth noise from a few sine waves at unrelated rates.
        let x = sin(time * 17.3) * 0.6 + sin(time * 31.7 + 1.3) * 0.3 + sin(time * 7.1 + 2.1) * 0.4
        let y = sin(time * 19.9 + 0.7) * 0.6 + sin(time * 27.1 + 2.9) * 0.3 + sin(time * 5.3) * 0.4
        return CGPoint(x: x * s, y: y * s)
    }

    private static func noise(_ extent: CGRect, time: Double) -> CIImage {
        let frame = floor(time * 24)
        let shift = CGAffineTransform(translationX: CGFloat((frame * 137).truncatingRemainder(dividingBy: 997)),
                                      y: CGFloat((frame * 211).truncatingRemainder(dividingBy: 991)))
        return CIFilter(name: "CIRandomGenerator")!.outputImage!.transformed(by: shift).cropped(to: extent)
    }

    private static func grain(_ image: CIImage, amount: Double, time: Double) -> CIImage {
        let mono = noise(image.extent, time: time).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.55)),
        ])
        return mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: image.extent)
    }

    private static func channel(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Red and blue pulled apart, jumping now and then.
    private static func glitch(_ image: CIImage, amount: Double, time: Double) -> CIImage {
        let extent = image.extent
        let beat = floor(time * 8)
        let burst = sin(beat * 12.9898).truncatingRemainder(dividingBy: 1)
        let strength = abs(burst) > 0.6 ? 1.0 : 0.35
        let dx = CGFloat(amount * strength) * extent.width * 0.012
        let r = channel(image, r: 1, g: 0, b: 0).transformed(by: CGAffineTransform(translationX: dx, y: 0))
        let g = channel(image, r: 0, g: 1, b: 0)
        let b = channel(image, r: 0, g: 0, b: 1).transformed(by: CGAffineTransform(translationX: -dx, y: 0))
        var out = r.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: g])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
        // A band of the picture slipped sideways during bursts.
        if strength > 0.5 {
            let bandY = extent.minY + extent.height * CGFloat(abs(sin(beat * 78.233)))
            let band = CGRect(x: extent.minX, y: bandY, width: extent.width, height: extent.height * 0.08)
            let slipped = out.cropped(to: band).transformed(by: CGAffineTransform(translationX: dx * 4, y: 0))
            out = slipped.composited(over: out)
        }
        return out.cropped(to: extent)
    }

    private static func vhs(_ image: CIImage, amount: Double, time: Double) -> CIImage {
        let extent = image.extent
        var out = glitch(image, amount: amount * 0.4, time: time)
        out = out.clampedToExtent().applyingGaussianBlur(sigma: amount * 1.2).cropped(to: extent)
        let lines = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(0.25 * amount)),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            "inputWidth": max(1.5, extent.height / 360), "inputSharpness": 0.5,
        ])!.outputImage!.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: extent)
        out = lines.composited(over: out)
        return grain(out, amount: amount * 0.6, time: time)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - 0.25 * amount, kCIInputContrastKey: 1 - 0.1 * amount])
    }

    /// A warm glow drifting in from a corner.
    private static func lightLeak(_ image: CIImage, amount: Double, time: Double) -> CIImage {
        let e = image.extent
        let drift = (sin(time * 0.6) + 1) / 2
        let center = CIVector(x: e.minX + e.width * CGFloat(0.85 - 0.3 * drift), y: e.minY + e.height * CGFloat(0.8 - 0.2 * drift))
        let leak = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: center, "inputRadius0": 0, "inputRadius1": max(e.width, e.height) * 0.7,
            "inputColor0": CIColor(red: 1, green: 0.55, blue: 0.2, alpha: CGFloat(0.9 * amount)),
            "inputColor1": CIColor(red: 1, green: 0.3, blue: 0.1, alpha: 0),
        ])!.outputImage!.cropped(to: e)
        return leak.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: e)
    }

    // MARK: Masks

    /// Cuts the picture to the mask's shape (outside becomes transparent).
    static func mask(_ image: CIImage, _ m: ClipMask) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, e.width > 0 else { return image }
        let cx = e.minX + e.width * CGFloat(m.centerX)
        let cy = e.minY + e.height * CGFloat(1 - m.centerY)
        let w = e.width * CGFloat(max(0.01, m.width)), h = e.height * CGFloat(max(0.01, m.height))
        let feather = CGFloat(min(max(m.feather, 0), 1))
        let rotate = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(m.rotation) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        var shape: CIImage
        switch m.shape {
        case .circle:
            // A unit circle with a soft edge, stretched into the ellipse.
            shape = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0), "inputRadius0": max(0, 1 - feather), "inputRadius1": 1,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!.transformed(by: CGAffineTransform(scaleX: w / 2, y: h / 2)
                .concatenating(CGAffineTransform(translationX: cx, y: cy)))
        case .rectangle:
            let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            let blur = Double(feather * min(w, h) * 0.25)
            shape = CIImage(color: .white).cropped(to: rect).composited(over: CIImage(color: .black))
            if blur > 0.5 { shape = shape.applyingGaussianBlur(sigma: blur) }
        case .linear:
            // Visible above a line through the center; feather is the width of the soft band.
            let band = max(1, e.height * feather)
            shape = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx, y: cy - band / 2), "inputPoint1": CIVector(x: cx, y: cy + band / 2),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white,
            ])!.outputImage!
        }
        shape = shape.transformed(by: rotate)
        if m.invert { shape = shape.applyingFilter("CIColorInvert") }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e),
            kCIInputMaskImageKey: shape.cropped(to: e),
        ]).cropped(to: e)
    }

    // MARK: Green screen

    private static let cubeSize = 32
    private static let cubeCache = NSCache<NSString, NSData>()

    /// Makes the key color transparent, with a soft edge and the color's spill pulled out of the edges.
    static func chromaKey(_ image: CIImage, _ key: ChromaKey) -> CIImage {
        let cacheKey = "\(key.color)|\(key.tolerance)|\(key.softness)|\(key.despill)" as NSString
        let data: NSData
        if let cached = cubeCache.object(forKey: cacheKey) { data = cached }
        else { data = cube(key) as NSData; cubeCache.setObject(data, forKey: cacheKey) }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize, "inputCubeData": data as Data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    /// The keying table: for every color, how far it is from the key (in hue and strength) decides its alpha.
    static func cube(_ key: ChromaKey) -> Data {
        let n = cubeSize
        let kc = TitleRenderer.color(key.color).usingColorSpace(.sRGB) ?? .green
        let (kh, ks, _) = hsv(Float(kc.redComponent), Float(kc.greenComponent), Float(kc.blueComponent))
        let tol = Float(0.04 + key.tolerance * 0.3)
        let soft = Float(0.02 + key.softness * 0.3)
        var out = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var rf = Float(r) / Float(n - 1), gf = Float(g) / Float(n - 1), bf = Float(b) / Float(n - 1)
                    let (h, sat, v) = hsv(rf, gf, bf)
                    var dh = abs(h - kh)
                    dh = min(dh, 1 - dh)
                    // Distance from the key: hue difference, plus how washed-out or dark the color is.
                    let d = dh + max(0, ks * 0.6 - sat) * 0.6 + max(0, 0.18 - v) * 0.8
                    var alpha = min(1, max(0, (d - tol) / soft))
                    if key.despill && alpha > 0 && alpha < 1 || (key.despill && dh < tol * 2.5) {
                        // Pull the key's tint out: clamp the channel it dominates to the others.
                        if kc.greenComponent >= kc.redComponent && kc.greenComponent >= kc.blueComponent { gf = min(gf, max(rf, bf)) }
                        else if kc.blueComponent >= kc.redComponent { bf = min(bf, max(rf, gf)) }
                        else { rf = min(rf, max(gf, bf)) }
                    }
                    if alpha < 0.002 { alpha = 0 }
                    out[i] = rf * alpha; out[i + 1] = gf * alpha; out[i + 2] = bf * alpha; out[i + 3] = alpha
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    // MARK: Blending

    /// Puts `picture` on `canvas` with a blend mode.
    static func blend(_ picture: CIImage, over canvas: CIImage, mode: BlendMode) -> CIImage {
        guard let name = mode.filter else { return picture.composited(over: canvas) }
        return picture.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: canvas]).cropped(to: canvas.extent)
    }

    /// The clip blurred and filling the frame, for behind clips that fit inside it.
    static func blurredFill(_ picture: CIImage, size: CGSize) -> CIImage {
        let e = picture.extent
        guard e.width > 0, e.height > 0 else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        let s = max(size.width / e.width, size.height / e.height) * 1.08
        let filled = picture.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)))
        let frame = CGRect(origin: .zero, size: size)
        return filled.clampedToExtent().applyingGaussianBlur(sigma: Double(min(size.width, size.height)) * 0.035)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08, kCIInputSaturationKey: 1.1])
            .cropped(to: frame)
    }
}
