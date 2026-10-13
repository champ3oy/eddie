import AVFoundation
import Combine
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

struct LogEntry: Identifiable {
    enum Kind { case info, ai, error }
    let id = UUID()
    let kind: Kind
    let text: String
    var detail: String? = nil
}

/// What the AI said about the current grade.
struct ColoristNote {
    var text: String
    var recipe: GradeRecipe
}

@MainActor
final class EditorModel: ObservableObject {
    static let shared = EditorModel()

    // MARK: Project

    @Published private(set) var project = Project()
    /// Selected clip or music item.
    @Published var selection: UUID? { didSet { if selection != oldValue { selectionChanged() } } }
    /// The library project being edited, and whether the Projects screen is showing.
    @Published private(set) var currentProjectID: UUID?
    @Published var showingLibrary = true
    let library: ProjectLibrary
    private var autosaveTask: Task<Void, Never>?
    private var lastSaved: Project?
    private var loadingProject = false
    /// The size the viewer renders at (smaller than the project when proxies are in use).
    @Published private(set) var renderSize = CGSize(width: 1920, height: 1080)
    /// The project's real frame size (what export uses).
    @Published private(set) var projectSize = CGSize(width: 1920, height: 1080)
    /// Light 1080p copies of 4K videos for smooth playback, by original file.
    @Published private(set) var proxyMedia: [URL: VideoClip] = [:]
    @Published var useProxies = UserDefaults.standard.object(forKey: "useProxies") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useProxies, forKey: "useProxies")
            if useProxies { for (url, m) in media { makeProxyIfNeeded(url, m) } }
            rebuild()
        }
    }
    private var proxyJobs: Set<URL> = []
    @Published private(set) var frameRate: Float = 30
    private(set) var media: [URL: VideoClip] = [:]
    private(set) var musicMedia: [URL: MusicSource] = [:]
    private(set) var photoSizes: [URL: CGSize] = [:]
    var pool: MediaPool { MediaPool(videos: media, audio: musicMedia, photos: photoSizes) }

    let player = AVPlayer()
    let clock = PlaybackClock()
    /// Histogram of the frame currently on screen (after the grade).
    let scope = ScopeMonitor()

    // MARK: View

    @Published var mode = ViewMode.graded { didSet { pushState() } }
    @Published var compare = false { didSet { pushState() } }
    @Published var split = 0.5 { didSet { if compare { pushState() } } }
    @Published private(set) var lut: CubeLUT { didSet { pushState(); invalidateThumbnails() } }
    /// Timeline zoom in points per second; nil means "fit the edit the next time there is one".
    /// Kept here (not in the view) so trimming or rebuilding the timeline view never rescales it.
    @Published var timelineScale: CGFloat?
    /// Set once you zoom the timeline yourself; until then a growing edit is refitted.
    var timelineZoomedByUser = false

    /// Switches one lane's sound off or on (the speaker buttons beside the timeline). Saved with the project.
    func toggleLaneMute(_ lane: String) {
        mutate(.push) { p in
            if p.mutedLanes.contains(lane) { p.mutedLanes.remove(lane) } else { p.mutedLanes.insert(lane) }
        }
    }

    // MARK: Undo

    @Published private(set) var undoStack: [Project] = []
    @Published private(set) var redoStack: [Project] = []
    private var lastCoalescedEdit = Date.distantPast
    private var interacting = false
    private var structureAtInteractionStart = ""

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Timeline caches

    @Published private(set) var clipThumbs: [UUID: [CGImage]] = [:]
    @Published private(set) var waveforms: [URL: [Float]] = [:]
    private var thumbKeys: [UUID: String] = [:]
    private var thumbTask: Task<Void, Never>?

    // MARK: Presets

    @Published private(set) var presetThumbs: [String: CGImage] = [:]
    /// The preset currently applied to the selected clip, and the grade it was applied on.
    @Published private(set) var activePreset: String?
    private var presetBase: GradeRecipe?
    private var applyingPreset = false
    private var previewSource: CIImage?
    private var previewTask: Task<Void, Never>?
    private var previewTimeWatch: AnyCancellable?

    // MARK: AI + activity

    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var note: ColoristNote?
    @Published private(set) var errorMessage: String?
    /// The clip the AI is grading right now (drawn with moving stripes).
    @Published private(set) var gradingClipID: UUID?
    /// The editing assistant's latest answer, shown above the composer.
    @Published var assistantReply: String?
    @Published private(set) var exportProgress: Double?
    @Published var alert: String?

    private let state: GradeState
    private var videoComposition: AVVideoComposition?
    private var frameCache: [String: [CIImage]] = [:]
    private var aiTask: Task<Void, Never>?

    static let frameCount = 6
    /// Which AI to use; tests swap in a scripted model.
    var makeVisionModel: () -> VisionModel = { AISettings.makeModel() }

    init(library: ProjectLibrary = .shared) {
        self.library = library
        let lut = Self.loadSavedLUT() ?? .djiAction4
        self.lut = lut
        state = GradeState(.init(recipe: .neutral, lut: lut, mode: .graded))
        player.actionAtItemEnd = .pause
        clock.attach(to: player)
        // When the playhead settles somewhere new, re-take the preset preview frame.
        previewTimeWatch = clock.$time
            .removeDuplicates { abs($0 - $1) < 0.05 }
            .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.clock.playing else { return }
                self.loadPreviewFrame()
            }
    }

    // MARK: - Selection helpers

    /// The selected clip on the main track or the overlay track.
    var selectedClip: ClipItem? { selection.flatMap { project.clip($0) } }
    var selectedOverlay: OverlayItem? { project.overlays.first { $0.id == selection } }
    var selectedMusic: MusicItem? { project.music.first { $0.id == selection } }
    var selectedTitle: TitleItem? { project.titles.first { $0.id == selection } }
    /// Edges stick to the playhead and to clip, title and song edges while dragging.
    @Published var snapping = true
    /// Source media of the selected clip (or the first clip).
    var clip: VideoClip? { (selectedClip ?? project.clips.first).flatMap { media[$0.url] } }
    var hasProject: Bool { !project.isEmpty }
    var fileName: String {
        if let id = currentProjectID, let info = library.info(id) { return info.name }
        return project.clips.first?.name ?? ""
    }

    /// Grade of the selected clip. Setting it (e.g. from a slider) is one coalesced undo step.
    var recipe: GradeRecipe {
        get { selectedClip?.recipe ?? .neutral }
        set {
            guard let id = selectedClip?.id else { return }
            forgetPresetIfEdited()
            mutate(.coalesce) { $0.updateClip(id) { $0.recipe = newValue } }
        }
    }

    var intensity: Double {
        get { selectedClip?.intensity ?? 1 }
        set {
            guard let id = selectedClip?.id else { return }
            forgetPresetIfEdited()
            mutate(.coalesce) { $0.updateClip(id) { $0.intensity = newValue } }
        }
    }

    var effectiveRecipe: GradeRecipe { selectedClip?.effectiveRecipe ?? .neutral }
    var providerKind: ProviderKind { AISettings.provider }
    var providerName: String { AISettings.displayName() }

    func setProvider(_ kind: ProviderKind) {
        AISettings.provider = kind
        objectWillChange.send()
    }

    private func selectionChanged() {
        activePreset = nil
        presetBase = nil
        note = nil
        // Selecting a title off-screen jumps to it, so it can be positioned on the video.
        if let t = selectedTitle, clock.time < t.start || clock.time >= t.end {
            seek(to: t.start + min(0.5, t.duration / 2))
        }
        // Same for overlays, so their handles show on the video.
        if let o = selectedOverlay, clock.time < o.start || clock.time >= o.end {
            seek(to: o.start + min(0.5, o.clip.duration / 2))
        }
        loadPreviewFrame()
    }

    // MARK: - Mutation, undo

    enum UndoMode { case push, coalesce, none }

    /// Every project change goes through here: records undo, then updates the player.
    func mutate(_ undo: UndoMode = .push, _ change: (inout Project) -> Void) {
        // Live drag updates use `.none`; any other edit means no drag is really in progress
        // (macOS can cancel a drag without reporting its end), so settle it first.
        if undo != .none, interacting { endInteraction() }
        var next = project
        change(&next)
        guard next != project else { return }
        switch undo {
        case .push:
            pushUndo()
        case .coalesce:
            if Date().timeIntervalSince(lastCoalescedEdit) > 1 { pushUndo() }
            lastCoalescedEdit = Date()
        case .none:
            break
        }
        setProject(next)
    }

    private func pushUndo() {
        undoStack.append(project)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        activePreset = nil
        presetBase = nil
        setProject(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        setProject(next)
    }

    /// Drags (trim, moving music) record one undo step and rebuild the player once, when they end.
    func beginInteraction() {
        if interacting { endInteraction() }   // a previous drag never reported its end
        interacting = true
        structureAtInteractionStart = Self.structure(project)
        pushUndo()
    }

    func endInteraction() {
        guard interacting else { return }
        interacting = false
        // Moving or rotating a title doesn't change the composition; only rebuild when it did.
        if Self.structure(project) != structureAtInteractionStart { rebuild() }
        scheduleThumbnails()
        renderPresetThumbs()
        scheduleAutosave()
    }

    private func setProject(_ next: Project) {
        let old = project
        project = next
        // Keep the selection unless the selected thing is gone (any kind: clip, overlay, song, title, marker).
        if let s = selection, !Self.contains(next, s) {
            selection = next.clips.first?.id
        }
        extraSelection = extraSelection.filter { Self.contains(next, $0) }
        if selection == nil { selection = next.clips.first?.id }
        if Self.structure(old) != Self.structure(next) {
            if !interacting { rebuild() } else { clock.duration = next.duration }
        } else {
            pushState()
        }
        // During a drag only the picture updates; previews, thumbnails and saving catch up when it ends.
        guard !interacting else { return }
        scheduleThumbnails()
        renderPresetThumbs()
        scheduleAutosave()
    }

    static func contains(_ p: Project, _ id: UUID) -> Bool {
        p.clips.contains { $0.id == id } || p.overlays.contains { $0.id == id } || p.music.contains { $0.id == id }
            || p.titles.contains { $0.id == id } || p.markers.contains { $0.id == id }
    }

    /// Everything that needs a new composition (not grades).
    /// Grade, framing, keyframes, source type and overlay opacity are drawn live and don't count.
    private static func structure(_ p: Project) -> String {
        func clipKey(_ c: ClipItem) -> String {
            "\(c.id)|\(c.url.path)|\(c.sourceStart)|\(c.sourceEnd)|\(c.speed)|\(c.audioMuted)|\(c.volume)|\(c.isPhoto)|"
                + "\(String(describing: c.transitionIn))|\(c.audioFadeIn)|\(c.audioFadeOut)|\(String(describing: c.audioOverride))|\(c.reversed)|\(String(describing: c.reversedURL))"
        }
        return "\(p.duckUnderMusic)|\(p.fadeOut)|\(p.format.aspect)|\(p.mutedLanes.sorted())#" + p.clips.map(clipKey).joined(separator: ";")
            + "#" + p.overlays.map { "\(clipKey($0.clip))@\($0.start)" }.joined(separator: ";")
            + "#" + p.music.map { "\($0.id)|\($0.playURL.path)|\($0.start)|\($0.sourceStart)|\($0.sourceEnd)|\($0.volume)|\($0.fadeIn)|\($0.fadeOut)|\($0.kind)" }.joined(separator: ";")
    }

    // MARK: - Opening, adding

    /// Starts a new project with this video (Finder "Open With", tests).
    func open(_ url: URL) {
        createProject()
        addClips([url])
    }

    /// Makes a new library project and opens it.
    func createProject() {
        saveNow()
        do {
            let info = try library.create()
            resetEditor()
            currentProjectID = info.id
            lastSaved = Project()
            showingLibrary = false
        } catch {
            alert = "Couldn't create a project: \(error.localizedDescription)"
        }
    }

    /// Kept for the New Project menu item.
    func newProject() { createProject() }

    private func resetEditor() {
        cancelAI()
        player.pause()
        project = Project()
        timelineScale = nil
        timelineZoomedByUser = false
        selection = nil
        undoStack = []
        redoStack = []
        clipThumbs = [:]
        thumbKeys = [:]
        frameCache = [:]
        presetThumbs = [:]
        errorMessage = nil
        note = nil
        player.replaceCurrentItem(with: nil)
        clock.duration = 0
        clock.time = 0
    }

    /// Adds videos (and songs, if any audio files are among them) at the end of the timeline.
    func addClips(_ urls: [URL]) {
        if currentProjectID == nil { createProject() }
        showingLibrary = false
        Task {
            var added: [ClipItem] = []
            var songs: [URL] = []
            for url in urls {
                if Self.isAudioFile(url) { songs.append(url); continue }
                do {
                    added.append(try await makeClip(url))
                } catch {
                    alert = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            if !added.isEmpty {
                let wasEmpty = project.isEmpty
                mutate(.push) { $0.clips.append(contentsOf: added) }
                selection = added.first?.id
                if wasEmpty { seek(to: 0) }
                append(.info, "Added \(added.count) clip\(added.count == 1 ? "" : "s").")
            }
            for song in songs { addMusic(song) }
        }
    }

    func addMusic(_ url: URL, at time: Double? = nil, kind: MusicItem.Kind = .music) {
        Task {
            do {
                let src = try await loadMusic(url)
                let start = time ?? (clock.time < project.duration - 0.5 ? clock.time : 0)
                let length = kind == .music ? min(src.duration, max(1, project.duration - start)) : src.duration
                var item = MusicItem(url: url, start: start, sourceEnd: length)
                item.kind = kind
                if kind != .music { item.fadeIn = 0; item.fadeOut = 0; item.volume = 1 }
                // First lane where it doesn't overlap anything.
                var lane = 0
                while project.music.contains(where: { $0.lane == lane && $0.start < start + length && $0.end > start }) { lane += 1 }
                item.lane = lane
                // Skip a quiet intro so the song is actually heard (adjustable with "Starts at").
                if waveforms[url] == nil {
                    waveforms[url] = (try? await Waveform.peaks(of: src.asset, buckets: max(100, min(6000, Int(src.duration * 40))))) ?? []
                }
                if kind == .music, let loud = loudStart(of: item), loud < src.duration - 1 {
                    item.sourceStart = loud
                    item.sourceEnd = min(src.duration, loud + length)
                    append(.info, "\(url.lastPathComponent) starts quietly — skipped to \(Int(loud)) s.")
                }
                mutate(.push) { $0.music.append(item) }
                selection = item.id
                append(.info, "Added music: \(url.lastPathComponent)")
            } catch {
                alert = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// A full-length clip for a video, or a 4-second clip for a photo.
    func makeClip(_ url: URL) async throws -> ClipItem {
        if Self.isImageFile(url) {
            try loadPhoto(url)
            var c = ClipItem(url: url, sourceStart: 0, sourceEnd: 4)
            c.isPhoto = true
            c.profile = .normal
            return c
        }
        let info = try await loadMedia(url)
        var c = ClipItem(url: url, sourceStart: 0, sourceEnd: info.duration.seconds)
        c.profile = info.isLikelyLog ? .dlogM : .normal
        return c
    }

    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    private func loadPhoto(_ url: URL) throws {
        guard photoSizes[url] == nil else { return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Couldn't read this image."]) }
        let rotated = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        photoSizes[url] = rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    // MARK: Overlays, transitions, framing, format

    /// Puts a video or photo on the overlay track at the playhead (full frame, its sound off).
    func addOverlay(_ url: URL, pictureInPicture: Bool = false) {
        guard hasProject else { return }
        Task {
            do {
                var c = try await makeClip(url)
                c.audioMuted = true
                if c.isPhoto { c.sourceEnd = 3 }
                if pictureInPicture { c.transform = Self.pipTransform }
                let start = min(clock.time, max(0, project.duration - 0.5))
                let item = OverlayItem(clip: c, start: start)
                mutate(.push) { $0.overlays.append(item) }
                selection = item.id
            } catch {
                alert = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    static let pipTransform = EditorModelPiP.transform

    func updateOverlay(_ id: UUID, undo: UndoMode = .coalesce, _ change: (inout OverlayItem) -> Void) {
        mutate(undo) { $0.updateOverlay(id, change) }
    }

    /// Changes the selected (or given) clip, main track or overlay.
    func updateClip(_ id: UUID? = nil, undo: UndoMode = .coalesce, _ change: (inout ClipItem) -> Void) {
        guard let id = id ?? selection else { return }
        mutate(undo) { $0.updateClip(id, change) }
    }

    func setTransition(_ transition: Transition?, for id: UUID? = nil) {
        updateClip(id, undo: .push) { $0.transitionIn = transition }
    }

    /// Adds (or replaces) a framing keyframe at the playhead for the selected clip.
    func addKeyframe() {
        guard let clip = selectedClip else { return }
        let start = project.start(of: clip.id) ?? selectedOverlay?.start ?? 0
        let local = min(max(0, clock.time - start), clip.duration)
        let current = clip.transform(at: local)
        updateClip(clip.id, undo: .push) { c in
            if c.keyframes.isEmpty, local > 0.05 { c.keyframes.append(Keyframe(time: 0, transform: c.transform)) }
            c.keyframes.removeAll { abs($0.time - local) < 0.05 }
            c.keyframes.append(Keyframe(time: local, transform: current))
            c.keyframes.sort { $0.time < $1.time }
        }
    }

    /// A slow zoom in across the whole clip.
    func kenBurns(_ id: UUID? = nil) {
        guard let id = id ?? selection, let clip = project.clip(id) else { return }
        updateClip(id, undo: .push) { c in
            c.keyframes = [Keyframe(time: 0, transform: Transform2D(scale: 1.0)),
                           Keyframe(time: clip.duration, transform: Transform2D(scale: 1.18, x: 0.03, y: -0.02))]
        }
    }

    func clearKeyframes(_ id: UUID? = nil) {
        updateClip(id, undo: .push) { c in
            if let first = c.keyframes.first { c.transform = first.transform }
            c.keyframes = []
        }
    }

    /// The picture size of a clip's source (photo pixels, or the video's display size), before crop.
    func sourceSize(of clip: ClipItem) -> CGSize? {
        clip.isPhoto ? photoSizes[clip.url] : media[clip.url]?.displaySize
    }

    /// Edits the framing at the playhead: the keyframe there if animated, otherwise the clip's framing.
    func setFraming(undo: UndoMode = .coalesce, _ change: (inout Transform2D) -> Void) {
        guard let clip = selectedClip else { return }
        let start = project.start(of: clip.id) ?? selectedOverlay?.start ?? 0
        let local = min(max(0, clock.time - start), clip.duration)
        var t = clip.transform(at: local)
        change(&t)
        let new = t
        updateClip(clip.id, undo: undo) { c in
            if c.keyframes.isEmpty {
                c.transform = new
            } else if let i = c.keyframes.firstIndex(where: { abs($0.time - local) < 0.05 }) {
                c.keyframes[i].transform = new
            } else {
                c.keyframes.append(Keyframe(time: local, transform: new))
                c.keyframes.sort { $0.time < $1.time }
            }
        }
    }

    func setFormat(_ change: (inout ProjectFormat) -> Void) {
        mutate(.push) { change(&$0.format) }
    }

    func setFadeOut(_ seconds: Double) {
        mutate(.coalesce) { $0.fadeOut = max(0, seconds) }
    }

    static func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) && !type.conforms(to: .movie)
    }

    private func loadMedia(_ url: URL) async throws -> VideoClip {
        if let m = media[url] { return m }
        let m = try await VideoClip.load(url)
        media[url] = m
        makeProxyIfNeeded(url, m)
        if m.audioTrack != nil { loadWaveform(url, asset: m.asset) }
        return m
    }

    private func loadMusic(_ url: URL) async throws -> MusicSource {
        if let m = musicMedia[url] { return m }
        let m = try await MusicSource.load(url)
        musicMedia[url] = m
        loadWaveform(url, asset: m.asset)
        return m
    }

    private func loadWaveform(_ url: URL, asset: AVAsset) {
        guard waveforms[url] == nil else { return }
        Task.detached(priority: .utility) {
            let duration = (try? await asset.load(.duration).seconds) ?? 1
            let buckets = max(100, min(6000, Int(duration * 40)))
            if let cached = MediaCache.waveform(for: url, buckets: buckets) {
                await MainActor.run { self.waveforms[url] = cached }
                return
            }
            let peaks = (try? await Waveform.peaks(of: asset, buckets: buckets)) ?? []
            if !peaks.isEmpty { MediaCache.storeWaveform(peaks, for: url, buckets: buckets) }
            await MainActor.run { self.waveforms[url] = peaks }
        }
    }

    /// Makes (or finds) a 1080p proxy for 4K footage in the background, then switches playback to it.
    private func makeProxyIfNeeded(_ url: URL, _ m: VideoClip) {
        guard useProxies, max(m.displaySize.width, m.displaySize.height) > 2100,
              proxyMedia[url] == nil, !proxyJobs.contains(url), !url.path.hasPrefix(AudioProcessor.mediaFolder.path) else { return }
        proxyJobs.insert(url)
        Task {
            defer { proxyJobs.remove(url) }
            let existing = MediaCache.existingProxy(for: url)
            if existing == nil { append(.info, "Making a playback copy of \(url.lastPathComponent)…") }
            var proxyURL = existing
            if proxyURL == nil { proxyURL = try? await MediaCache.makeProxy(for: url) }
            guard let proxyURL, let proxy = try? await VideoClip.load(proxyURL) else { return }
            // Only use it if it lines up with the original.
            guard abs(proxy.duration.seconds - m.duration.seconds) < 0.1 else { return }
            proxyMedia[url] = proxy
            if useProxies && !interacting { rebuild() }
        }
    }

    /// Deletes the thumbnail, waveform and proxy caches (they're remade as needed).
    func clearCaches() {
        proxyMedia = [:]
        MediaCache.clear()
        rebuild()
    }

    // MARK: - Editing

    func splitAtPlayhead() {
        var newID: UUID?
        mutate(.push) { newID = $0.split(at: clock.time) }
        if let newID { selection = newID }
    }

    func deleteSelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        mutate(.push) { p in for id in ids { p.remove(id) } }
        selection = nil
        extraSelection = []
    }

    // MARK: Multi-select, clipboard, insert/overwrite

    /// Items selected besides `selection` (⌘-click adds to the selection).
    @Published var extraSelection: Set<UUID> = []
    var selectedIDs: Set<UUID> { extraSelection.union(selection.map { [$0] } ?? []) }

    /// Click: select only this. ⌘-click: add or remove it from the selection.
    func select(_ id: UUID, adding: Bool) {
        if adding {
            if selectedIDs.contains(id) {
                extraSelection.remove(id)
                if selection == id { selection = extraSelection.popFirst() }
            } else {
                if let s = selection { extraSelection.insert(s) }
                selection = id
            }
        } else {
            extraSelection = []
            selection = id
        }
    }

    func selectAll() {
        let all = project.clips.map(\.id) + project.overlays.map(\.id) + project.titles.map(\.id) + project.music.map(\.id)
        selection = all.first
        extraSelection = Set(all.dropFirst())
    }

    /// Copied items; times are relative to the earliest copied item.
    struct Clipboard {
        var clips: [ClipItem] = []
        var overlays: [OverlayItem] = []
        var titles: [TitleItem] = []
        var music: [MusicItem] = []
    }
    @Published private(set) var clipboard: Clipboard?

    enum EditMode: String { case insert, overwrite }
    @Published var editMode = EditMode.insert

    func copySelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        var c = Clipboard()
        c.clips = project.clips.filter { ids.contains($0.id) }
        let others = project.overlays.filter { ids.contains($0.id) }.map(\.start)
            + project.titles.filter { ids.contains($0.id) }.map(\.start) + project.music.filter { ids.contains($0.id) }.map(\.start)
        let origin = others.min() ?? 0
        c.overlays = project.overlays.filter { ids.contains($0.id) }.map { var o = $0; o.start -= origin; return o }
        c.titles = project.titles.filter { ids.contains($0.id) }.map { var t = $0; t.start -= origin; return t }
        c.music = project.music.filter { ids.contains($0.id) }.map { var m = $0; m.start -= origin; return m }
        clipboard = c
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Pastes at the playhead: clips by insert or overwrite (see `editMode`), everything else on its own lane.
    func paste() {
        guard let c = clipboard, hasProject || !c.clips.isEmpty else { return }
        let t = clock.time
        var newIDs: [UUID] = []
        mutate(.push) { p in
            let clips = c.clips.map { var x = $0; x.id = UUID(); x.keyframes = x.keyframes.map { var k = $0; k.id = UUID(); return k }; return x }
            if !clips.isEmpty {
                if editMode == .overwrite { p.overwrite(clips, atTime: t) } else { p.insert(clips, atTime: t) }
                newIDs += clips.map(\.id)
            }
            for o in c.overlays {
                var x = o
                x.clip.id = UUID()
                x.start = t + o.start
                p.overlays.append(x)
                newIDs.append(x.id)
            }
            for ti in c.titles {
                var x = ti
                x.id = UUID()
                x.start = t + ti.start
                p.titles.append(x)
                newIDs.append(x.id)
            }
            for m in c.music {
                var x = m
                x.id = UUID()
                x.start = t + m.start
                p.music.append(x)
                newIDs.append(x.id)
            }
        }
        selection = newIDs.first
        extraSelection = Set(newIDs.dropFirst())
    }

    /// Adds files to the timeline at a time (drag from the media bin or Finder), by insert or overwrite.
    func place(_ urls: [URL], atTime t: Double, lane: DropLane) {
        Task {
            var clips: [ClipItem] = []
            for url in urls {
                if Self.isAudioFile(url) {
                    addMusic(url, at: t)
                    continue
                }
                do { clips.append(try await makeClip(url)) } catch { alert = "\(url.lastPathComponent): \(error.localizedDescription)" }
            }
            guard !clips.isEmpty else { return }
            if currentProjectID == nil { createProject() }
            switch lane {
            case .overlay:
                var start = t
                mutate(.push) { p in
                    for var c in clips {
                        c.audioMuted = true
                        if c.isPhoto { c.sourceEnd = 3 }
                        p.overlays.append(OverlayItem(clip: c, start: start))
                        start += c.duration
                    }
                }
                selection = clips.first?.id
            default:
                mutate(.push) { p in
                    if editMode == .overwrite { p.overwrite(clips, atTime: t) } else { p.insert(clips, atTime: t) }
                }
                selection = clips.first?.id
            }
        }
    }

    enum DropLane { case overlay, main, audio }

    // MARK: Markers

    func addMarker() {
        guard hasProject else { return }
        let t = clock.time
        if project.markers.contains(where: { abs($0.time - t) < 0.05 }) { return }
        let m = Marker(time: t, name: "Marker \(project.markers.count + 1)")
        mutate(.push) { $0.markers.append(m); $0.markers.sort { $0.time < $1.time } }
    }

    func updateMarker(_ id: UUID, _ change: (inout Marker) -> Void) {
        mutate(.push) { p in if let i = p.markers.firstIndex(where: { $0.id == id }) { change(&p.markers[i]) } }
    }

    func removeMarker(_ id: UUID) { mutate(.push) { $0.markers.removeAll { $0.id == id } } }

    /// Jumps the playhead to the next (or previous) marker or cut.
    func jump(forward: Bool) {
        let points = Set(project.markers.map(\.time) + project.starts + [project.duration]).sorted()
        let t = clock.time
        if let p = forward ? points.first(where: { $0 > t + 0.02 }) : points.last(where: { $0 < t - 0.02 }) { seek(to: p) }
    }

    // MARK: J / K / L, blade

    /// J plays backwards (press again for faster), K stops, L plays forwards (faster each press).
    func shuttle(_ key: Character) {
        guard hasProject else { return }
        if interacting { endInteraction() }
        let rate = player.rate
        switch key {
        case "k": player.pause()
        case "l": player.rate = rate <= 0 ? 1 : min(8, rate * 2)
        case "j":
            let canReverse = player.currentItem?.canPlayReverse ?? false
            if canReverse { player.rate = rate >= 0 ? -1 : max(-8, rate * 2) } else { step(frames: -Int(frameRate.rounded())) }
        default: break
        }
    }

    /// Blade tool: clicking a clip cuts it where you click.
    @Published var bladeMode = false

    func blade(at time: Double) {
        mutate(.push) { $0.split(at: time) }
    }

    /// Cuts an overlay in two at a timeline time.
    func bladeOverlay(_ id: UUID, at time: Double) {
        guard let o = project.overlays.first(where: { $0.id == id }), time > o.start + 0.1, time < o.end - 0.1 else { return }
        mutate(.push) { p in
            guard let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
            let cut = o.clip.sourceStart + (time - o.start) * o.clip.speed
            var right = o
            right.clip.id = UUID()
            right.clip.sourceStart = cut
            right.clip.transitionIn = nil
            right.start = time
            p.overlays[i].clip.sourceEnd = cut
            p.overlays.insert(right, at: i + 1)
        }
    }

    // MARK: Freeze frame, reverse

    /// Holds the frame under the playhead for two seconds (inserted at the playhead).
    func freezeFrame(at time: Double? = nil) {
        let at = time ?? clock.time
        guard let (i, sourceTime) = project.locate(at) else { return }
        let clip = project.clips[i]
        guard !clip.isPhoto, let info = media[clip.url] else { return }
        Task {
            do {
                let gen = AVAssetImageGenerator(asset: info.asset)
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter = .zero
                let (image, _) = try await gen.image(at: CMTime(seconds: sourceTime, preferredTimescale: 600))
                let url = AudioProcessor.mediaFolder.appendingPathComponent("\(UUID().uuidString)-freeze.png")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                try loadPhoto(url)
                var still = ClipItem(url: url, sourceStart: 0, sourceEnd: 2)
                still.isPhoto = true
                still.profile = clip.profile
                still.recipe = clip.recipe
                still.intensity = clip.intensity
                still.transform = clip.transform(at: at - (project.start(of: clip.id) ?? 0))
                mutate(.push) { $0.insert([still], atTime: at) }
                selection = still.id
            } catch {
                alert = "Couldn't grab that frame: \(error.localizedDescription)"
            }
        }
    }

    /// Plays a clip backwards (Eddie makes a reversed copy the first time).
    func toggleReverse(_ id: UUID? = nil) {
        guard let id = id ?? selection, let clip = project.clip(id), !clip.isPhoto else { return }
        if clip.reversed {
            updateClip(id, undo: .push) { $0.reversed = false; $0.audioOverride = nil }
            return
        }
        if let r = clip.reversedURL, FileManager.default.fileExists(atPath: r.path) {
            Task {
                _ = try? await loadMedia(r)
                let audio = r.deletingPathExtension().appendingPathExtension("m4a")
                if FileManager.default.fileExists(atPath: audio.path) { _ = try? await loadMusic(audio) }
                updateClip(id, undo: .push) {
                    $0.reversed = true
                    $0.audioOverride = FileManager.default.fileExists(atPath: audio.path) ? audio : nil
                }
            }
            return
        }
        runAudioJob(id, "Reversing \(clip.name)") { [self] in
            let result = try await Reverser.reverse(clip.url)
            // Keep the sound next to the video with the same name, so it can be found again.
            var audio: URL?
            if let a = result.audio {
                let named = result.video.deletingPathExtension().appendingPathExtension("m4a")
                try? FileManager.default.moveItem(at: a, to: named)
                audio = named
                _ = try await loadMusic(named)
            }
            _ = try await loadMedia(result.video)
            updateClip(id, undo: .push) { $0.reversed = true; $0.reversedURL = result.video; $0.audioOverride = audio }
        }
    }

    func duplicateSelection() {
        guard let id = selectedClip?.id else { return }
        var newID: UUID?
        mutate(.push) { newID = $0.duplicate(id) }
        if let newID { selection = newID }
    }

    func moveClip(_ id: UUID, to index: Int) {
        mutate(.push) { $0.move(id, to: index) }
    }

    func setSpeed(_ speed: Double, for id: UUID? = nil) {
        guard let id = id ?? selectedClip?.id else { return }
        mutate(.push) { $0.setSpeed(id, speed) }
    }

    func setClipVolume(_ volume: Double, for id: UUID? = nil) {
        guard let id = id ?? selectedClip?.id else { return }
        mutate(.coalesce) { $0.updateClip(id) { $0.volume = min(max(volume, 0), 1); $0.audioMuted = false } }
    }

    func setDuckUnderMusic(_ on: Bool) {
        mutate(.push) { $0.duckUnderMusic = on }
    }

    func toggleClipAudio(_ id: UUID? = nil) {
        guard let id = id ?? selectedClip?.id else { return }
        mutate(.push) { $0.updateClip(id) { $0.audioMuted.toggle() } }
    }

    /// Live trim during a drag (call `beginInteraction` first, `endInteraction` after).
    func trimClip(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let c = project.clip(id) else { return }
        let full = c.isPhoto ? 3600 : (media[c.url]?.duration.seconds ?? c.sourceEnd)
        mutate(.none) { $0.trim(id, start: start, end: end, sourceDuration: full) }
    }

    /// Adds a 3-second title at the playhead and selects it.
    func addTitle(style: TitleItem.Style = .title) {
        guard hasProject else { return }
        let start = min(clock.time, max(0, project.duration - 1))
        let item = TitleItem(text: style == .title ? "Title" : (style == .lowerThird ? "Name\nPlace" : "Caption"),
                             start: start, duration: min(3, max(1, project.duration - start)), style: style)
        mutate(.push) { $0.titles.append(item) }
        selection = item.id
        // Titles fade in, so the frame at their very start is blank: step just inside so it shows.
        seek(to: start + min(0.4, item.duration / 2))
    }

    func updateTitle(_ id: UUID, undo: UndoMode = .coalesce, _ change: (inout TitleItem) -> Void) {
        mutate(undo) { $0.updateTitle(id, change) }
    }

    func updateMusic(_ id: UUID, undo: UndoMode = .coalesce, _ change: (inout MusicItem) -> Void) {
        mutate(undo) { $0.updateMusic(id, change) }
    }

    /// Changes where in the song playback begins, keeping its place and length on the timeline.
    func setSongOffset(_ id: UUID, to offset: Double, undo: UndoMode = .coalesce) {
        guard let item = project.music.first(where: { $0.id == id }) else { return }
        let full = musicSourceDuration(item)
        let length = item.duration
        let start = min(max(0, offset), max(0, full - 0.5))
        mutate(undo) { $0.updateMusic(id) { m in
            m.sourceStart = start
            m.sourceEnd = min(full, start + length)
        } }
    }

    /// Where the song first gets loud (a quarter of its peak level), if its intro is quiet.
    func loudStart(of item: MusicItem) -> Double? {
        guard let peaks = waveforms[item.playURL], !peaks.isEmpty else { return nil }
        let full = musicSourceDuration(item)
        guard let i = peaks.firstIndex(where: { $0 >= 0.25 }) else { return nil }
        let t = full * Double(i) / Double(peaks.count)
        return t >= 2 ? t : nil   // only worth it for an intro of 2 s or more
    }

    func musicSourceDuration(_ item: MusicItem) -> Double { musicMedia[item.playURL]?.duration ?? item.sourceEnd }
    func clipSourceDuration(_ clip: ClipItem) -> Double { media[clip.url]?.duration.seconds ?? clip.sourceEnd }

    // MARK: - Projects (saved automatically)

    /// Saves a second after the last change; edits are never lost to a forgotten save.
    private func scheduleAutosave() {
        guard currentProjectID != nil, !loadingProject else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Writes the project to the library now (if it changed).
    func saveNow() {
        autosaveTask?.cancel()
        guard let id = currentProjectID, !loadingProject else { return }
        let thumb = project.clips.first.flatMap { clipThumbs[$0.id]?.first }
        do {
            if project != lastSaved {
                try library.save(project, id: id, thumbnail: thumb)
                lastSaved = project
                thumbnailSaved = thumb != nil
            } else if let thumb, !thumbnailSaved {
                try library.updateThumbnail(thumb, id: id)   // a new thumbnail isn't an edit
                thumbnailSaved = true
            }
        } catch {
            alert = "Couldn't save the project: \(error.localizedDescription)"
        }
    }
    private var thumbnailSaved = false

    /// Opens a project from the library. Videos are loaded from where they were; missing ones are listed.
    /// A project whose files were moved: the user points Eddie at them before it opens.
    struct RelinkRequest: Identifiable {
        let id: UUID
        var project: Project
        var missing: [URL]
    }
    @Published var relink: RelinkRequest?

    func openProject(id: UUID) {
        saveNow()
        do {
            let p = try library.read(id)
            let missing = p.mediaURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
            if missing.isEmpty { load(p, id: id) } else { relink = RelinkRequest(id: id, project: p, missing: missing) }
        } catch {
            alert = "Couldn't open the project: \(error.localizedDescription)"
        }
    }

    /// Looks for every missing file by name inside `folder` (and its subfolders). Returns how many were found.
    @discardableResult
    func relinkSearch(in folder: URL) -> Int {
        guard var r = relink else { return 0 }
        let wanted = Dictionary(grouping: r.missing, by: { $0.lastPathComponent.lowercased() })
        var found = 0
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = e?.nextObject() as? URL {
            guard let olds = wanted[url.lastPathComponent.lowercased()] else { continue }
            for old in olds where r.missing.contains(old) {
                r.project.relink(old, to: url)
                r.missing.removeAll { $0 == old }
                found += 1
            }
            if r.missing.isEmpty { break }
        }
        relink = r
        return found
    }

    func relinkFile(_ old: URL, to new: URL) {
        guard var r = relink else { return }
        r.project.relink(old, to: new)
        r.missing.removeAll { $0 == old }
        relink = r
    }

    /// Opens the project being relinked: with everything found, or leaving out what's still missing.
    func finishRelink() {
        guard var r = relink else { return }
        relink = nil
        let gone = Set(r.missing)
        r.project.clips.removeAll { gone.contains($0.url) }
        r.project.overlays.removeAll { gone.contains($0.clip.url) }
        r.project.music.removeAll { gone.contains($0.url) }
        r.project.bin.removeAll { gone.contains($0) }
        try? library.save(r.project, id: r.id)
        load(r.project, id: r.id)
    }

    private func load(_ p: Project, id: UUID) {
        Task {
            do {
                loadingProject = true
                defer { loadingProject = false }
                resetEditor()
                currentProjectID = id
                for c in p.clips + p.overlays.map(\.clip) {
                    if c.isPhoto { try loadPhoto(c.url) } else { _ = try await loadMedia(c.url) }
                }
                for m in p.music { _ = try await loadMusic(m.playURL) }
                for c in p.clips + p.overlays.map(\.clip) {
                    if let o = c.audioOverride { _ = try? await loadMusic(o) }
                    if c.reversed, let r = c.reversedURL { _ = try? await loadMedia(r) }
                }
                setProject(p)
                lastSaved = p
                thumbnailSaved = false
                selection = p.clips.first?.id
                seek(to: 0)
                showingLibrary = false
            } catch {
                alert = "Couldn't open the project: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Audio clean-up and beats

    /// Audio jobs running, by item id (the timeline shows a spinner).
    @Published private(set) var audioJobs: Set<UUID> = []

    private func runAudioJob(_ id: UUID, _ label: String, _ job: @escaping () async throws -> Void) {
        guard !audioJobs.contains(id) else { return }
        audioJobs.insert(id)
        append(.info, "\(label)…")
        Task {
            do { try await job() } catch { alert = "\(label) failed: \(error.localizedDescription)" }
            audioJobs.remove(id)
        }
    }

    /// Makes a song, voiceover or effect a consistent loudness.
    func normalize(_ musicID: UUID) { processMusic(musicID, AudioProcessor.Options(normalize: true), "Normalizing") }

    func reduceNoise(musicID: UUID) {
        processMusic(musicID, AudioProcessor.Options(normalize: true, reduceNoise: true), "Removing background noise")
    }

    private func processMusic(_ id: UUID, _ options: AudioProcessor.Options, _ label: String) {
        guard let item = project.music.first(where: { $0.id == id }) else { return }
        runAudioJob(id, label) { [self] in
            let out = try await AudioProcessor.process(item.url, options: options)
            _ = try await loadMusic(out)
            updateMusic(id, undo: .push) { $0.processed = out }
        }
    }

    /// Cleans up a video clip's own sound (main track or overlay).
    func processClipAudio(_ id: UUID, normalize: Bool = true, reduceNoise: Bool) {
        guard let clip = project.clip(id), !clip.isPhoto else { return }
        runAudioJob(id, reduceNoise ? "Removing background noise" : "Normalizing") { [self] in
            let out = try await AudioProcessor.process(clip.url, options: .init(normalize: normalize, reduceNoise: reduceNoise))
            _ = try await loadMusic(out)
            updateClip(id, undo: .push) { $0.audioOverride = out }
        }
    }

    /// Back to the original sound.
    func resetAudio(_ id: UUID) {
        if project.music.contains(where: { $0.id == id }) { updateMusic(id, undo: .push) { $0.processed = nil } }
        else { updateClip(id, undo: .push) { $0.audioOverride = nil } }
    }

    /// Finds a song's beats so clips, titles and the playhead snap to them.
    func detectBeats(_ musicID: UUID) {
        guard let item = project.music.first(where: { $0.id == musicID }) else { return }
        runAudioJob(musicID, "Finding the beat") { [self] in
            let beats = try await BeatDetector.beats(in: item.url)
            updateMusic(musicID, undo: .push) { $0.beats = beats }
            if let bpm = BeatDetector.tempo(of: beats) { append(.info, "\(item.name): \(Int(bpm.rounded())) BPM") }
        }
    }

    // MARK: Captions

    @Published private(set) var captioning = false

    /// Listens to the clips (on this Mac) and adds captions, replacing earlier auto captions.
    func autoCaptions() {
        guard hasProject, !captioning else { return }
        captioning = true
        append(.info, "Listening for speech…")
        let project = self.project
        Task {
            defer { captioning = false }
            do {
                let lines = try await Captioner.captions(for: project)
                mutate(.push) { p in
                    p.titles.removeAll { $0.isCaption }
                    p.titles.append(contentsOf: lines)
                }
                append(.info, "Added \(lines.count) caption\(lines.count == 1 ? "" : "s").")
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func removeCaptions() {
        mutate(.push) { $0.titles.removeAll { $0.isCaption } }
    }

    // MARK: Voiceover

    let recorder = VoiceRecorder()
    /// Timeline time where the current recording started.
    @Published private(set) var recordStart = 0.0
    private var recordEndObserver: NSObjectProtocol?

    /// Starts recording a voiceover at the playhead while the video plays; call again to stop and place it.
    func toggleVoiceover() {
        if recorder.isRecording {
            player.pause()
            if let o = recordEndObserver { NotificationCenter.default.removeObserver(o); recordEndObserver = nil }
            guard let url = recorder.stop() else { return }
            let start = recordStart
            Task {
                do {
                    let src = try await loadMusic(url)
                    var lane = 0
                    while project.music.contains(where: { $0.lane == lane && $0.start < start + src.duration && $0.end > start }) { lane += 1 }
                    var item = MusicItem(url: url, start: start, sourceEnd: src.duration)
                    item.kind = .voiceover
                    item.volume = 1
                    item.fadeIn = 0.05
                    item.fadeOut = 0.2
                    item.lane = lane
                    mutate(.push) { $0.music.append(item) }
                    selection = item.id
                    append(.info, "Recorded a \(Int(src.duration.rounded())) s voiceover.")
                } catch {
                    alert = "Couldn't add the recording: \(error.localizedDescription)"
                }
            }
            return
        }
        guard hasProject else { return }
        Task {
            guard await VoiceRecorder.requestAccess() else {
                alert = "Eddie needs the microphone to record. Allow it in System Settings → Privacy & Security → Microphone."
                return
            }
            do {
                if interacting { endInteraction() }
                recordStart = clock.time
                try recorder.start()
                objectWillChange.send()
                // Reaching the end of the video stops the recording.
                recordEndObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                           object: player.currentItem, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.recorder.isRecording == true { self?.toggleVoiceover() } }
                }
                player.play()
            } catch {
                alert = "Couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Media bin

    /// Brings files into the project's media bin without putting them on the timeline.
    func importToBin(_ urls: [URL]) {
        let new = urls.filter { !project.bin.contains($0) }
        guard !new.isEmpty else { return }
        mutate(.push) { $0.bin.append(contentsOf: new) }
    }

    func removeFromBin(_ url: URL) {
        mutate(.push) { $0.bin.removeAll { $0 == url } }
    }

    /// Everything in the bin plus anything used on the timeline.
    var binItems: [URL] { project.mediaURLs }

    /// How many times a file is used on the timeline.
    func uses(of url: URL) -> Int {
        project.clips.filter { $0.url == url }.count + project.overlays.filter { $0.clip.url == url }.count
            + project.music.filter { $0.url == url }.count
    }

    /// Back to the Projects screen (saves first).
    func showProjects() {
        player.pause()
        saveNow()
        library.reload()
        showingLibrary = true
    }

    func renameCurrentProject(_ name: String) {
        guard let id = currentProjectID else { return }
        try? library.rename(id, to: name)
        objectWillChange.send()
    }

    /// Brings a standalone .eddie file into the library and opens it.
    func importProjectFile(_ url: URL) {
        do {
            let info = try library.importFile(url)
            openProject(id: info.id)
        } catch {
            alert = "Couldn't import the project: \(error.localizedDescription)"
        }
    }

    func exportProjectFile(to url: URL) {
        saveNow()
        guard let id = currentProjectID else { return }
        do { try library.exportFile(id, to: url) } catch { alert = "Couldn't export the project file: \(error.localizedDescription)" }
    }

    // MARK: - Playback

    func togglePlay() {
        guard hasProject else { return }
        // While recording a voiceover, Space stops the recording.
        if recorder.isRecording { toggleVoiceover(); return }
        if interacting { endInteraction() }
        if player.rate == 0 {
            if clock.time >= clock.duration - 0.05 { seek(to: 0) }
            player.play()
        } else {
            player.pause()
        }
    }

    func step(frames n: Int) {
        guard hasProject else { return }
        player.pause()
        seek(to: clock.time + Double(n) / Double(frameRate))
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: min(max(0, seconds), clock.duration), preferredTimescale: 600)
        clock.time = t.seconds
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Recompiles the project into a new player item, keeping the playhead.
    private func rebuild() {
        guard !project.isEmpty else {
            player.replaceCurrentItem(with: nil)
            clock.duration = 0
            return
        }
        do {
            let time = clock.time
            let full = ProjectCompiler.frameSize(project, pool: pool)
            var preview = pool
            var size = full
            if useProxies && !proxyMedia.isEmpty {
                for (url, proxy) in proxyMedia { preview.videos[url] = proxy }
                let s = min(1, 1920 / max(full.width, full.height))
                size = CGSize(width: (full.width * s / 2).rounded() * 2, height: (full.height * s / 2).rounded() * 2)
            }
            let compiled = try ProjectCompiler.compile(project, pool: preview, state: state, renderSize: size)
            projectSize = full
            let item = AVPlayerItem(asset: compiled.composition)
            item.videoComposition = compiled.videoComposition
            item.audioMix = compiled.audioMix
            item.audioTimePitchAlgorithm = .spectral
            videoComposition = compiled.videoComposition
            renderSize = compiled.renderSize
            frameRate = compiled.frameRate
            pushState(refresh: false)
            scope.attach(to: item)
            player.replaceCurrentItem(with: item)
            clock.duration = project.duration
            seek(to: min(time, project.duration))
        } catch {
            alert = error.localizedDescription
        }
    }

    private func pushState(refresh: Bool = true) {
        state.snapshot = ProjectCompiler.snapshot(for: project, lut: lut, mode: mode, split: compare ? split : nil)
        if refresh { refreshPausedFrame() }
    }

    /// While playing, the next frame picks the new grade up. While paused, force a redraw.
    private func refreshPausedFrame() {
        guard let item = player.currentItem, let videoComposition, player.rate == 0 else { return }
        item.videoComposition = videoComposition.mutableCopy() as? AVVideoComposition
        player.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - AI

    /// Grades the selected clip.
    func autoGrade() {
        guard let id = selectedClip?.id ?? project.clips.first?.id else { return }
        runAI(on: [id]) { agent, frames, lut, _ in
            try await agent.autoGrade(frames: frames, lut: lut, events: { [weak self] e in self?.handle(e, clip: id) })
        }
    }

    /// Grades every clip, one after another.
    func autoGradeAll() {
        let ids = project.clips.map(\.id)
        runAI(on: ids) { agent, frames, lut, id in
            try await agent.autoGrade(frames: frames, lut: lut, events: { [weak self] e in self?.handle(e, clip: id) })
        }
    }

    func refine(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = selectedClip?.id else { return }
        runAI(on: [id]) { agent, frames, lut, id in
            let current = await MainActor.run { self.project.clips.first { $0.id == id }?.effectiveRecipe ?? .neutral }
            return try await agent.refine(frames: frames, lut: lut, current: current, instruction: text,
                                          events: { [weak self] e in self?.handle(e, clip: id) })
        }
    }

    /// Plain-language editing: the AI cuts, trims, arranges, adds titles, sets music and speed, and can hand
    /// color work to the colorist. The whole request is one undo step.
    func ask(_ request: String) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasProject, !busy else { return }
        busy = true
        errorMessage = nil
        assistantReply = nil
        status = "Looking at the timeline…"
        let agent = EditingAgent(model: makeVisionModel())
        let start = project, playhead = clock.time
        let durations = media.mapValues { $0.duration.seconds }.merging(musicMedia.mapValues(\.duration)) { a, _ in a }
        aiTask = Task {
            var colorWork: [ColorRequest] = []
            var jobs: [EditJob] = []
            do {
                let frames = await timelineFrames(count: 8)
                let step = try await agent.run(request: text, project: start, playhead: playhead, frames: frames,
                                               sourceDuration: { durations[$0] }, progress: { [weak self] in self?.status = $0 })
                try Task.checkCancellation()
                if step.project != project { mutate(.push) { $0 = step.project } }
                assistantReply = step.reply
                if let s = step.seek { seek(to: s) }
                colorWork = step.color
                jobs = step.jobs
                append(.ai, step.reply, detail: step.log.joined(separator: "; "))
            } catch is CancellationError {
                append(.info, "Stopped.")
            } catch let error as URLError where error.code == .cancelled {
                append(.info, "Stopped.")
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
            status = nil
            aiTask = nil
            // Color requests go through the colorist, which looks at the clip's frames.
            for work in colorWork { await runColor(work) }
            for job in jobs { run(job) }
        }
    }

    /// Slow work the editing AI asked for.
    private func run(_ job: EditJob) {
        switch job {
        case .reverse(let id): toggleReverse(id)
        case .freeze(let at): freezeFrame(at: at)
        case .normalize(let id):
            if project.music.contains(where: { $0.id == id }) { normalize(id) } else { processClipAudio(id, reduceNoise: false) }
        case .reduceNoise(let id):
            if project.music.contains(where: { $0.id == id }) { reduceNoise(musicID: id) } else { processClipAudio(id, reduceNoise: true) }
        case .captions: autoCaptions()
        case .beats(let id): detectBeats(id)
        }
    }

    private func runColor(_ work: ColorRequest) async {
        let ids = work.clipIDs.filter { id in project.clips.contains { $0.id == id } }
        guard !ids.isEmpty else { return }
        let instruction = work.instruction
        runAI(on: ids) { agent, frames, lut, id in
            if instruction.isEmpty {
                return try await agent.autoGrade(frames: frames, lut: lut, events: { [weak self] e in self?.handle(e, clip: id) })
            }
            let current = await MainActor.run { self.project.clips.first { $0.id == id }?.effectiveRecipe ?? .neutral }
            return try await agent.refine(frames: frames, lut: lut, current: current, instruction: instruction,
                                          events: { [weak self] e in self?.handle(e, clip: id) })
        }
        await aiTask?.value
    }

    /// Graded frames spread across the timeline (what the viewer shows), for the editing assistant to look at.
    private func timelineFrames(count: Int) async -> [(time: Double, jpeg: Data)] {
        guard let item = player.currentItem, project.duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let n = max(1, min(count, Int(project.duration / 1.5)))
        var out: [(Double, Data)] = []
        for i in 0..<n {
            let t = project.duration * (Double(i) + 0.5) / Double(n)
            guard let (cg, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
                  let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
            else { continue }
            out.append((t, jpeg))
        }
        return out
    }

    func cancelAI() {
        aiTask?.cancel()
    }

    private func runAI(on ids: [UUID],
                       _ work: @escaping (GradingAgent, [CIImage], CubeLUT, UUID) async throws -> GradeRecipe) {
        guard !ids.isEmpty, !busy else { return }
        busy = true
        errorMessage = nil
        let model = makeVisionModel()
        let lut = self.lut
        pushUndo()   // the whole run is one undo step
        aiTask = Task {
            defer {
                busy = false
                status = nil
                gradingClipID = nil
                aiTask = nil
            }
            for (n, id) in ids.enumerated() {
                guard let clip = project.clip(id) else { continue }
                var agent = GradingAgent(model: model)
                agent.applyLUT = clip.profile == .dlogM
                gradingClipID = id
                do {
                    if ids.count > 1 { status = "Clip \(n + 1) of \(ids.count)…" }
                    let frames = try await framesForAI(clip)
                    let result = try await work(agent, frames, lut, id)
                    try Task.checkCancellation()
                    mutate(.none) { $0.updateClip(id) { $0.recipe = result; $0.intensity = 1 } }
                    append(.info, "Graded \(clip.name): \(result.summary)")
                } catch is CancellationError {
                    append(.info, "Stopped.")
                    return
                } catch let error as URLError where error.code == .cancelled {
                    append(.info, "Stopped.")
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    append(.error, error.localizedDescription)
                    return
                }
            }
        }
    }

    private func framesForAI(_ clip: ClipItem) async throws -> [CIImage] {
        let key = "\(clip.url.path)|\(clip.sourceStart)|\(clip.sourceEnd)"
        if let cached = frameCache[key] { return cached }
        if clip.isPhoto, let still = StillCache.image(clip.url) {
            let s = min(1, 1280 / max(1, still.extent.width))
            return [GradeRenderer.shared.materialize(still.transformed(by: CGAffineTransform(scaleX: s, y: s)))]
        }
        guard let info = media[clip.url] else { return [] }
        status = "Grabbing \(Self.frameCount) frames…"
        let times = FrameSampler.evenTimes(count: Self.frameCount, duration: ProjectCompiler.time(clip.sourceLength))
            .map { $0 + ProjectCompiler.time(clip.sourceStart) }
        let frames = try await FrameSampler.frames(of: info, at: times).map(\.image)
        frameCache[key] = frames
        return frames
    }

    private func handle(_ event: GradingAgent.Event, clip id: UUID) {
        switch event {
        case let .status(s):
            if !(status?.hasPrefix("Clip ") ?? false) { status = s }
            append(.info, s)
        case let .analysis(_, text, r):
            note = ColoristNote(text: text, recipe: r)
            append(.ai, text, detail: r.summary)
            // Show each round's result live while the AI keeps checking.
            mutate(.none) { $0.updateClip(id) { $0.recipe = r; $0.intensity = 1 } }
        }
    }

    // MARK: - Grades

    /// Applies a preset on the pre-preset grade; clicking the active preset again removes it.
    func apply(_ preset: Preset) {
        guard selectedClip != nil, !busy else { return }
        let base = presetBase ?? effectiveRecipe
        applyingPreset = true
        defer { applyingPreset = false }
        // Record the base before changing the grade: the change re-renders the previews from it.
        if activePreset == preset.name {
            activePreset = nil
            presetBase = nil
            setRecipe(base, resetIntensity: true)
        } else {
            activePreset = preset.name
            presetBase = base
            setRecipe(base.adding(preset.adjust), resetIntensity: true)
        }
    }

    private func forgetPresetIfEdited() {
        guard !applyingPreset, activePreset != nil || presetBase != nil else { return }
        activePreset = nil
        presetBase = nil
    }

    func setRecipe(_ r: GradeRecipe, resetIntensity: Bool, recordHistory: Bool = true) {
        guard let id = selectedClip?.id else { return }
        mutate(recordHistory ? .push : .none) {
            $0.updateClip(id) { c in
                c.recipe = r
                if resetIntensity { c.intensity = 1 }
            }
        }
    }

    func reset() {
        setRecipe(.neutral, resetIntensity: true)
        note = nil
    }

    func useLUT(at url: URL?) {
        do {
            if let url {
                lut = try CubeLUT(contentsOf: url)
                UserDefaults.standard.set(url.path, forKey: "lut.path")
            } else {
                lut = .djiAction4
                UserDefaults.standard.removeObject(forKey: "lut.path")
            }
            append(.info, "Using LUT: \(lut.title)")
        } catch {
            alert = error.localizedDescription
        }
    }

    private static func loadSavedLUT() -> CubeLUT? {
        guard let path = UserDefaults.standard.string(forKey: "lut.path") else { return nil }
        return try? CubeLUT(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - Export

    @Published var showingExport = false

    /// The file being exported (for the progress bar).
    @Published private(set) var exportingName: String?
    private var exportTask: Task<Void, Never>?

    func export(to url: URL, settings: ExportSettings = .init()) {
        guard hasProject, exportProgress == nil else { return }
        exportProgress = 0
        exportingName = url.lastPathComponent
        let project = self.project, pool = self.pool, lut = self.lut
        append(.info, "Exporting to \(url.lastPathComponent)…")
        exportTask = Task {
            do {
                try await Exporter.export(project: project, pool: pool, lut: lut, settings: settings, to: url) { p in
                    Task { @MainActor [weak self] in if self?.exportProgress != nil { self?.exportProgress = p } }
                }
                try Task.checkCancellation()
                append(.info, "Export finished: \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                append(.info, "Export cancelled.")
            } catch {
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    append(.info, "Export cancelled.")
                } else {
                    errorMessage = "Export failed: \(error.localizedDescription)"
                    append(.error, "Export failed: \(error.localizedDescription)")
                }
            }
            exportProgress = nil
            exportingName = nil
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    // MARK: - Thumbnails, previews

    private func invalidateThumbnails() {
        thumbKeys = [:]
        scheduleThumbnails()
        renderPresetThumbs()
    }

    /// Regenerates filmstrip thumbnails for clips whose trim or grade changed, shortly after they stop changing.
    private func scheduleThumbnails() {
        let lutTitle = lut.title
        let pending = (project.clips + project.overlays.map(\.clip)).filter { c in
            thumbKeys[c.id] != "\(c.sourceStart)|\(c.sourceEnd)|\(c.effectiveRecipe.jsonString())|\(lutTitle)"
        }
        guard !pending.isEmpty else { return }
        thumbTask?.cancel()
        let lut = self.lut, media = self.media
        thumbTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            for c in pending {
                guard !Task.isCancelled else { return }
                var images: [CGImage] = []
                if c.isPhoto {
                    images = Filmstrip.photoThumbnail(c, lut: lut).map { [$0] } ?? []
                } else if let info = media[c.url] {
                    images = await Filmstrip.thumbnails(of: info, clip: c, lut: lut)
                }
                guard !Task.isCancelled else { return }
                if !images.isEmpty {
                    clipThumbs[c.id] = images
                    if c.id == project.clips.first?.id { thumbnailSaved = false; scheduleAutosave() }
                    thumbKeys[c.id] = "\(c.sourceStart)|\(c.sourceEnd)|\(c.effectiveRecipe.jsonString())|\(lutTitle)"
                }
            }
        }
    }

    /// Decodes the raw frame under the playhead (or the middle of the selected clip), then re-renders preset previews.
    private func loadPreviewFrame() {
        guard let clip = selectedClip else { return }
        if clip.isPhoto, let still = StillCache.image(clip.url) {
            let s = min(1, 240 / max(1, still.extent.width))
            previewSource = GradeRenderer.shared.materialize(still.transformed(by: CGAffineTransform(scaleX: s, y: s)))
            renderPresetThumbs()
            return
        }
        guard let info = media[clip.url] else { return }
        var sourceTime = (clip.sourceStart + clip.sourceEnd) / 2
        if let hit = project.locate(clock.time), project.clips[hit.index].id == clip.id { sourceTime = hit.sourceTime }
        Task {
            guard let frame = try? await FrameSampler.frames(of: info, at: [ProjectCompiler.time(sourceTime)], maxWidth: 240).first,
                  self.selectedClip?.id == clip.id else { return }
            previewSource = frame.image
            renderPresetThumbs()
        }
    }

    private func renderPresetThumbs() {
        guard let source = previewSource else { return }
        previewTask?.cancel()
        // Previews show each preset on the pre-preset grade, so they don't inherit the active one.
        let base = presetBase ?? effectiveRecipe, lut = self.lut, applyLUT = selectedClip?.profile != .normal
        previewTask = Task.detached(priority: .userInitiated) {
            var out: [String: CGImage] = [:]
            let renderer = GradeRenderer.shared
            for preset in Preset.all {
                if Task.isCancelled { return }
                let img = renderer.render(source, recipe: base.adding(preset.adjust), lut: lut, mode: .graded, applyLUT: applyLUT)
                let px = renderer.rgba8(img, maxWidth: 160)
                if let cg = Self.cgImage(px.pixels, px.width, px.height) { out[preset.name] = cg }
            }
            let result = out
            await MainActor.run { if !Task.isCancelled { self.presetThumbs = result } }
        }
    }

    nonisolated static func cgImage(_ pixels: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func append(_ kind: LogEntry.Kind, _ text: String, detail: String? = nil) {
        log.append(LogEntry(kind: kind, text: text, detail: detail))
    }
}

/// Playback position, published separately so only the timeline redraws while the video plays.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var playing = false
    private var observer: Any?
    private var rateObservation: AnyCancellable?

    func attach(to player: AVPlayer) {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds }
        }
        rateObservation = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.playing = status != .paused }
    }
}

/// Graded thumbnails across one clip's trimmed range.
enum Filmstrip {
    static func thumbnails(of info: VideoClip, clip: ClipItem, lut: CubeLUT) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: info.asset)
        var snap = GradeState.Snapshot(recipe: clip.effectiveRecipe, lut: lut, mode: .graded)
        var plain = clip
        plain.transform = .identity
        plain.keyframes = []
        snap.clips = [UUID(): plain]
        // Thumbnails show the clip's own picture (no framing), graded, with or without the LUT per its source type.
        let state = GradeState(snap)
        let composition = info.makeComposition(state: state) as! AVMutableVideoComposition
        composition.instructions = [GradeInstruction(timeRange: CMTimeRange(start: .zero, duration: info.duration),
                                                     layers: [LayerSpec(clipID: snap.clips.keys.first, trackID: info.track.trackID,
                                                                        orientation: info.orientation)], state: state)]
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width: 200, height: 200)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let count = max(2, min(10, Int(clip.duration / 1.5) + 2))
        var images: [CGImage] = []
        for i in 0..<count {
            if Task.isCancelled { return [] }
            let s = clip.sourceStart + clip.sourceLength * (Double(i) + 0.5) / Double(count)
            if let (image, _) = try? await generator.image(at: CMTime(seconds: s, preferredTimescale: 600)) { images.append(image) }
        }
        return images
    }

    /// A graded thumbnail of a photo clip.
    static func photoThumbnail(_ clip: ClipItem, lut: CubeLUT) -> CGImage? {
        guard let still = StillCache.image(clip.url) else { return nil }
        let s = 200 / max(1, max(still.extent.width, still.extent.height))
        let small = still.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let graded = GradeRenderer.shared.render(small, recipe: clip.effectiveRecipe, lut: lut, mode: .graded, applyLUT: clip.profile == .dlogM)
        let px = GradeRenderer.shared.rgba8(graded, maxWidth: 200)
        return EditorModel.cgImage(px.pixels, px.width, px.height)
    }

    /// Kept for single-clip callers.
    static func thumbnails(of clip: VideoClip, snapshot: GradeState.Snapshot, count: Int) async -> [CGImage] {
        let item = ClipItem(url: clip.asset.url, sourceStart: 0, sourceEnd: clip.duration.seconds, recipe: snapshot.recipe)
        return await thumbnails(of: clip, clip: item, lut: snapshot.lut)
    }
}

/// Peak levels of the first audio track, for drawing a waveform.
enum Waveform {
    static func peaks(of asset: AVAsset, buckets: Int) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }

        let total = max(1, Int(duration * sampleRate))
        let perBucket = max(1, total / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        var index = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for i in 0..<(length / 4) {
                    let b = min(buckets - 1, index / perBucket)
                    peaks[b] = max(peaks[b], abs(samples[i]))
                    index += 1
                }
            }
        }
        let top = max(peaks.max() ?? 1, 0.0001)
        return peaks.map { $0 / top }
    }

    /// The part of a full-file waveform covering `start…end` of a file `duration` long.
    static func slice(_ peaks: [Float], duration: Double, start: Double, end: Double) -> [Float] {
        guard !peaks.isEmpty, duration > 0 else { return [] }
        let a = max(0, min(peaks.count - 1, Int(start / duration * Double(peaks.count))))
        let b = max(a + 1, min(peaks.count, Int(end / duration * Double(peaks.count))))
        return Array(peaks[a..<b])
    }
}

/// RGB + luma histogram, 64 bins each, normalized so the tallest bin is 1.
struct Histogram: Equatable {
    static let bins = 64
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luma: [Float]
    var clippedHighlights: Bool
    var clippedShadows: Bool

    /// From BGRA8 pixels, sampling every `step`-th pixel in both directions.
    init(bgra base: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int, step: Int) {
        var r = [Float](repeating: 0, count: Self.bins), g = r, b = r, y = r
        var hi = 0, lo = 0, n = 0
        let scale = Float(Self.bins) / 256
        for row in stride(from: 0, to: height, by: step) {
            let p = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            for col in stride(from: 0, to: width, by: step) {
                let bb = p[col * 4], gg = p[col * 4 + 1], rr = p[col * 4 + 2]
                r[Int(Float(rr) * scale)] += 1
                g[Int(Float(gg) * scale)] += 1
                b[Int(Float(bb) * scale)] += 1
                let l = 0.2126 * Float(rr) + 0.7152 * Float(gg) + 0.0722 * Float(bb)
                y[min(Self.bins - 1, Int(l * scale))] += 1
                if max(rr, gg, bb) >= 252 { hi += 1 }
                if l <= 3 { lo += 1 }
                n += 1
            }
        }
        // Ignore the extreme bins when normalizing so a little clipping doesn't flatten the graph.
        let top = max(1, ([r, g, b, y].flatMap { Array($0[1..<(Self.bins - 1)]) }.max() ?? 1))
        red = r.map { min(1, $0 / top) }
        green = g.map { min(1, $0 / top) }
        blue = b.map { min(1, $0 / top) }
        luma = y.map { min(1, $0 / top) }
        clippedHighlights = Float(hi) / Float(max(1, n)) > 0.005
        clippedShadows = Float(lo) / Float(max(1, n)) > 0.005
    }

    init(red: [Float], green: [Float], blue: [Float], luma: [Float], clippedHighlights: Bool, clippedShadows: Bool) {
        self.red = red; self.green = green; self.blue = blue; self.luma = luma
        self.clippedHighlights = clippedHighlights; self.clippedShadows = clippedShadows
    }
}

/// Reads the composited (graded) frames the player shows and turns them into a histogram, ~6 times a second.
@MainActor
final class ScopeMonitor: ObservableObject {
    @Published private(set) var histogram: Histogram?
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "eddie.scope", qos: .utility)
    private var computing = false

    func attach(to item: AVPlayerItem) {
        if let output, let old = self.item { old.remove(output) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        self.output = output
        self.item = item
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard !computing, let output, let item else { return }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        computing = true
        nonisolated(unsafe) let pixels = buffer
        queue.async { [weak self] in
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
            let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
            let step = max(1, w / 320)
            let hist = Histogram(bgra: base, width: w, height: h, rowBytes: CVPixelBufferGetBytesPerRow(pixels), step: step)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.histogram = hist
                    self?.computing = false
                }
            }
        }
    }
}
