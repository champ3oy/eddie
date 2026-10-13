import AVFoundation
import VideoToolbox

/// Makes a backwards copy of a video (and a backwards copy of its sound), kept in Eddie's media folder.
/// Works in short chunks from the end so long clips don't fill memory.
enum Reverser {
    struct Result {
        let video: URL
        let audio: URL?
    }

    static func reverse(_ url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No video in \(url.lastPathComponent)."])
        }
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let formats = try await track.load(.formatDescriptions)
        let tenBit = formats.first.map { VideoClip.bitDepth(of: $0) >= 10 } ?? false

        let out = AudioProcessor.mediaFolder.appendingPathComponent("\(UUID().uuidString)-reversed.mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: Int(size.width * size.height * Double(max(fps, 24)) * 0.25),
                                          AVVideoExpectedSourceFrameRateKey: fps]
        if tenBit { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let total = duration.seconds
        let chunk = 0.5
        var chunkEnd = total
        let frameDuration = 1 / Double(max(fps, 1))
        while chunkEnd > 0.0001 {
            try Task.checkCancellation()
            let chunkStart = max(0, chunkEnd - chunk)
            let reader = try AVAssetReader(asset: asset)
            // Read a little before the chunk so the first frame isn't missed; keep only frames inside it.
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, chunkStart - 0.1), preferredTimescale: 600),
                                           end: CMTime(seconds: chunkEnd, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()
            var frames: [(CVPixelBuffer, Double)] = []
            while let sample = output.copyNextSampleBuffer() {
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard t >= chunkStart - 1e-4, t < chunkEnd - 1e-4, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                frames.append((pb, t))
            }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
            for (pb, t) in frames.reversed() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                let newTime = max(0, total - t - frameDuration)
                adaptor.append(pb, withPresentationTime: CMTime(seconds: newTime, preferredTimescale: 600_000))
            }
            chunkEnd = chunkStart
            progress(1 - chunkEnd / total)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        // The sound, backwards.
        var audioURL: URL?
        if (try? await asset.loadTracks(withMediaType: .audio).first) != nil {
            let buffer = try await AudioProcessor.decode(url)
            for c in 0..<Int(buffer.format.channelCount) {
                let d = buffer.floatChannelData![c]
                var i = 0, j = Int(buffer.frameLength) - 1
                while i < j { d.swapAt(i, j); i += 1; j -= 1 }
            }
            let a = AudioProcessor.mediaFolder.appendingPathComponent("\(UUID().uuidString)-reversed.m4a")
            try AudioProcessor.write(buffer, to: a)
            audioURL = a
        }
        return Result(video: out, audio: audioURL)
    }
}

private extension UnsafeMutablePointer where Pointee == Float {
    func swapAt(_ i: Int, _ j: Int) {
        let t = self[i]
        self[i] = self[j]
        self[j] = t
    }
}
