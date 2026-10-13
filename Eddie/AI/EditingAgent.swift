import AVFoundation
import AppKit
import Foundation

/// One editing action the AI can ask for — its "tools". Flat, so every provider's JSON mode can produce it.
struct EditAction: Codable, Equatable {
    var type: String
    var clip: String? = nil
    var title: String? = nil
    var music: String? = nil
    var target: String? = nil
    var at: Double? = nil
    var duration: Double? = nil
    var keep_from: Double? = nil
    var keep_to: Double? = nil
    var to_position: Double? = nil
    var speed: Double? = nil
    var volume: Double? = nil
    var text: String? = nil
    var style: String? = nil
    var x: Double? = nil
    var y: Double? = nil
    var size: Double? = nil
    var rotation: Double? = nil
    var font: String? = nil
    var color: String? = nil
    var weight: String? = nil
    var starts_at: Double? = nil
    var fade_in: Double? = nil
    var fade_out: Double? = nil
    var preset: String? = nil
    var instruction: String? = nil
    var kind: String? = nil
    var aspect: String? = nil
    var opacity: Double? = nil
    var layout: String? = nil
    var profile: String? = nil
    var fill: Bool? = nil
}

/// Work the agent asks for that the app does after the edit (it takes time or needs the media).
enum EditJob: Equatable {
    case reverse(UUID)
    case freeze(at: Double)
    case normalize(UUID)
    case reduceNoise(UUID)
    case captions
    case beats(UUID)
}

struct EditPlan: Codable {
    var reply: String
    var actions: [EditAction]
    var done: Bool
}

/// A color request the agent hands back to the grading pipeline (it needs frames and its own rounds).
struct ColorRequest: Equatable {
    var clipIDs: [UUID]
    var instruction: String
}

/// Labels the AI uses for things on the timeline: c1, c2… for clips (in order), t1… titles, m1… songs.
struct TimelineLabels {
    var clips: [String: UUID] = [:]
    var titles: [String: UUID] = [:]
    var music: [String: UUID] = [:]
    var overlays: [String: UUID] = [:]
    var markers: [String: UUID] = [:]

    init(_ p: Project) {
        for (i, c) in p.clips.enumerated() { clips["c\(i + 1)"] = c.id }
        for (i, o) in p.overlays.enumerated() { overlays["o\(i + 1)"] = o.id }
        for (i, m) in p.markers.enumerated() { markers["k\(i + 1)"] = m.id }
        for (i, t) in p.titles.enumerated() { titles["t\(i + 1)"] = t.id }
        for (i, m) in p.music.enumerated() { music["m\(i + 1)"] = m.id }
    }
}

// MARK: - Describing the timeline

