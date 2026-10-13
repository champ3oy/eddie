import AVFoundation

/// Text to speech with the Mac's built-in voices, written to a file in Eddie's media folder.
enum SpeechMaker {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
    }

    /// Installed voices, best quality first, for the given language prefix ("en") or all.
    static func voices(language: String? = nil) -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { language == nil || $0.language.hasPrefix(language!) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map { v in
                let quality = v.quality == .premium ? " (Premium)" : (v.quality == .enhanced ? " (Enhanced)" : "")
                return Voice(id: v.identifier, name: v.name + quality, language: v.language)
            }
    }

    /// Speaks `text` into an audio file. `rate` 0.5…1.5 (1 = normal), `pitch` 0.5…2.
    static func speak(_ text: String, voice: String?, rate: Double = 1, pitch: Double = 1) async throws -> URL {
        let utterance = AVSpeechUtterance(string: text)
        if let voice, let v = AVSpeechSynthesisVoice(identifier: voice) { utterance.voice = v }
        else { utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier) }
        utterance.rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * min(max(rate, 0.5), 1.5))
        utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2))
        let url = AudioProcessor.mediaFolder.appendingPathComponent("Speech \(UUID().uuidString.prefix(6)).caf")
        let synthesizer = AVSpeechSynthesizer()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var file: AVAudioFile?
            nonisolated(unsafe) var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    finished = true
                    if file == nil { c.resume(throwing: CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "No speech was produced."])) }
                    else { c.resume() }
                    return
                }
                do {
                    if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
                    try file?.write(from: pcm)
                } catch {
                    finished = true
                    c.resume(throwing: error)
                }
            }
        }
        withExtendedLifetime(synthesizer) {}
        return url
    }
}
