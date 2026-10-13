import AppKit
import CoreImage
import CoreText

/// Draws title text into a Core Image overlay placed in the video frame (position, size, rotation).
/// The drawn text box is cached, so moving or rotating a title doesn't redraw it.
enum TitleRenderer {
    private final class Box {
        let image: CIImage
        let size: CGSize
        init(image: CIImage, size: CGSize) { self.image = image; self.size = size }
    }

    private static let cache = NSCache<NSString, Box>()

    /// System font choices shown first in the font menu.
    static let systemFamilies = ["System", "Rounded", "Serif", "Mono"]

    /// The title as it looks at a moment of the video: its animation, typed-out letters and highlighted word.
    static func overlay(_ title: TitleItem, renderSize: CGSize, at time: Double) -> CIImage? {
        let m = motion(title, at: time)
        var state = DrawState()
        if title.animation == .typewriter {
            let chars = title.text.count
            let span = min(max(0.4, Double(chars) * 0.045), title.duration * 0.6)
            state.reveal = min(chars, Int((Double(chars) * (time - title.start) / span).rounded(.up)))
        }
        if title.wordHighlight {
            let words = title.timedWords
            state.highlight = words.lastIndex { $0.start <= time + 0.01 } ?? -1
        }
        return overlay(title, renderSize: renderSize, opacity: m.opacity, state: state, scale: m.scale, lift: m.lift)
    }

    /// Opacity, scale and vertical offset (fraction of the frame height, up) from the title's animation.
    static func motion(_ title: TitleItem, at time: Double) -> (opacity: Double, scale: Double, lift: Double) {
        let inT = time - title.start, outT = title.end - time
        let fadeOut = max(0, min(1, outT / min(0.25, title.duration / 3)))
        func p(_ length: Double) -> Double { max(0, min(1, inT / min(length, title.duration / 2))) }
        switch title.animation {
        case .none:
            return (1, 1, 0)
        case .fade:
            return (opacity(of: title, at: time), 1, 0)
        case .typewriter:
            return (fadeOut, 1, 0)
        case .pop:
            let t = p(0.28)
            let back = 1 + 2.7 * pow(t - 1, 3) + 1.7 * pow(t - 1, 2)   // ease-out with a little overshoot
            return (min(1, t * 3) * fadeOut, 0.55 + 0.45 * back, 0)
        case .bounce:
            let t = p(0.6)
            let bounce = 1 - pow(1 - t, 2) * abs(cos(t * .pi * 3))
            return (min(1, t * 4) * fadeOut, 0.3 + 0.7 * bounce, 0)
        case .slideUp, .slideDown:
            let t = p(0.35)
            let eased = 1 - pow(1 - t, 3)
            let distance = 0.06 * (1 - eased)
            return (eased * fadeOut, 1, title.animation == .slideUp ? -distance : distance)
        }
    }

    /// The title as a transparent overlay in frame coordinates, faded by `opacity`.
    static func overlay(_ title: TitleItem, renderSize: CGSize, opacity: Double = 1) -> CIImage? {
        overlay(title, renderSize: renderSize, opacity: opacity, state: DrawState(), scale: 1, lift: 0)
    }

    /// What changes the drawn text over time: letters typed so far and the word being spoken.
    struct DrawState: Hashable {
        var reveal: Int?
        var highlight: Int?
    }