enum TimelineDescriber {
    static func describe(_ p: Project, playhead: Double) -> String {
        func t(_ s: Double) -> String { String(format: "%.2f s", s) }
        var lines = [String(format: "Timeline: %.2f s long. Playhead at %.2f s.", p.duration, playhead)]
        lines.append("Clips, in order (they play back to back):")
        if p.clips.isEmpty { lines.append("  (none)") }
        for (i, c) in p.clips.enumerated() {
            let start = p.starts[i]
            var extras = ["speed \(c.speed == c.speed.rounded() ? "\(Int(c.speed))" : String(c.speed))×"]
            extras.append(c.audioMuted ? "sound off" : "sound \(Int((c.volume * 100).rounded()))%")
            extras.append(c.recipe.isNeutral ? "no grade" : "graded (\(c.effectiveRecipe.summary))")
            extras.append(c.isPhoto ? "photo" : (c.profile == .dlogM ? "D-Log M footage" : "normal footage"))
            if let tr = c.transitionIn { extras.append(i == 0 ? "fades in from black \(t(tr.duration))" : "\(tr.kind.rawValue) transition in \(t(tr.duration))") }
            if c.reversed { extras.append("reversed") }
            if c.audioFadeIn > 0 || c.audioFadeOut > 0 { extras.append("sound fades \(t(c.audioFadeIn))/\(t(c.audioFadeOut))") }
            if c.transform != .identity { extras.append(framing(c.transform)) }
            if !c.keyframes.isEmpty { extras.append("animated framing (\(c.keyframes.count) keyframes)") }
            lines.append("  c\(i + 1): \"\(c.name)\" at \(t(start))–\(t(start + c.duration)) (\(t(c.duration)) long), " + extras.joined(separator: ", "))
        }
        lines.append("Overlays (on top of the clips, B-roll or picture-in-picture):")
        if p.overlays.isEmpty { lines.append("  (none)") }
        for (i, o) in p.overlays.enumerated() {
            var parts = ["\"\(o.clip.name)\" at \(t(o.start))–\(t(o.end))", o.clip.transform.scale < 0.95 ? "picture-in-picture" : "full frame",
                         "opacity \(Int((o.opacity * 100).rounded()))%"]
            if o.clip.transform != .identity { parts.append(framing(o.clip.transform)) }
            lines.append("  o\(i + 1): " + parts.joined(separator: ", "))
        }
        lines.append("Titles:")
        if p.titles.isEmpty { lines.append("  (none)") }
        for (i, ti) in p.titles.enumerated() {
            var parts = ["\"\(ti.text.replacingOccurrences(of: "\n", with: "\\n"))\" at \(t(ti.start))–\(t(ti.end))", "style \(ti.style.rawValue)"]
            if let x = ti.x, let y = ti.y { parts.append(String(format: "position x %.2f y %.2f", x, y)) }
            parts.append("size \(Int((ti.size * 100).rounded()))%")
            if ti.rotation != 0 { parts.append("rotation \(Int(ti.rotation))°") }
            parts.append("font \(ti.font)")
            parts.append("color \(ti.color)")
            lines.append("  t\(i + 1): " + parts.joined(separator: ", "))
        }
        lines.append("Music:")
        if p.music.isEmpty { lines.append("  (none)") }
        for (i, m) in p.music.enumerated() {
            lines.append("  m\(i + 1) (\(m.kind.rawValue)\(m.beats.isEmpty ? "" : ", beats found")): \"\(m.name)\" at \(t(m.start))–\(t(m.end)), starts \(t(m.sourceStart)) into the song, volume \(Int((m.volume * 100).rounded()))%, fade in \(t(m.fadeIn)), fade out \(t(m.fadeOut))")
        }
        if !p.markers.isEmpty {
            lines.append("Markers: " + p.markers.enumerated().map { "k\($0.offset + 1) \"\($0.element.name)\" at \(t($0.element.time))" }.joined(separator: ", "))
        }
        lines.append("Format: \(p.format.aspect.rawValue)\(p.format.fill ? "" : " (fit inside)"), fade out at the end: \(p.fadeOut > 0 ? t(p.fadeOut) : "none").")
        return lines.joined(separator: "\n")
    }

