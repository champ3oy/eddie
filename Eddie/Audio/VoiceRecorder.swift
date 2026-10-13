import AVFoundation

/// Records the microphone to a file in Eddie's media folder.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Input level 0…1 for the meter.
    @Published private(set) var level: Float = 0

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private(set) var url: URL?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "No microphone found."])
        }
        let url = AudioProcessor.mediaFolder.appendingPathComponent("Voiceover \(Self.stamp()).m4a")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(2, format.channelCount),
            AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            try? file.write(from: buffer)
            var peak: Float = 0
            if let d = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(d[i])) }
            }
            Task { @MainActor in self?.level = peak }
        }
        try engine.start()
        self.engine = engine
        self.file = file
        self.url = url
        isRecording = true
    }

    /// Stops and returns the recording.
    func stop() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
        isRecording = false
        level = 0
        return url
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
