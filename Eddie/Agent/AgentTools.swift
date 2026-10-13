import AppKit
import Foundation

/// What an agent's tool call does inside Eddie. Each call that changes the edit is one undo step, and the
/// user sees it happen in the window.
@MainActor
enum AgentTools {
    struct Reply: Sendable {
        var ok = true
        var text: String
        var image: Data? = nil

        static func fail(_ text: String) -> Reply { Reply(ok: false, text: text) }
    }

    static func handle(_ tool: String, _ args: [String: Any], model: EditorModel) async -> Reply {
        switch tool {
        case "get_timeline": return timeline(model)
        case "list_projects": return listProjects(model)
        case "open_project": return await openProject(args, model)
        case "new_project": return newProject(args, model)
        case "add_media": return await addMedia(args, model)
        case "edit": return edit(args, model)
        case "get_frame": return await frame(args, model)
        case "set_grade": return setGrade(args, model)
        case "auto_grade": return await autoGrade(args, model)
        case "control": return control(args, model)
        case "export": return await export(args, model)
        default: return .fail("Unknown tool \(tool).")
        }
    }

    // MARK: Looking

    static func timeline(_ model: EditorModel) -> Reply {
        guard model.currentProjectID != nil, !model.showingLibrary else {
            return Reply(text: "No project is open. Use list_projects and open_project, or new_project.")
        }
        var lines = ["Project: \(model.fileName.isEmpty ? "Untitled" : model.fileName)"]
        if model.project.isEmpty && model.project.overlays.isEmpty && model.project.music.isEmpty {
            lines.append("The timeline is empty. Add footage with add_media (as: clip).")
        } else {
            lines.append(TimelineDescriber.describe(model.project, playhead: model.clock.time))
            lines.append("Frame size \(Int(model.projectSize.width))×\(Int(model.projectSize.height)), \(Int(model.frameRate.rounded())) fps.")
        }
        if model.busy { lines.append("Eddie's AI is busy: \(model.status ?? "working").") }
        if let p = model.exportProgress { lines.append("Exporting: \(Int(p * 100))%.") }
        return Reply(text: lines.joined(separator: "\n"))
    }

    static func listProjects(_ model: EditorModel) -> Reply {
        model.library.reload()
        let f = ISO8601DateFormatter()
        let rows = model.library.projects.map { p in
            "- \(p.name) — id \(p.id.uuidString), \(String(format: "%.1f", p.duration)) s, \(p.clipCount) clip\(p.clipCount == 1 ? "" : "s"), edited \(f.string(from: p.modified))"
                + (p.id == model.currentProjectID && !model.showingLibrary ? " (open)" : "")
        }
        return Reply(text: rows.isEmpty ? "No projects yet. Use new_project." : "Projects:\n" + rows.joined(separator: "\n"))
    }

    static func frame(_ args: [String: Any], _ model: EditorModel) async -> Reply {
        guard model.hasProject else { return .fail("Nothing on the timeline yet.") }
        let t = number(args["time"]) ?? model.clock.time
        let width = CGFloat(min(1920, max(320, number(args["width"]) ?? 960)))
        guard let jpeg = await model.frame(at: t, width: width) else { return .fail("Couldn't render that frame.") }
        return Reply(text: String(format: "Frame at %.2f s of %.2f s.", min(t, model.project.duration), model.project.duration), image: jpeg)
    }

    // MARK: Projects

