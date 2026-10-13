import AVFoundation
import Speech

/// Auto captions: on-device speech recognition of each clip's own sound, grouped into short lines.
enum Captioner {
    struct Word {
        let text: String
        let start: Double
        let duration: Double
        var end: Double { start + duration }
    }

    enum CaptionError: LocalizedError {
        case notAllowed, unavailable, noSpeech
        var errorDescription: String? {
            switch self {
            case .notAllowed: return "Eddie needs Speech Recognition to make captions. Allow it in System Settings → Privacy & Security → Speech Recognition."
            case .unavailable: return "Speech recognition isn't available for this language on this Mac."
            case .noSpeech: return "No speech found in the clips."
            }
        }
    }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// Captions for the whole project, in timeline time.
    static func captions(for project: Project, locale: Locale = .current) async throws -> [TitleItem] {
        lines(from: try await words(for: project, locale: locale))
    }

    /// Every spoken word in the clips, in timeline time.
    static func words(for project: Project, locale: Locale = .current) async throws -> [Word] {
        guard await requestAccess() else { throw CaptionError.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw CaptionError.unavailable }
        var words: [Word] = []
        let starts = project.starts
        for (i, clip) in project.clips.enumerated() where !clip.isPhoto && !clip.audioMuted && clip.volume > 0.01 {
            let audio = try await extractAudio(clip)
            defer { try? FileManager.default.removeItem(at: audio) }
            let found = (try? await recognize(audio, with: recognizer)) ?? []
            for w in found {
                // Source time → timeline time (speed changes stretch it).
                let t = starts[i] + w.start / clip.speed
                guard t < starts[i] + clip.duration else { continue }
                words.append(Word(text: w.text, start: t, duration: w.duration / clip.speed))
            }
        }
        guard !words.isEmpty else { throw CaptionError.noSpeech }
        return words
    }

    /// The clip's used stretch of sound as a temporary .m4a (times start at 0).
    static func extractAudio(_ clip: ClipItem) async throws -> URL {
        let asset = AVURLAsset(url: clip.audioOverride ?? clip.url)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                                        end: CMTime(seconds: clip.sourceEnd, preferredTimescale: 600))
        try await session.export(to: out, as: .m4a)
        return out
    }

    /// All the words in an audio file. Long recordings come back in pieces (one per stretch of speech), so every
    /// piece is collected until recognition says it has finished — not just the first or last one.
    static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> [Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let collector = Collector()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Word], Error>) in
                collector.continuation = c
                collector.task = recognizer.recognitionTask(with: request, delegate: collector)
            }
        } onCancel: {
            collector.task?.cancel()
        }
    }

    /// Gathers each finished piece of a recognition task; answers once the whole file is done.
    private final class Collector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
        var continuation: CheckedContinuation<[Word], Error>?
        var task: SFSpeechRecognitionTask?
        private var words: [Double: Word] = [:]
        private let lock = NSLock()

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
            lock.withLock {
                // Keyed by start time: a later, fuller piece replaces any words it repeats.
                for s in result.bestTranscription.segments {
                    words[(s.timestamp * 100).rounded() / 100] = Word(text: s.substring, start: s.timestamp, duration: s.duration)
                }
            }
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
            let (found, c) = lock.withLock { () -> ([Word], CheckedContinuation<[Word], Error>?) in
                let c = continuation
                continuation = nil
                return (words.values.sorted { $0.start < $1.start }, c)
            }
            guard let c else { return }
            if successfully || !found.isEmpty { c.resume(returning: found); return }
            let error = task.error as NSError?
            // "No speech detected" isn't a failure — just nothing to caption.
            if error == nil || error?.code == 1110 || error?.code == 203 { c.resume(returning: []) }
            else { c.resume(throwing: error!) }
        }
    }

    /// Groups words into caption lines: at most ~7 words or 3 seconds, broken at pauses and sentence ends.
    static func lines(from words: [Word], maxWords: Int = 7, maxDuration: Double = 3, pause: Double = 0.6) -> [TitleItem] {
        var out: [TitleItem] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            var t = TitleItem(text: current.map(\.text).joined(separator: " "), start: first.start,
                              duration: max(0.8, last.end - first.start + 0.15), style: .caption)
            t.isCaption = true
            t.words = current.map { TitleItem.Word(text: $0.text, start: $0.start, end: $0.end) }
            out.append(t)
            current = []
        }
        for w in words {
            if let last = current.last {
                let tooLong = current.count >= maxWords || w.end - current[0].start > maxDuration
                if tooLong || w.start - last.end > pause { flush() }
            }
            current.append(w)
            if let ch = w.text.last, ".?!".contains(ch) { flush() }
        }
        flush()
        // No overlaps: each line ends where the next begins.
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i].duration = max(0.3, out[i + 1].start - out[i].start)
        }
        return out
    }
}
