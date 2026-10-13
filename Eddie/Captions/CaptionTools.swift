import AVFoundation
import Foundation

// MARK: - SRT

/// SubRip (.srt) captions: the format YouTube, Premiere, CapCut and most players read and write.
enum SRT {
    static func export(_ captions: [TitleItem]) -> String {
        captions.sorted { $0.start < $1.start }.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [(start: Double, end: Double, text: String)] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let a = seconds(parts[0]), let b = seconds(parts[1]), b > a else { return nil }
            let body = lines[(timing + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)   // <i>, <b>, <font…>
            return body.isEmpty ? nil : (a, b, body)
        }
    }

    static func stamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// "00:01:02,500" or "00:01:02.500" (also tolerates "1:02.5").
    static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first?
            .replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) } ?? []
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

// MARK: - Styles

/// One-click caption looks, applied to every caption at once.
struct CaptionPreset: Identifiable {
    let name: String
    let apply: (inout TitleItem) -> Void
    var id: String { name }

    static let all: [CaptionPreset] = [
        CaptionPreset(name: "Classic") { t in
            t.font = "System"; t.weight = .medium; t.color = "#FFFFFF"; t.plate = true; t.outline = 0; t.glow = 0
            t.wordHighlight = false; t.animation = .fade; t.size = 1; t.italic = false
        },
        CaptionPreset(name: "Bold") { t in
            t.font = "System"; t.weight = .heavy; t.color = "#FFFFFF"; t.plate = false; t.outline = 0.14
            t.outlineColor = "#000000"; t.glow = 0; t.wordHighlight = false; t.animation = .pop; t.size = 1.35; t.italic = false
        },
        CaptionPreset(name: "Highlight") { t in
            t.font = "System"; t.weight = .heavy; t.color = "#FFFFFF"; t.plate = false; t.outline = 0.14
            t.outlineColor = "#000000"; t.glow = 0; t.wordHighlight = true; t.highlightColor = "#FFD60A"
            t.animation = .pop; t.size = 1.35; t.italic = false
        },
        CaptionPreset(name: "Karaoke") { t in
            t.font = "Rounded"; t.weight = .bold; t.color = "#FFFFFF"; t.plate = true; t.outline = 0; t.glow = 0
            t.wordHighlight = true; t.highlightColor = "#34C759"; t.animation = .fade; t.size = 1.15; t.italic = false
        },
        CaptionPreset(name: "Neon") { t in
            t.font = "Rounded"; t.weight = .bold; t.color = "#FFFFFF"; t.plate = false; t.outline = 0
            t.glow = 0.8; t.glowColor = "#FF2DCD"; t.wordHighlight = false; t.animation = .fade; t.size = 1.2; t.italic = false
        },
        CaptionPreset(name: "Typewriter") { t in
            t.font = "Mono"; t.weight = .medium; t.color = "#FFFFFF"; t.plate = true; t.outline = 0; t.glow = 0
            t.wordHighlight = false; t.animation = .typewriter; t.size = 1; t.italic = false
        },
        CaptionPreset(name: "Minimal") { t in
            t.font = "System"; t.weight = .regular; t.color = "#FFFFFF"; t.plate = false; t.outline = 0; t.glow = 0
            t.wordHighlight = false; t.animation = .fade; t.size = 0.95; t.italic = false
        },
        CaptionPreset(name: "Serif") { t in
            t.font = "Georgia"; t.weight = .bold; t.color = "#FFF4D6"; t.plate = false; t.outline = 0.06
            t.outlineColor = "#1A1A1A"; t.glow = 0; t.wordHighlight = false; t.animation = .slideUp; t.size = 1.15; t.italic = false
        },
    ]
}

// MARK: - Making captions

enum CaptionMaker {
    /// Captions from typed or pasted text: one caption per line (long lines are split), spread over
    /// `start…end` in proportion to their length.
    static func manual(_ script: String, from start: Double, to end: Double, maxChars: Int = 42) -> [TitleItem] {
        let lines = script.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .flatMap { chunk($0, maxChars: maxChars) }
        guard !lines.isEmpty, end - start > 0.2 else { return [] }
        let total = Double(lines.reduce(0) { $0 + $1.count + 4 })
        var t = start
        return lines.map { line in
            let d = (end - start) * Double(line.count + 4) / total
            defer { t += d }
            var c = TitleItem(text: line, start: t, duration: max(0.4, d - 0.05), style: .caption)
            c.isCaption = true
            return c
        }
    }