    static func framing(_ f: Transform2D) -> String {
        var parts = [String(format: "zoom %.2f", f.scale)]
        if f.x != 0 || f.y != 0 { parts.append(String(format: "offset x %.2f y %.2f", f.x, f.y)) }
        if f.rotation != 0 { parts.append("rotated \(Int(f.rotation))°") }
        if f.cropLeft + f.cropRight + f.cropTop + f.cropBottom > 0 { parts.append("cropped") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Carrying out actions

enum EditExecutor {
    struct Result {
        var project: Project
        var log: [String]
        var errors: [String]
        var color: [ColorRequest]
        var seek: Double?
        var jobs: [EditJob] = []
    }

    /// Applies actions in order to a copy of the project. Labels refer to the timeline as it was described.
    static func apply(_ actions: [EditAction], to project: Project, labels: TimelineLabels, playhead: Double,
                      sourceDuration: (URL) -> Double?) -> Result {
        var p = project
        var log: [String] = [], errors: [String] = [], color: [ColorRequest] = []
        var seek: Double?
        var jobs: [EditJob] = []

        func clipID(_ label: String?) -> UUID? { label.flatMap { labels.clips[$0.lowercased()] } }
        func overlayID(_ label: String?) -> UUID? { label.flatMap { labels.overlays[$0.lowercased()] } }
        /// A main-track clip or an overlay (anything with framing).
        func anyClipTargets(_ label: String?) -> [UUID]? {
            if label?.lowercased() == "all" { return p.clips.map(\.id) }
            return (clipID(label) ?? overlayID(label)).map { [$0] }
        }
        func titleID(_ label: String?) -> UUID? { label.flatMap { labels.titles[$0.lowercased()] } }
        func musicID(_ label: String?) -> UUID? { label.flatMap { labels.music[$0.lowercased()] } }
        func clipTargets(_ label: String?) -> [UUID]? {
            if label?.lowercased() == "all" { return p.clips.map(\.id) }
            return clipID(label).map { [$0] }
        }

        for a in actions {
            switch a.type {
            case "split":
                guard let at = a.at else { errors.append("split needs `at`"); continue }
                if p.split(at: at) != nil { log.append(String(format: "Split at %.2f s", at)) }
                else { errors.append(String(format: "Can't split at %.2f s (too close to a cut or outside the video)", at)) }

            case "trim":
                guard let id = clipID(a.clip), let c = p.clips.first(where: { $0.id == id }) else { errors.append("trim: unknown clip \(a.clip ?? "?")"); continue }
                let from = max(0, a.keep_from ?? 0), to = min(c.duration, a.keep_to ?? c.duration)
                guard to - from >= ClipItem.minLength else { errors.append("trim: keep range too short for \(a.clip!)"); continue }
                let full = sourceDuration(c.url) ?? c.sourceEnd
                let newStart = c.sourceStart + from * c.speed, newEnd = c.sourceStart + to * c.speed
                p.trim(id, start: newStart, sourceDuration: full)
                p.trim(id, end: newEnd, sourceDuration: full)
                log.append(String(format: "Trimmed %@ to %.2f–%.2f s of it", a.clip!, from, to))

            case "delete":
                let label = a.target ?? a.clip ?? a.title ?? a.music
                guard let l = label, let id = clipID(l) ?? titleID(l) ?? musicID(l) ?? overlayID(l) ?? labels.markers[l.lowercased()] else { errors.append("delete: unknown \(label ?? "?")"); continue }
                p.remove(id)
                log.append("Deleted \(l)")

            case "move":
                guard let id = clipID(a.clip), let pos = a.to_position.map({ Int($0.rounded()) }) else { errors.append("move needs clip and to_position"); continue }
                p.move(id, to: pos - 1)
                log.append("Moved \(a.clip!) to position \(pos)")

            case "duplicate":
                guard let id = clipID(a.clip), p.duplicate(id) != nil else { errors.append("duplicate: unknown clip \(a.clip ?? "?")"); continue }
                log.append("Duplicated \(a.clip!)")

            case "speed":
                guard let ids = clipTargets(a.clip), let s = a.speed else { errors.append("speed needs clip and speed"); continue }
                for id in ids { p.setSpeed(id, s) }
                log.append("Speed \(s)× on \(a.clip!)")

            case "clip_volume":
                guard let ids = clipTargets(a.clip), var v = a.volume else { errors.append("clip_volume needs clip and volume"); continue }
                if v > 1 { v /= 100 }
                for id in ids { p.updateClip(id) { $0.volume = min(max(v, 0), 1); $0.audioMuted = v <= 0.001 } }
                log.append("Clip sound \(Int(v * 100))% on \(a.clip!)")

            case "add_title":
                let text = (a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { errors.append("add_title needs text"); continue }
                var t = TitleItem(text: text, start: max(0, a.at ?? playhead), duration: max(TitleItem.minLength, a.duration ?? 3),
                                  style: a.style.flatMap(TitleItem.Style.init(rawValue:)) ?? .title)
                applyTitleFields(a, to: &t)
                p.titles.append(t)
                log.append("Added title \"\(text)\"")

            case "edit_title":
                guard let id = titleID(a.title ?? a.target) else { errors.append("edit_title: unknown title \(a.title ?? "?")"); continue }
                p.updateTitle(id) { t in
                    if let text = a.text { t.text = text }
                    if let at = a.at { t.start = max(0, at) }
                    if let d = a.duration { t.duration = max(TitleItem.minLength, d) }
                    if let s = a.style.flatMap(TitleItem.Style.init(rawValue:)) { t.style = s }
                    applyTitleFields(a, to: &t)
                }
                log.append("Edited \(a.title ?? a.target ?? "title")")

            case "music":
                guard let id = musicID(a.music ?? a.target) else { errors.append("music: unknown song \(a.music ?? "?")"); continue }
                p.updateMusic(id) { m in
                    if var v = a.volume { if v > 1 { v /= 100 }; m.volume = min(max(v, 0), 1) }
                    if let at = a.at { m.start = max(0, at) }
                    if let s = a.starts_at {
                        let len = m.duration
                        m.sourceStart = max(0, s)
                        m.sourceEnd = m.sourceStart + len
                    }
                    if let d = a.duration { m.sourceEnd = m.sourceStart + max(0.5, d) }
                    if let f = a.fade_in { m.fadeIn = max(0, f) }
                    if let f = a.fade_out { m.fadeOut = max(0, f) }
                }
                log.append("Updated \(a.music ?? a.target ?? "song")")

            case "preset":
                guard let ids = clipTargets(a.clip), let preset = Preset.all.first(where: { $0.name.lowercased() == a.preset?.lowercased() }) else {
                    errors.append("preset needs clip (or \"all\") and one of: \(Preset.all.map(\.name).joined(separator: ", "))"); continue
                }
                for id in ids { p.updateClip(id) { c in c.recipe = c.effectiveRecipe.adding(preset.adjust); c.intensity = 1 } }
                log.append("Preset \(preset.name) on \(a.clip!)")

            case "color":
                guard let ids = clipTargets(a.clip) else { errors.append("color: unknown clip \(a.clip ?? "?")"); continue }
                color.append(ColorRequest(clipIDs: ids, instruction: (a.instruction ?? "").trimmingCharacters(in: .whitespaces)))
                log.append("Will color \(a.clip!)\(a.instruction.map { ": \($0)" } ?? "")")

            case "seek":
                if let at = a.at { seek = at }

            case "transition":
                guard let ids = clipTargets(a.clip) else { errors.append("transition: unknown clip \(a.clip ?? "?")"); continue }
                let kindName = (a.kind ?? "crossDissolve").lowercased()
                let kind = Transition.Kind.allCases.first { $0.rawValue.lowercased() == kindName }
                for id in ids {
                    // "all" means every cut, not the very first clip (that one would be a fade from black).
                    if a.clip?.lowercased() == "all", p.clips.first?.id == id { continue }
                    p.updateClip(id) { c in
                        if kindName == "none" { c.transitionIn = nil }
                        else { c.transitionIn = Transition(kind: kind ?? .crossDissolve, duration: min(max(a.duration ?? 0.6, 0.2), 3)) }
                    }
                }
                log.append(kindName == "none" ? "Removed transition on \(a.clip!)" : "\(kind?.label ?? "Cross Dissolve") into \(a.clip!)")

            case "fade":
                // Fade from black at the start and/or to black at the end.
                if let f = a.fade_in, let first = p.clips.first {
                    p.updateClip(first.id) { $0.transitionIn = f > 0 ? Transition(kind: .dipToBlack, duration: min(f, 5)) : nil }
                }
                if let f = a.fade_out { p.fadeOut = min(max(f, 0), 8) }
                log.append("Set fades")

            case "clip_fade":
                guard let ids = anyClipTargets(a.clip) else { errors.append("clip_fade: unknown clip \(a.clip ?? "?")"); continue }
                for id in ids {
                    p.updateClip(id) { c in
                        if let f = a.fade_in { c.audioFadeIn = min(max(f, 0), c.duration / 2) }
                        if let f = a.fade_out { c.audioFadeOut = min(max(f, 0), c.duration / 2) }
                    }
                }
                log.append("Sound fades on \(a.clip!)")

            case "format":
                let name = (a.aspect ?? "").lowercased()
                let aliases = ["9:16": "portrait", "vertical": "portrait", "16:9": "landscape", "1:1": "square", "4:5": "portrait4x5"]
                guard let aspect = ProjectFormat.Aspect(rawValue: aliases[name] ?? name)
                        ?? ProjectFormat.Aspect.allCases.first(where: { $0.rawValue.lowercased() == (aliases[name] ?? name) }) else {
                    errors.append("format: aspect must be auto, landscape, portrait, square or portrait4x5"); continue
                }
                p.format.aspect = aspect
                if let f = a.fill { p.format.fill = f }
                log.append("Format \(aspect.label)")

            case "framing":
                guard let ids = anyClipTargets(a.clip ?? a.target) else { errors.append("framing: unknown clip \(a.clip ?? "?")"); continue }
                for id in ids {
                    p.updateClip(id) { c in
                        var f = c.transform
                        if let z = a.size { f.scale = min(max(z, 0.1), 5) }
                        if let x = a.x { f.x = min(max(x, -1), 1) }
                        if let y = a.y { f.y = min(max(y, -1), 1) }
                        if let r = a.rotation { f.rotation = r }
                        c.transform = f
                        c.keyframes = []
                    }
                }
                log.append("Framing on \(a.clip ?? a.target ?? "clip")")

            case "ken_burns":
                guard let ids = anyClipTargets(a.clip) else { errors.append("ken_burns: unknown clip \(a.clip ?? "?")"); continue }
                let zoom = min(max(a.size ?? 1.18, 1.02), 2)
                for id in ids {
                    p.updateClip(id) { c in
                        c.keyframes = [Keyframe(time: 0, transform: Transform2D(scale: 1)),
                                       Keyframe(time: c.duration, transform: Transform2D(scale: zoom, x: 0.03, y: -0.02))]
                    }
                }
                log.append("Slow zoom on \(a.clip!)")

            case "profile":
                guard let ids = anyClipTargets(a.clip), let prof = SourceProfile.allCases.first(where: {
                    $0.rawValue.lowercased() == (a.profile ?? "").lowercased() || $0.label.lowercased() == (a.profile ?? "").lowercased()
                }) else { errors.append("profile needs clip and profile (dlogM or normal)"); continue }
                for id in ids { p.updateClip(id) { $0.profile = prof } }
                log.append("\(a.clip!) is \(prof.label) footage")

            case "overlay":
                guard let id = overlayID(a.target ?? a.clip) else { errors.append("overlay: unknown overlay \(a.target ?? "?")"); continue }
                p.updateOverlay(id) { o in
                    if let at = a.at { o.start = max(0, at) }
                    if var op = a.opacity { if op > 1 { op /= 100 }; o.opacity = min(max(op, 0), 1) }
                    if let d = a.duration { o.clip.sourceEnd = o.clip.sourceStart + max(0.3, d) * o.clip.speed }
                    switch a.layout?.lowercased() {
                    case "pip": o.clip.transform = EditorModelPiP.transform; o.clip.keyframes = []
                    case "full": o.clip.transform = .identity; o.clip.keyframes = []
                    default: break
                    }
                    if var v = a.volume { if v > 1 { v /= 100 }; o.clip.volume = min(max(v, 0), 1); o.clip.audioMuted = v <= 0.001 }
                }
                log.append("Updated \(a.target ?? a.clip ?? "overlay")")

            case "marker":
                guard let at = a.at else { errors.append("marker needs at"); continue }
                p.markers.append(Marker(time: max(0, at), name: a.text ?? "Marker"))
                p.markers.sort { $0.time < $1.time }
                log.append(String(format: "Marker at %.2f s", at))

            case "reverse":
                guard let ids = anyClipTargets(a.clip) else { errors.append("reverse: unknown clip \(a.clip ?? "?")"); continue }
                for id in ids { jobs.append(.reverse(id)) }
                log.append("Will reverse \(a.clip!)")

            case "freeze":
                jobs.append(.freeze(at: a.at ?? playhead))
                log.append("Will freeze the frame at \(String(format: "%.2f", a.at ?? playhead)) s")

            case "clean_audio":
                let label = a.target ?? a.clip ?? a.music
                let noise = (a.kind ?? "").lowercased().contains("noise")
                if let id = musicID(label) {
                    jobs.append(noise ? .reduceNoise(id) : .normalize(id))
                } else if let ids = anyClipTargets(label) {
                    for id in ids { jobs.append(noise ? .reduceNoise(id) : .normalize(id)) }
                } else { errors.append("clean_audio: unknown \(label ?? "?")"); continue }
                log.append("Will \(noise ? "remove noise from" : "normalize") \(label!)")

            case "captions":
                jobs.append(.captions)
                log.append("Will add captions from speech")

            case "beats":
                guard let id = musicID(a.music ?? a.target) else { errors.append("beats: unknown song \(a.music ?? "?")"); continue }
                jobs.append(.beats(id))
                log.append("Will find the beat of \(a.music ?? a.target!)")

            default:
                errors.append("Unknown action \(a.type)")
            }
        }
        return Result(project: p, log: log, errors: errors, color: color, seek: seek, jobs: jobs)
    }

    private static func applyTitleFields(_ a: EditAction, to t: inout TitleItem) {
        if let x = a.x { t.x = min(max(x, 0), 1); if t.y == nil { t.y = 0.5 } }
        if let y = a.y { t.y = min(max(y, 0), 1); if t.x == nil { t.x = 0.5 } }
        if let s = a.size { t.size = min(max(s > 4 ? s / 100 : s, 0.3), 4) }
        if let r = a.rotation { t.rotation = r }
        if let f = a.font, !f.isEmpty { t.font = f }
        if let c = a.color, c.hasPrefix("#"), c.count == 7 { t.color = c.uppercased() }
        if let w = a.weight.flatMap(TitleItem.Weight.init(rawValue:)) { t.weight = w }
    }
}

// MARK: - The agent

/// Turns a plain-language request into editing actions, applies them, shows the AI the result, and repeats
/// until it says it's done (at most a few rounds).
struct EditingAgent {
    var model: VisionModel
    var maxRounds = 4

    struct Step {
        var project: Project
        var reply: String
        var log: [String]
        var color: [ColorRequest]
        var seek: Double?
        var jobs: [EditJob] = []
    }

    func run(request: String, project start: Project, playhead: Double, frames: [(time: Double, jpeg: Data)],
             sourceDuration: @escaping (URL) -> Double?, progress: @MainActor (String) -> Void) async throws -> Step {
        var project = start
        var allLog: [String] = [], allColor: [ColorRequest] = [], allJobs: [EditJob] = []
        var seek: Double?
        var reply = ""
        var feedback = ""

        for round in 1...maxRounds {
            try Task.checkCancellation()
            await progress(round == 1 ? "Planning the edit…" : "Checking the result (step \(round))…")
            let labels = TimelineLabels(project)
            var text = """
            The user asked: "\(request)"

            \(TimelineDescriber.describe(project, playhead: playhead))
            """
            if round == 1, !frames.isEmpty {
                text += "\n\nThe attached images are frames from the timeline at: " +
                    frames.enumerated().map { String(format: "image %d = %.1f s", $0.offset + 1, $0.element.time) }.joined(separator: ", ") + "."
            }
            if !feedback.isEmpty { text += "\n\nWhat happened after your last actions:\n\(feedback)" }
            text += "\n\nReply with the JSON object. Use an empty actions list and done=true when the request is fully handled."

            let raw = try await model.complete(VisionRequest(system: Self.system, text: text,
                                                             images: round == 1 ? frames.map(\.jpeg) : [],
                                                             schema: Self.schema, schemaName: "edit_plan"))
            guard let data = JSONExtraction.object(in: raw), let plan = try? JSONDecoder().decode(EditPlan.self, from: data) else {
                throw VisionModelError.invalidJSON(raw)
            }
            reply = plan.reply
            if plan.actions.isEmpty { break }
            let result = EditExecutor.apply(plan.actions, to: project, labels: labels, playhead: playhead, sourceDuration: sourceDuration)
            project = result.project
            allLog += result.log
            allColor += result.color
            allJobs += result.jobs
            seek = result.seek ?? seek
            feedback = (result.log.map { "OK: \($0)" } + result.errors.map { "Error: \($0)" }).joined(separator: "\n")
            if plan.done && result.errors.isEmpty { break }
        }
        return Step(project: project, reply: reply, log: allLog, color: allColor, seek: seek, jobs: allJobs)
    }

    static let system = """
    You are the editor inside Eddie, a video editing app. You edit by returning actions; the app performs them \
    and shows you the updated timeline. All times are timeline seconds unless noted. Clips play back to back, so \
    deleting or trimming a clip shifts everything after it.

    Reply with one JSON object: {"reply": string, "actions": [action…], "done": boolean}.
    "reply" is one or two short, friendly sentences for the user about what you did (or why you can't).
    Each action is an object with "type" and the fields it needs (leave other fields null):
    - split: at — cut the clip under that time into two.
    - trim: clip, keep_from, keep_to — keep only that part of the clip, in seconds from the clip's own start (0 … its length).
    - delete: target — a clip (c2), title (t1) or song (m1).
    - move: clip, to_position — 1 = first.
    - duplicate: clip.
    - speed: clip (or "all"), speed — 0.25 to 4.
    - clip_volume: clip (or "all"), volume — 0 to 1 (0 mutes the clip's own sound).
    - add_title: text, at, duration, style ("title" | "lowerThird" | "caption"), optional x and y (0–1, center of the \
    text, y from the top), size (1 = normal, 0.3–4), rotation (degrees, clockwise), font ("System", "Rounded", "Serif", \
    "Mono" or a font family like "Georgia", "Futura", "Avenir Next", "Didot", "Marker Felt"), color ("#RRGGBB"), weight \
    ("regular" | "medium" | "bold" | "heavy"). Use \\n for a line break.
    - edit_title: title, then any of the add_title fields to change.
    - music: music, optional volume (0–1), at (timeline start), starts_at (seconds into the song), duration, fade_in, fade_out.
    - preset: clip (or "all"), preset — one of Warm, Cool, Bright, Punchy, Soft, Vivid, Moody, Cinematic, Golden, Faded, Mono.
    - color: clip (or "all"), instruction — hand off to the AI colorist for a proper grade ("natural", "warmer", "cinematic"…).
    - seek: at — move the playhead to show the user the result.
    - transition: clip (or "all" for every cut), kind ("crossDissolve" | "dipToBlack" | "wipe" | "slide" | "none"),     duration (0.2–3) — the transition INTO that clip from the one before.
    - fade: fade_in (seconds, fade from black at the start; 0 removes), fade_out (seconds, fade to black at the end).
    - clip_fade: clip (or overlay, or "all"), fade_in, fade_out — fade the clip's own sound in/out.
    - format: aspect ("landscape" 16:9 | "portrait" 9:16 for Reels/TikTok/Shorts | "square" | "portrait4x5" | "auto"),     optional fill (true = crop to fill the frame, false = fit inside with black bars).
    - framing: clip or overlay, any of size (zoom, 1 = normal), x and y (offset, -1…1 of the frame, y down), rotation.
    - ken_burns: clip or overlay (or "all"), optional size (end zoom, e.g. 1.2) — a slow push-in.
    - profile: clip or overlay (or "all"), profile ("dlogM" for DJI log footage | "normal" for phone/normal footage).
    - overlay: target (o1…), optional at, duration, opacity (0–1), layout ("pip" | "full"), volume.
    - marker: at, text.
    - reverse: clip or overlay — play it backwards (toggles).
    - freeze: at — hold that frame for 2 seconds (inserted there).
    - clean_audio: target (a clip, overlay or song), kind ("normalize" | "noise") — even out loudness or remove background noise.
    - captions: — transcribe the speech in the clips into captions (replaces earlier auto captions).
    - beats: music — find the song's beat so cuts can line up with it.

    Labels: c1, c2… are clips in their current order; o1… overlays; t1… titles; m1… songs, voiceovers and sound effects; k1… markers. Labels are renumbered every step, so always \
    use the labels from the latest timeline you were shown. Do all you can in one step; you'll see the result and can fix \
    anything. When the request is fully done, return no actions and done=true. If a request needs something you can't \
    do (for example adding a new video or song file), say so in "reply".
    """

    static let schema: [String: Any] = {
        func nullable(_ type: String) -> [String: Any] { ["type": [type, "null"]] }
        let fields: [String: [String: Any]] = [
            "type": ["type": "string", "enum": ["split", "trim", "delete", "move", "duplicate", "speed", "clip_volume", "add_title",
                                                "edit_title", "music", "preset", "color", "seek", "transition", "fade", "clip_fade",
                                                "format", "framing", "ken_burns", "profile", "overlay", "marker", "reverse", "freeze",
                                                "clean_audio", "captions", "beats"]],
            "clip": nullable("string"), "title": nullable("string"), "music": nullable("string"), "target": nullable("string"),
            "at": nullable("number"), "duration": nullable("number"), "keep_from": nullable("number"), "keep_to": nullable("number"),
            "to_position": nullable("integer"), "speed": nullable("number"), "volume": nullable("number"),
            "text": nullable("string"), "style": nullable("string"), "x": nullable("number"), "y": nullable("number"),
            "size": nullable("number"), "rotation": nullable("number"), "font": nullable("string"), "color": nullable("string"),
            "weight": nullable("string"), "starts_at": nullable("number"), "fade_in": nullable("number"),
            "fade_out": nullable("number"), "preset": nullable("string"), "instruction": nullable("string"),
            "kind": nullable("string"), "aspect": nullable("string"), "opacity": nullable("number"), "layout": nullable("string"),
            "profile": nullable("string"), "fill": nullable("boolean"),
        ]
        let action: [String: Any] = [
            "type": "object",
            "properties": fields,
            "required": Array(fields.keys).sorted(),
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "reply": ["type": "string"],
                "actions": ["type": "array", "items": action],
                "done": ["type": "boolean"],
            ],
            "required": ["reply", "actions", "done"],
            "additionalProperties": false,
        ]
    }()
}

/// The picture-in-picture framing (shared by the AI and the UI).
enum EditorModelPiP {
    static let transform = Transform2D(scale: 0.32, x: 0.3, y: -0.28)
}
