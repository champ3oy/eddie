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

    /// The title as a transparent overlay in frame coordinates, faded by `opacity`.
    static func overlay(_ title: TitleItem, renderSize: CGSize, opacity: Double = 1) -> CIImage? {
        guard let box = box(title, renderSize: renderSize) else { return nil }
        let center = centerInFrame(title, boxSize: box.size, renderSize: renderSize)
        // Core Image's y axis points up, so clockwise rotation is a negative angle.
        let t = CGAffineTransform(translationX: -box.size.width / 2, y: -box.size.height / 2)
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

    private static func box(_ title: TitleItem, renderSize: CGSize) -> Box? {
        let text = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, renderSize.width > 0 else { return nil }
        let key = [text, title.style.rawValue, "\(title.size)", title.font, title.resolvedWeight.rawValue, "\(title.italic)",
                   title.color, "\(title.resolvedPlate)", title.resolvedAlign.rawValue,
                   "\(Int(renderSize.width))x\(Int(renderSize.height))"].joined(separator: "|") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let drawn = draw(text, title: title, renderSize: renderSize) else { return nil }
        cache.setObject(drawn, forKey: key)
        return drawn
    }

    private static func draw(_ text: String, title: TitleItem, renderSize: CGSize) -> Box? {
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
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color(title.color), .paragraphStyle: paragraph,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = w * 0.9
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height))

        let pad = fontSize * (title.resolvedPlate ? 0.45 : 0.4)
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
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return Box(image: CIImage(cgImage: cg, options: [.colorSpace: NSNull()]), size: box)
    }
}