    /// Breaks a long line into pieces of at most `maxChars`, at spaces.
    static func chunk(_ line: String, maxChars: Int) -> [String] {
        guard line.count > maxChars else { return [line] }
        var out: [String] = [], current = ""
        for word in line.split(separator: " ") {
            if !current.isEmpty, current.count + word.count + 1 > maxChars { out.append(current); current = "" }
            current += current.isEmpty ? String(word) : " " + word
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func fromSRT(_ text: String) -> [TitleItem] {
        SRT.parse(text).map { e in
            var c = TitleItem(text: e.text, start: e.start, duration: e.end - e.start, style: .caption)
            c.isCaption = true
            return c
        }
    }

    // MARK: Translation

    /// Translates caption lines with the AI provider set in Settings (same number of lines back).
    static func translate(_ lines: [String], to language: String, model: VisionModel) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["lines": ["type": "array", "items": ["type": "string"]]],
            "required": ["lines"], "additionalProperties": false,
        ]
        let input = String(data: try JSONSerialization.data(withJSONObject: lines), encoding: .utf8) ?? "[]"
        let raw = try await model.complete(VisionRequest(
            system: "You translate video captions. Keep each line short and natural for on-screen reading. Keep names. Return exactly one translated line per input line, in the same order.",
            text: "Translate these \(lines.count) caption lines into \(language). Reply with JSON {\"lines\": [...]}.\n\(input)",
            images: [], schema: schema, schemaName: "translation"))
        guard let data = JSONExtraction.object(in: raw),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = obj["lines"] as? [String] else { throw VisionModelError.invalidJSON(raw) }
        guard out.count == lines.count else {
            throw NSError(domain: "Eddie", code: 1, userInfo: [NSLocalizedDescriptionKey: "The translation came back with \(out.count) lines instead of \(lines.count). Try again."])
        }
        return out
    }
}

// MARK: - Tightening the edit

enum SpeechCleanup {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh", "hmm", "hm", "mm", "mhm"]

    /// Timeline ranges of filler words ("um", "uh"…), padded slightly.
    static func fillerRanges(_ words: [Captioner.Word]) -> [(start: Double, end: Double)] {
        words.filter { fillers.contains($0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            .map { (max(0, $0.start - 0.03), $0.end + 0.03) }
    }

    /// Timeline ranges where the clips' own sound stays quiet for at least `minimum` seconds,
    /// keeping `keep` seconds at each edge so cuts don't clip words.
    static func silenceRanges(_ project: Project, minimum: Double = 0.7, keep: Double = 0.15,
                              threshold: Float = 0.02) async -> [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []
        let starts = project.starts
        let perSecond = 50.0
        for (i, clip) in project.clips.enumerated() where !clip.isPhoto && !clip.reversed {
            let asset = AVURLAsset(url: clip.audioOverride ?? clip.url)
            guard let full = try? await asset.load(.duration).seconds, full > 0 else { continue }
            let peaks = (try? await Waveform.peaks(of: asset, buckets: max(10, Int(full * perSecond)))) ?? []
            guard !peaks.isEmpty else { continue }
            let bucket = full / Double(peaks.count)
            var runStart: Double?
            func close(_ end: Double) {
                guard let s = runStart else { return }
                runStart = nil
                guard end - s >= minimum else { return }
                // Source seconds → timeline seconds.
                let a = starts[i] + (s - clip.sourceStart) / clip.speed + keep
                let b = starts[i] + (end - clip.sourceStart) / clip.speed - keep
                if b - a > 0.1 { out.append((a, b)) }
            }
            var t = clip.sourceStart
            while t < clip.sourceEnd {
                let p = peaks[min(peaks.count - 1, Int(t / bucket))]
                if p < threshold { if runStart == nil { runStart = t } } else { close(t) }
                t += bucket
            }
            close(clip.sourceEnd)
        }
        return out
    }
}