    static func openProject(_ args: [String: Any], _ model: EditorModel) async -> Reply {
        model.library.reload()
        let projects = model.library.projects
        var match: ProjectInfo?
        if let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)) { match = projects.first { $0.id == id } }
        if match == nil, let name = (args["name"] as? String)?.lowercased(), !name.isEmpty {
            match = projects.first { $0.name.lowercased() == name } ?? projects.first { $0.name.lowercased().contains(name) }
        }
        guard let info = match else { return .fail("No project matches. Use list_projects to see them.") }
        model.openProject(id: info.id)
        if let r = model.relink, r.id == info.id {
            return .fail("\(info.name) uses files that were moved: \(r.missing.map(\.lastPathComponent).joined(separator: ", ")). The user needs to find them in Eddie first.")
        }
        await waitUntil(30) { model.currentProjectID == info.id && !model.showingLibrary && !model.loadingProject }
        try? await Task.sleep(for: .milliseconds(300))
        return timeline(model)
    }

    static func newProject(_ args: [String: Any], _ model: EditorModel) -> Reply {
        model.createProject()
        if let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty, let id = model.currentProjectID {
            try? model.library.rename(id, to: name)
            model.objectWillChange.send()
        }
        return Reply(text: "Created and opened \"\(model.fileName.isEmpty ? "Untitled Project" : model.fileName)\". Add footage with add_media.")
    }

    // MARK: Adding media

    static func addMedia(_ args: [String: Any], _ model: EditorModel) async -> Reply {
        let paths = (args["paths"] as? [String]) ?? ((args["path"] as? String).map { [$0] } ?? [])
        guard !paths.isEmpty else { return .fail("Give paths: an array of absolute file paths.") }
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else { return .fail("Not found: \(missing.map(\.path).joined(separator: ", "))") }
        if model.currentProjectID == nil || model.showingLibrary { model.createProject() }
        let kind = (args["as"] as? String) ?? "clip"
        let at = number(args["at"])
        var notes: [String] = []

        switch kind {
        case "bin":
            model.importToBin(urls)
            notes.append("Added \(urls.count) file\(urls.count == 1 ? "" : "s") to the media bin.")
        case "music", "effect", "voiceover":
            let k: MusicItem.Kind = kind == "effect" ? .effect : (kind == "voiceover" ? .voiceover : .music)
            for url in urls {
                let before = model.project.music.count
                model.addMusic(url, at: at, kind: k)
                await waitUntil(20) { model.project.music.count > before || model.alert != nil }
                if let a = model.alert { model.alert = nil; return .fail(a) }
                notes.append("Added \(url.lastPathComponent) as \(kind).")
            }
        case "overlay":
            var start = at ?? model.clock.time
            for url in urls {
                do {
                    var c = try await model.makeClip(url)
                    c.audioMuted = true
                    if c.isPhoto { c.sourceEnd = 3 }
                    let item = OverlayItem(clip: c, start: start)
                    model.mutate(.push) { $0.overlays.append(item) }
                    start += c.duration
                    notes.append("Added \(url.lastPathComponent) as an overlay.")
                } catch {
                    return .fail("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        default:
            var clips: [ClipItem] = []
            for url in urls {
                do { clips.append(try await model.makeClip(url)) } catch {
                    return .fail("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let wasEmpty = model.project.isEmpty
            model.mutate(.push) { p in
                if let at, !p.isEmpty { p.insert(clips, atTime: at) } else { p.clips.append(contentsOf: clips) }
            }
            if wasEmpty { model.seek(to: 0) }
            notes.append("Added \(clips.count) clip\(clips.count == 1 ? "" : "s").")
        }
        try? await Task.sleep(for: .milliseconds(200))
        return Reply(text: notes.joined(separator: "\n") + "\n\n" + timeline(model).text)
    }

    // MARK: Editing

    static func edit(_ args: [String: Any], _ model: EditorModel) -> Reply {
        guard model.currentProjectID != nil, !model.showingLibrary else { return .fail("No project is open.") }
        guard let raw = args["actions"] as? [[String: Any]], !raw.isEmpty else {
            return .fail("Give actions: an array of objects with a \"type\".")
        }
        var actions: [EditAction] = []
        for (i, a) in raw.enumerated() {
            guard let data = try? JSONSerialization.data(withJSONObject: a),
                  let action = try? JSONDecoder().decode(EditAction.self, from: data) else {
                return .fail("Action \(i + 1) isn't valid: \(a)")
            }
            actions.append(action)
        }
        let durations = model.media.mapValues { $0.duration.seconds }.merging(model.musicMedia.mapValues(\.duration)) { a, _ in a }
        let result = EditExecutor.apply(actions, to: model.project, labels: TimelineLabels(model.project),
                                        playhead: model.clock.time, sourceDuration: { durations[$0] })
        if result.project != model.project { model.mutate(.push) { $0 = result.project } }
        if let s = result.seek { model.seek(to: s) }
        for job in result.jobs { model.perform(job) }
        for work in result.color { Task { await model.runColor(work) } }

        var lines: [String] = []
        if !result.log.isEmpty { lines.append("Done:\n" + result.log.map { "- \($0)" }.joined(separator: "\n")) }
        if !result.errors.isEmpty { lines.append("Problems:\n" + result.errors.map { "- \($0)" }.joined(separator: "\n")) }
        if !result.jobs.isEmpty || !result.color.isEmpty {
            lines.append("Some work (color, reverse, audio clean-up, captions, beats) continues in the background — check get_timeline in a moment.")
        }
        lines.append(timeline(model).text)
        return Reply(ok: result.errors.isEmpty || !result.log.isEmpty, text: lines.joined(separator: "\n\n"))
    }

    static func setGrade(_ args: [String: Any], _ model: EditorModel) -> Reply {
        guard let label = args["clip"] as? String else { return .fail("Give clip: c1, o1… or \"all\".") }
        let labels = TimelineLabels(model.project)
        let ids: [UUID]
        if label.lowercased() == "all" { ids = model.project.clips.map(\.id) }
        else if let id = labels.clips[label.lowercased()] ?? labels.overlays[label.lowercased()] { ids = [id] }
        else { return .fail("Unknown clip \(label). Use get_timeline for labels.") }
        let knobs = (args["knobs"] as? [String: Any]) ?? [:]
        let unknown = knobs.keys.filter { k in !GradeRecipe.knobs.contains { $0.name == k } }
        guard unknown.isEmpty else {
            return .fail("Unknown knobs: \(unknown.joined(separator: ", ")). Use: \(GradeRecipe.knobs.map(\.name).joined(separator: ", ")).")
        }
        let reset = args["reset"] as? Bool ?? false
        let strength = number(args["strength"])
        model.mutate(.push) { p in
            for id in ids {
                p.updateClip(id) { c in
                    if reset { c.recipe = .neutral }
                    for knob in GradeRecipe.knobs {
                        if let v = number(knobs[knob.name]) { c.recipe[keyPath: knob.key] = min(max(v, knob.range.lowerBound), knob.range.upperBound) }
                    }
                    if let s = strength { c.intensity = min(max(s, 0), 1.5) }
                }
            }
        }
        let summary = ids.compactMap { model.project.clip($0) }.map { "\($0.name): \($0.recipe.isNeutral ? "no grade" : $0.effectiveRecipe.summary)" }
        return Reply(text: "Graded.\n" + summary.joined(separator: "\n"))
    }

    static func autoGrade(_ args: [String: Any], _ model: EditorModel) async -> Reply {
        guard model.hasProject else { return .fail("Nothing on the timeline yet.") }
        guard !model.busy else { return .fail("Eddie's AI is already working.") }
        let label = ((args["clip"] as? String) ?? "c1").lowercased()
        let instruction = (args["instruction"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if label == "all" {
            if instruction.isEmpty { model.autoGradeAll() }
            else { await model.runColor(ColorRequest(clipIDs: model.project.clips.map(\.id), instruction: instruction)) }
        } else {
            guard let id = TimelineLabels(model.project).clips[label] else { return .fail("Unknown clip \(label).") }
            model.selection = id
            if instruction.isEmpty { model.autoGrade() } else { model.refine(instruction) }
        }
        try? await Task.sleep(for: .milliseconds(300))
        await waitUntil(240) { !model.busy }
        if let e = model.errorMessage { return .fail("The colorist couldn't finish: \(e)") }
        var text = model.note.map { "Colorist: \($0.text)" } ?? "Graded."
        text += "\n\n" + timeline(model).text
        return Reply(text: text)
    }

    // MARK: Control and export

    static func control(_ args: [String: Any], _ model: EditorModel) -> Reply {
        switch args["action"] as? String {
        case "play": if !model.clock.playing { model.togglePlay() }; return Reply(text: "Playing.")
        case "pause": if model.clock.playing { model.togglePlay() }; return Reply(text: "Paused.")
        case "seek":
            guard let t = number(args["time"]) else { return .fail("seek needs time.") }
            model.seek(to: t)
            return Reply(text: String(format: "Playhead at %.2f s.", model.clock.time))
        case "undo":
            guard model.canUndo else { return .fail("Nothing to undo.") }
            model.undo(); return Reply(text: "Undone.\n\n" + timeline(model).text)
        case "redo":
            guard model.canRedo else { return .fail("Nothing to redo.") }
            model.redo(); return Reply(text: "Redone.\n\n" + timeline(model).text)
        case "save": model.saveNow(); return Reply(text: "Saved.")
        default: return .fail("action must be play, pause, seek, undo, redo or save.")
        }
    }

    static func export(_ args: [String: Any], _ model: EditorModel) async -> Reply {
        guard model.hasProject else { return .fail("Nothing to export.") }
        guard let path = args["path"] as? String, !path.isEmpty else { return .fail("Give path: where to write the video.") }
        guard model.exportProgress == nil else { return .fail("An export is already running.") }
        var settings = ExportSettings()
        if let c = (args["codec"] as? String).flatMap(ExportSettings.Codec.init(rawValue:)) { settings.codec = c }
        switch args["resolution"] as? String {
        case "720": settings.resolution = .p720
        case "1080": settings.resolution = .p1080
        case "2160": settings.resolution = .p2160
        default: settings.resolution = .project
        }
        if let f = args["fps"] as? String, f != "project" { settings.frameRate = ExportSettings.FrameRate(rawValue: "fps" + f) ?? .project }
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if url.pathExtension.isEmpty { url.appendPathExtension(settings.fileExtension) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        model.export(to: url, settings: settings)
        await waitUntil(3600) { model.exportProgress == nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail("Export failed\(model.errorMessage.map { ": \($0)" } ?? ".")")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Reply(text: "Exported \(url.path) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))).")
    }

    // MARK: Helpers

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
