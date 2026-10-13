import CoreImage
import Foundation
import ImageIO

/// Animated GIF / WebP / PNG overlays: their frames, decoded once, and which one shows at a time (looping).
final class AnimatedImage: @unchecked Sendable {
    let frames: [CIImage]
    /// When each frame ends, in seconds from the start of a loop.
    let ends: [Double]
    var duration: Double { ends.last ?? 0 }

    init(frames: [CIImage], ends: [Double]) {
        self.frames = frames
        self.ends = ends
    }

    /// The frame `t` seconds in (looping).
    func frame(at t: Double) -> CIImage {
        guard frames.count > 1, duration > 0 else { return frames[0] }
        var x = t.truncatingRemainder(dividingBy: duration)
        if x < 0 { x += duration }
        var lo = 0, hi = ends.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return frames[lo]
    }

    // MARK: Loading

    private static let cache: NSCache<NSURL, AnimatedImage> = {
        let c = NSCache<NSURL, AnimatedImage>()
        c.totalCostLimit = 400 << 20
        return c
    }()
    /// Files known to have a single frame (so they're not opened again every frame).
    private static let stills = NSCache<NSURL, NSNumber>()

    /// The animation in a file, or nil for an ordinary (one-frame) picture.
    static func load(_ url: URL) -> AnimatedImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if stills.object(forKey: url as NSURL) != nil { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 1 else {
            stills.setObject(1, forKey: url as NSURL)
            return nil
        }
        let count = min(CGImageSourceGetCount(src), 600)
        // Frames are kept at most 720 px on the long side (they're overlays and stickers).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 720,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CIImage] = [], ends: [Double] = [], t = 0.0, bytes = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, options as CFDictionary) else { continue }
            frames.append(CIImage(cgImage: cg, options: [.colorSpace: NSNull()]))
            bytes += cg.bytesPerRow * cg.height
            t += delay(src, i)
            ends.append(t)
        }
        guard !frames.isEmpty else { return nil }
        let anim = AnimatedImage(frames: frames, ends: ends)
        cache.setObject(anim, forKey: url as NSURL, cost: bytes)
        return anim
    }

    /// How long a frame shows. Like browsers, very short delays (≤ 10 ms) count as 100 ms.
    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dict, unclamped, clamped) in dicts {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            let v = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0.1
            return v <= 0.011 ? 0.1 : v
        }
        return 0.1
    }
}
