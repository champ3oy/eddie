import AVFoundation

/// Offline audio clean-up. Reads the sound of any audio or video file, processes it, and writes a new
/// .m4a next to Eddie's other generated media. The original file is never touched.
enum AudioProcessor {
    struct Options {
        /// Bring the overall level to a consistent loudness.
        var normalize = false
        /// Remove background noise with Apple's voice isolation.
        var reduceNoise = false
        /// A fun voice (robot, deep, chipmunk…).
        var voice: VoiceEffect? = nil
    }

    enum VoiceEffect: String, Codable, CaseIterable, Identifiable {
        case robot, deep, chipmunk, echo, radio, alien, cathedral
        var id: String { rawValue }
        var label: String {
            switch self {
            case .robot: return "Robot"
            case .deep: return "Deep"
            case .chipmunk: return "Chipmunk"
            case .echo: return "Echo"
            case .radio: return "Old radio"
            case .alien: return "Alien"
            case .cathedral: return "Cathedral"
            }
        }

        /// The audio units that make the effect, in order.
        func nodes() -> [AVAudioNode] {
            func distortion(_ preset: AVAudioUnitDistortionPreset, _ wet: Float) -> AVAudioUnitDistortion {
                let d = AVAudioUnitDistortion()
                d.loadFactoryPreset(preset)
                d.wetDryMix = wet
                return d
            }
            func pitch(_ cents: Float) -> AVAudioUnitTimePitch {
                let p = AVAudioUnitTimePitch()
                p.pitch = cents
                return p
            }
            switch self {
            case .robot: return [pitch(-200), distortion(.speechGoldenPi, 70)]
            case .deep: return [pitch(-500)]
            case .chipmunk: return [pitch(700)]
            case .echo:
                let d = AVAudioUnitDelay()
                d.delayTime = 0.22; d.feedback = 45; d.wetDryMix = 35
                return [d]
            case .radio: return [distortion(.speechRadioTower, 75)]
            case .alien: return [pitch(300), distortion(.speechAlienChatter, 70)]
            case .cathedral:
                let r = AVAudioUnitReverb()
                r.loadFactoryPreset(.cathedral); r.wetDryMix = 45
                return [r]
            }
        }
    }

    /// Where Eddie keeps files it makes (processed audio, reversed clips, proxies).
    static var mediaFolder: URL {
        let base: URL
        if NSClassFromString("XCTestCase") != nil {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("EddieTestMedia", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Eddie/Media", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static let sampleRate = 48_000.0

    /// Processes the whole sound of `input` and returns the new file.
    static func process(_ input: URL, options: Options) async throws -> URL {
        var buffer = try await decode(input)
        if options.reduceNoise { buffer = try isolateVoice(buffer) }
        if let voice = options.voice { buffer = try render(buffer, through: voice.nodes()) }
        if options.normalize { normalize(buffer) }
        let out = mediaFolder.appendingPathComponent("\(UUID().uuidString).m4a")
        try write(buffer, to: out)
        return out
    }

    // MARK: Decode

    /// The file's sound as 48 kHz stereo float samples.
    static func decode(_ url: URL) async throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) has no sound."])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()
        var interleaved: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            interleaved.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        let frames = interleaved.count / 2
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
        for i in 0..<frames {
            l[i] = interleaved[2 * i]
            r[i] = interleaved[2 * i + 1]
        }
        return buffer
    }

    // MARK: Loudness

    /// Measured loudness: RMS in dBFS (silence-gated) and the sample peak.
    static func loudness(_ buffer: AVAudioPCMBuffer) -> (rms: Double, peak: Float) {
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard n > 0 else { return (-120, 0) }
        let block = Int(sampleRate * 0.4)
        var energies: [Double] = []
        var peak: Float = 0
        var i = 0
        while i < n {
            let end = min(n, i + block)
            var sum = 0.0
            for c in 0..<channels {
                let d = buffer.floatChannelData![c]
                for j in i..<end {
                    let v = d[j]
                    sum += Double(v * v)
                    peak = max(peak, abs(v))
                }
            }
            energies.append(sum / Double((end - i) * channels))
            i = end
        }
        // Ignore near-silent stretches, like a loudness meter's gate.
        let gated = energies.filter { $0 > 1e-6 }
        guard !gated.isEmpty else { return (-120, peak) }
        let mean = gated.reduce(0, +) / Double(gated.count)
        return (10 * log10(mean), peak)
    }

    /// Target loudness for normalize, in dBFS RMS (about −16 LUFS, typical for online video).
    static let targetRMS = -18.0

    /// Scales the sound to the target loudness, without letting peaks go over −1 dBFS.
    static func normalize(_ buffer: AVAudioPCMBuffer) {
        let (rms, peak) = loudness(buffer)
        guard rms > -100, peak > 0 else { return }
        var gain = pow(10, (targetRMS - rms) / 20)
        let ceiling = pow(10, -1.0 / 20)
        gain = min(gain, ceiling / Double(peak) * 4)   // allow up to 12 dB of limiting at most
        let g = Float(gain), limit = Float(ceiling)
        for c in 0..<Int(buffer.format.channelCount) {
            let d = buffer.floatChannelData![c]
            for i in 0..<Int(buffer.frameLength) {
                d[i] = softLimit(d[i] * g, limit)
            }
        }
    }

    /// Smoothly squashes anything above `limit`.
    private static func softLimit(_ x: Float, _ limit: Float) -> Float {
        let a = abs(x)
        guard a > limit * 0.8 else { return x }
        let knee = limit * 0.8
        let over = a - knee
        let squashed = knee + (limit - knee) * tanh(over / (limit - knee))
        return x < 0 ? -squashed : squashed
    }

    // MARK: Noise reduction

    /// Runs the sound through Apple's voice isolation (the same as the Voice Isolation mic mode).
    static func isolateVoice(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: 0x766F_6973,   // 'vois' — AUSoundIsolation
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard AVAudioUnitComponentManager.shared().components(matching: desc).first != nil else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Noise reduction isn't available on this Mac."])
        }
        return try render(input, through: [AVAudioUnitEffect(audioComponentDescription: desc)])
    }

    /// Runs the sound through a chain of audio units, offline (same length out as in).
    static func render(_ input: AVAudioPCMBuffer, through units: [AVAudioNode]) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var last: AVAudioNode = player
        for unit in units {
            engine.attach(unit)
            engine.connect(last, to: unit, format: input.format)
            last = unit
        }
        engine.connect(last, to: engine.mainMixerNode, format: input.format)
        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength)!
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while engine.manualRenderingSampleTime < AVAudioFramePosition(input.frameLength) {
            let remaining = AVAudioFrameCount(AVAudioFramePosition(input.frameLength) - engine.manualRenderingSampleTime)
            let status = try engine.renderOffline(min(4096, remaining), to: chunk)
            guard status == .success else { break }
            for c in 0..<Int(input.format.channelCount) {
                let src = chunk.floatChannelData![min(c, Int(chunk.format.channelCount) - 1)]
                let dst = out.floatChannelData![c] + Int(out.frameLength)
                dst.update(from: src, count: Int(chunk.frameLength))
            }
            out.frameLength += chunk.frameLength
        }
        player.stop()
        engine.stop()
        return out
    }

    // MARK: Write

    static func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
