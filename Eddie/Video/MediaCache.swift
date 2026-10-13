import AVFoundation
import AppKit
import CryptoKit

/// Eddie's disk caches in ~/Library/Caches/Eddie — thumbnails, waveforms and proxies. Safe to delete any time.
enum MediaCache {
    static var root: URL {
        let base = NSClassFromString("XCTestCase") != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("EddieTestCache", isDirectory: true)
            : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Eddie", isDirectory: true)
        return base
    }

    static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A key that changes when the file changes (path, size and modification date).
    static func key(for url: URL, _ extra: String = "") -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(date)|\(extra)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Waveforms

    static func waveform(for url: URL, buckets: Int) -> [Float]? {
        let file = folder("Waveforms").appendingPathComponent(key(for: url, "\(buckets)") + ".peaks")
        guard let data = try? Data(contentsOf: file), data.count % 4 == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func storeWaveform(_ peaks: [Float], for url: URL, buckets: Int) {
        let file = folder("Waveforms").appendingPathComponent(key(for: url, "\(buckets)") + ".peaks")
        try? peaks.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: file, options: .atomic)
    }

    // MARK: Thumbnails (media bin)

    /// A small poster frame for a video or photo, from the disk cache when possible.
    static func thumbnail(for url: URL, maxSide: CGFloat = 320) async -> NSImage? {
        let file = folder("Thumbnails").appendingPathComponent(key(for: url, "\(Int(maxSide))") + ".jpg")
        if let image = NSImage(contentsOf: file) { return image }
        var cg: CGImage?
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
            }
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSide, height: maxSide)
            cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        }
        guard let cg else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) { try? data.write(to: file, options: .atomic) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Proxies

    /// Where the proxy for a file lives (whether or not it's been made yet).
    static func proxyURL(for url: URL) -> URL {
        folder("Proxies").appendingPathComponent(key(for: url) + ".mov")
    }

    static func existingProxy(for url: URL) -> URL? {
        let p = proxyURL(for: url)
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }

    /// A 1080p HEVC copy for smooth playback of 4K footage (10-bit is kept). Export always uses the original.
    static func makeProxy(for url: URL) async throws -> URL {
        let out = proxyURL(for: url)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let tmp = out.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw CocoaError(.featureUnsupported)
        }
        try await session.export(to: tmp, as: .mov)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    /// How much space the caches use, in bytes.
    static func size() -> Int64 {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let u = e?.nextObject() as? URL { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    static func clear() { try? FileManager.default.removeItem(at: root) }
}