    private static func overlay(_ title: TitleItem, renderSize: CGSize, opacity: Double, state: DrawState,
                                scale: Double, lift: Double) -> CIImage? {
        guard opacity > 0.001, let box = box(title, renderSize: renderSize, state: state) else { return nil }
        var center = centerInFrame(title, boxSize: box.size, renderSize: renderSize)
        center.y += CGFloat(lift) * renderSize.height
        // Core Image's y axis points up, so clockwise rotation is a negative angle.
        let t = CGAffineTransform(translationX: -box.size.width / 2, y: -box.size.height / 2)
            .concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(title.rotation) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        let placed = box.image.transformed(by: t, highQualityDownsample: true)
        guard opacity < 0.999 else { return placed }
        let o = CGFloat(max(0, opacity))
        return placed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: o),
        ])
    }

    /// Size of the drawn text box in frame pixels (for the on-canvas handles).
    static func boxSize(_ title: TitleItem, renderSize: CGSize) -> CGSize {
        box(title, renderSize: renderSize)?.size ?? .zero
    }

    /// Box center as a fraction of the frame, y from the top (the title's own spot or its style's default).
    static func normalizedCenter(_ title: TitleItem, renderSize: CGSize) -> CGPoint {
        if let x = title.x, let y = title.y { return CGPoint(x: x, y: y) }
        let s = boxSize(title, renderSize: renderSize)
        let w = max(1, renderSize.width), h = max(1, renderSize.height)
        switch title.style {
        case .title: return CGPoint(x: 0.5, y: 0.5)
        case .lowerThird: return CGPoint(x: 0.06 + s.width / 2 / w, y: 1 - (0.12 + s.height / 2 / h))
        case .caption: return CGPoint(x: 0.5, y: 1 - (0.07 + s.height / 2 / h))
        }
    }

    /// Fade in/out over 0.25 s at the title's ends.
    static func opacity(of title: TitleItem, at time: Double) -> Double {
        let fade = min(0.25, title.duration / 3)
        let a = (time - title.start) / fade, b = (title.end - time) / fade
        return max(0, min(1, min(a, b)))
    }

    static func font(_ title: TitleItem, pointSize: CGFloat) -> NSFont {
        let w: NSFont.Weight
        switch title.resolvedWeight {
        case .regular: w = .regular
        case .medium: w = .medium
        case .bold: w = .bold
        case .heavy: w = .heavy
        }
        var font: NSFont
        switch title.font {
        case "System", "Rounded", "Serif", "Mono":
            font = NSFont.systemFont(ofSize: pointSize, weight: w)
            let design: NSFontDescriptor.SystemDesign? = title.font == "Rounded" ? .rounded
                : title.font == "Serif" ? .serif : title.font == "Mono" ? .monospaced : nil
            if let design, let d = font.fontDescriptor.withDesign(design), let f = NSFont(descriptor: d, size: pointSize) { font = f }
        default:
            let managerWeight: Int
            switch title.resolvedWeight {
            case .regular: managerWeight = 5
            case .medium: managerWeight = 6
            case .bold: managerWeight = 9
            case .heavy: managerWeight = 11
            }
            font = NSFontManager.shared.font(withFamily: title.font, traits: [], weight: managerWeight, size: pointSize)
                ?? NSFont.systemFont(ofSize: pointSize, weight: w)
        }
        if title.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func color(_ hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .white }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    // MARK: Drawing

    private static func centerInFrame(_ title: TitleItem, boxSize: CGSize, renderSize: CGSize) -> CGPoint {
        let n = normalizedCenter(title, renderSize: renderSize)
        return CGPoint(x: n.x * renderSize.width, y: (1 - n.y) * renderSize.height)
    }

    private static func box(_ title: TitleItem, renderSize: CGSize, state: DrawState = DrawState()) -> Box? {
        let text = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, renderSize.width > 0 else { return nil }
        let key = [text, title.style.rawValue, "\(title.size)", title.font, title.resolvedWeight.rawValue, "\(title.italic)",
                   title.color, "\(title.resolvedPlate)", title.resolvedAlign.rawValue,
                   "\(title.outline)", title.outlineColor, "\(title.glow)", title.glowColor, title.highlightColor,
                   "\(state.reveal ?? -1)", "\(state.highlight ?? -1)",
                   "\(Int(renderSize.width))x\(Int(renderSize.height))"].joined(separator: "|") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let drawn = draw(text, title: title, renderSize: renderSize, state: state) else { return nil }
        cache.setObject(drawn, forKey: key)
        return drawn
    }

    private static func draw(_ text: String, title: TitleItem, renderSize: CGSize, state: DrawState) -> Box? {
        let h = renderSize.height, w = renderSize.width
        let base: CGFloat
        switch title.style {
        case .title: base = h * 0.085
        case .lowerThird: base = h * 0.05
        case .caption: base = h * 0.038
        }
        let fontSize = base * CGFloat(title.size)
        let font = font(title, pointSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        switch title.resolvedAlign {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(title.color), .paragraphStyle: paragraph]
        if title.outline > 0 {
            // Negative stroke width = fill and stroke (as a percentage of the font size).
            attributes[.strokeWidth] = -title.outline * 100
            attributes[.strokeColor] = color(title.outlineColor)
        }
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        let ns = text as NSString
        // Word-by-word highlight: color the word being spoken.
        if let h = state.highlight, h >= 0 {
            var index = 0
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, stop in
                if index == h {
                    attributed.addAttribute(.foregroundColor, value: color(title.highlightColor), range: range)
                    stop.pointee = true
                }
                index += 1
            }
        }
        // Typewriter: letters not typed yet are invisible but keep their space, so the line doesn't move.
        if let reveal = state.reveal {
            let shown = (text.prefix(max(0, reveal)) as Substring).utf16.count
            if shown < ns.length {
                let rest = NSRange(location: shown, length: ns.length - shown)
                attributed.addAttribute(.foregroundColor, value: NSColor.clear, range: rest)
                attributed.addAttribute(.strokeColor, value: NSColor.clear, range: rest)
            }
        }
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = w * 0.9
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height))

        let pad = fontSize * ((title.resolvedPlate ? 0.45 : 0.4) + title.glow * 0.6 + title.outline)
        let box = CGSize(width: textSize.width + pad * 2, height: textSize.height + pad * 2)
        guard box.width < 16384, box.height < 16384,
              let ctx = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if title.resolvedPlate {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box), cornerWidth: pad * 0.6, cornerHeight: pad * 0.6, transform: nil))
            ctx.fillPath()
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.25,
                          color: NSColor.black.withAlphaComponent(0.6).cgColor)
        }
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: pad, y: pad, width: textSize.width, height: textSize.height), transform: nil), nil)
        if title.glow > 0 {
            // Glow: the text drawn with a wide colored shadow underneath, stronger for higher values.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: fontSize * CGFloat(0.25 + 0.75 * title.glow),
                          color: color(title.glowColor).withAlphaComponent(CGFloat(min(1, 0.5 + title.glow))).cgColor)
            for _ in 0..<(title.glow > 0.5 ? 2 : 1) { CTFrameDraw(frame, ctx) }
            ctx.restoreGState()
        }
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return Box(image: CIImage(cgImage: cg, options: [.colorSpace: NSNull()]), size: box)
    }
}
