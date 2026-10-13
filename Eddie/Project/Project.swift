import Foundation

// MARK: - Building blocks

/// Framing of a clip in the project frame: crop the source, then scale/move/rotate the result.
struct Transform2D: Codable, Equatable {
    /// 1 = the clip fills (or fits) the frame per the project setting.
    var scale = 1.0
    /// Offset as a fraction of the frame size (+x right, +y down).
    var x = 0.0
    var y = 0.0
    /// Clockwise, degrees.
    var rotation = 0.0
    /// Fractions of the source cut away from each side.
    var cropLeft = 0.0
    var cropRight = 0.0
    var cropTop = 0.0
    var cropBottom = 0.0

    static let identity = Transform2D()
    var isIdentity: Bool { self == .identity }

    func interpolated(to b: Transform2D, _ t: Double) -> Transform2D {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Transform2D(scale: mix(scale, b.scale), x: mix(x, b.x), y: mix(y, b.y), rotation: mix(rotation, b.rotation),
                           cropLeft: mix(cropLeft, b.cropLeft), cropRight: mix(cropRight, b.cropRight),
                           cropTop: mix(cropTop, b.cropTop), cropBottom: mix(cropBottom, b.cropBottom))
    }
}

/// A framing at a moment within a clip (seconds from the clip's start on the timeline).
struct Keyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var transform: Transform2D
}

/// How the clip was shot: D-Log M needs the DJI LUT; normal footage (phone, Rec.709) doesn't.
enum SourceProfile: String, Codable, CaseIterable, Identifiable {
    case dlogM, normal
    var id: String { rawValue }
    var label: String { self == .dlogM ? "D-Log M" : "Normal" }
}

/// How a clip comes in from the previous one.
struct Transition: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case crossDissolve, dipToBlack, wipe, slide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .crossDissolve: return "Cross Dissolve"
            case .dipToBlack: return "Dip to Black"
            case .wipe: return "Wipe"
            case .slide: return "Slide"
            }
        }
    }
    var kind = Kind.crossDissolve
    var duration = 0.6
}

// MARK: - Clips

/// One clip (video or photo): a trimmed range of a source file, played at a speed, framed and graded.
/// Used on the main track and, wrapped in `OverlayItem`, on the overlay track.
struct ClipItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    /// For photos: 0 and the duration it shows for.
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double = 1
    var recipe = GradeRecipe()
    var intensity = 1.0
    var audioMuted = false
    /// The clip's own sound level, 0…1.
    var volume = 1.0
    var isPhoto = false
    var profile = SourceProfile.dlogM
    var transform = Transform2D.identity
    /// When there are keyframes, framing animates between them (and `transform` is ignored).
    var keyframes: [Keyframe] = []
    /// How it comes in from the previous clip (on the first clip: a fade from black).
    var transitionIn: Transition? = nil
    var audioFadeIn = 0.0
    var audioFadeOut = 0.0
    /// Cleaned-up sound (noise reduction / loudness) rendered to a file, used instead of the source's audio.
    var audioOverride: URL? = nil
    /// A reversed copy of the source, used when the clip plays backwards.
    var reversedURL: URL? = nil
    /// Looks on top of the grade (blur, grain, glitch…), in order.
    var effects: [ClipEffect] = []
    var mask: ClipMask? = nil
    var chromaKey: ChromaKey? = nil
    var reversed = false

    static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    static let minLength = 0.2

    var name: String { url.lastPathComponent }
    var sourceLength: Double { sourceEnd - sourceStart }
    /// Length on the timeline, after speed.
    var duration: Double { sourceLength / speed }
    var effectiveRecipe: GradeRecipe { recipe.scaled(by: intensity) }

    /// Framing at a moment within the clip (seconds from its start on the timeline).
    func transform(at local: Double) -> Transform2D {
        guard !keyframes.isEmpty else { return transform }
        let k = keyframes.sorted { $0.time < $1.time }
        if local <= k[0].time || k.count == 1 { return k[0].transform }
        if local >= k[k.count - 1].time { return k[k.count - 1].transform }
        for (a, b) in zip(k, k.dropFirst()) where local >= a.time && local <= b.time {
            let t = (local - a.time) / max(1e-6, b.time - a.time)
            let eased = t * t * (3 - 2 * t)   // smooth start and stop
            return a.transform.interpolated(to: b.transform, eased)
        }
        return transform
    }
}

extension ClipItem {
    // Older project files lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        sourceStart = try c.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try c.decode(Double.self, forKey: .sourceEnd)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        recipe = try c.decodeIfPresent(GradeRecipe.self, forKey: .recipe) ?? GradeRecipe()
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 1
        audioMuted = try c.decodeIfPresent(Bool.self, forKey: .audioMuted) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isPhoto = try c.decodeIfPresent(Bool.self, forKey: .isPhoto) ?? false
        profile = try c.decodeIfPresent(SourceProfile.self, forKey: .profile) ?? .dlogM
        transform = try c.decodeIfPresent(Transform2D.self, forKey: .transform) ?? .identity
        keyframes = try c.decodeIfPresent([Keyframe].self, forKey: .keyframes) ?? []
        transitionIn = try c.decodeIfPresent(Transition.self, forKey: .transitionIn)
        audioFadeIn = try c.decodeIfPresent(Double.self, forKey: .audioFadeIn) ?? 0
        audioFadeOut = try c.decodeIfPresent(Double.self, forKey: .audioFadeOut) ?? 0
        audioOverride = try c.decodeIfPresent(URL.self, forKey: .audioOverride)
        reversedURL = try c.decodeIfPresent(URL.self, forKey: .reversedURL)
        reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        effects = try c.decodeIfPresent([ClipEffect].self, forKey: .effects) ?? []
        mask = try c.decodeIfPresent(ClipMask.self, forKey: .mask)
        chromaKey = try c.decodeIfPresent(ChromaKey.self, forKey: .chromaKey)
    }
}

/// A clip on the overlay track (B-roll, picture-in-picture, logos), placed anywhere on the timeline.
struct OverlayItem: Identifiable, Codable, Equatable {
    var clip: ClipItem
    /// Where it starts on the timeline.
    var start: Double
    var opacity = 1.0
    var blend = BlendMode.normal
    /// Which overlay lane it's on; higher lanes draw on top.
    var lane = 0
    var id: UUID { clip.id }
    var end: Double { start + clip.duration }

    init(clip: ClipItem, start: Double, opacity: Double = 1, blend: BlendMode = .normal, lane: Int = 0) {
        self.clip = clip
        self.start = start
        self.opacity = opacity
        self.blend = blend
        self.lane = lane
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clip = try c.decode(ClipItem.self, forKey: .clip)
        start = try c.decode(Double.self, forKey: .start)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        blend = try c.decodeIfPresent(BlendMode.self, forKey: .blend) ?? .normal
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 0
    }
}

// MARK: - Audio, titles, markers

/// A song, voiceover or sound effect on the audio lanes.
struct MusicItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case music, voiceover, effect }

    var id = UUID()
    var url: URL
    /// Where it starts on the timeline.
    var start: Double
    var sourceStart: Double = 0
    var sourceEnd: Double
    var volume = 0.8
    var fadeIn = 1.0
    var fadeOut = 2.0
    var kind = Kind.music
    /// Which audio lane it's drawn on.
    var lane = 0
    /// A cleaned-up copy (normalized / noise-reduced) Eddie made; played instead of `url`.
    var processed: URL?
    /// Beat times in the source file, in seconds (for snapping).
    var beats: [Double] = []

    var name: String { url.lastPathComponent }
    var playURL: URL { processed ?? url }
    var duration: Double { sourceEnd - sourceStart }
    var end: Double { start + duration }
}

extension MusicItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        start = try c.decode(Double.self, forKey: .start)
        sourceStart = try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        sourceEnd = try c.decode(Double.self, forKey: .sourceEnd)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 1
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 2
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .music
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 0
        processed = try c.decodeIfPresent(URL.self, forKey: .processed)
        beats = try c.decodeIfPresent([Double].self, forKey: .beats) ?? []
    }
}

/// Text over the video for a stretch of time.
struct TitleItem: Identifiable, Codable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case title, lowerThird, caption
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "Title"
            case .lowerThird: return "Lower third"
            case .caption: return "Caption"
            }
        }
    }

    enum Weight: String, Codable, CaseIterable, Identifiable {
        case regular, medium, bold, heavy
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum Align: String, Codable, CaseIterable, Identifiable {
        case left, center, right
        var id: String { rawValue }
    }

    /// How the text comes on and goes off.
    enum Animation: String, Codable, CaseIterable, Identifiable {
        case fade, pop, slideUp, slideDown, typewriter, bounce, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fade: return "Fade"
            case .pop: return "Pop"
            case .slideUp: return "Slide up"
            case .slideDown: return "Slide down"
            case .typewriter: return "Typewriter"
            case .bounce: return "Bounce"
            case .none: return "None"
            }
        }
    }

    /// One spoken word in a caption, in timeline seconds (for word-by-word highlighting).
    struct Word: Codable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    var id = UUID()
    var text = "Title"
    var start: Double
    var duration: Double = 3
    /// Preset look: sets the default position, weight, plate and alignment.
    var style = Style.title
    /// Text size multiplier, 0.3…4.
    var size = 1.0
    /// Center of the text box as a fraction of the frame (x from the left, y from the top). nil = the style's spot.
    var x: Double?
    var y: Double?
    /// Clockwise, in degrees.
    var rotation = 0.0
    /// Font family name, or "System", "Rounded", "Serif", "Mono" for Apple's system fonts.
    var font = "System"
    var weight: Weight?
    var italic = false
    /// Hex color, e.g. "#FFFFFF".
    var color = "#FFFFFF"
    /// Dark plate behind the text. nil = the style's default.
    var plate: Bool?
    var align: Align?
    /// A caption (on the captions lane, styled and edited together; auto captions replace these).
    var isCaption = false
    /// Outline around the letters, as a fraction of the font size (0 = none).
    var outline = 0.0
    var outlineColor = "#000000"
    /// Soft glow around the letters, 0…1.
    var glow = 0.0
    var glowColor = "#FFD60A"
    var animation = Animation.fade
    /// Light up each word as it's spoken (karaoke-style), in `highlightColor`.
    var wordHighlight = false
    var highlightColor = "#FFD60A"
    /// Word timings from speech recognition; empty means words are spread evenly over the caption.
    var words: [Word] = []

    static let minLength = 0.3
    var end: Double { start + duration }

    var resolvedWeight: Weight { weight ?? (style == .title ? .heavy : (style == .lowerThird ? .bold : .medium)) }
    var resolvedPlate: Bool { plate ?? (style != .title) }
    var resolvedAlign: Align { align ?? (style == .lowerThird ? .left : .center) }

    init(text: String = "Title", start: Double, duration: Double = 3, style: Style = .title, size: Double = 1) {
        self.text = text
        self.start = start
        self.duration = duration
        self.style = style
        self.size = size
    }

    // Titles saved before font/position options existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        duration = try c.decode(Double.self, forKey: .duration)
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .title
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? "System"
        weight = try c.decodeIfPresent(Weight.self, forKey: .weight)
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#FFFFFF"
        plate = try c.decodeIfPresent(Bool.self, forKey: .plate)
        align = try c.decodeIfPresent(Align.self, forKey: .align)
        isCaption = try c.decodeIfPresent(Bool.self, forKey: .isCaption) ?? false
        outline = try c.decodeIfPresent(Double.self, forKey: .outline) ?? 0
        outlineColor = try c.decodeIfPresent(String.self, forKey: .outlineColor) ?? "#000000"
        glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? 0
        glowColor = try c.decodeIfPresent(String.self, forKey: .glowColor) ?? "#FFD60A"
        animation = try c.decodeIfPresent(Animation.self, forKey: .animation) ?? .fade
        wordHighlight = try c.decodeIfPresent(Bool.self, forKey: .wordHighlight) ?? false
        highlightColor = try c.decodeIfPresent(String.self, forKey: .highlightColor) ?? "#FFD60A"
        words = try c.decodeIfPresent([Word].self, forKey: .words) ?? []
    }

    /// The words of the text with their times: speech timings when they still match the text,
    /// otherwise spread over the caption by length.
    var timedWords: [Word] {
        let pieces = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !pieces.isEmpty else { return [] }
        if words.count == pieces.count { return zip(pieces, words).map { Word(text: $0, start: $1.start, end: $1.end) } }
        let total = Double(pieces.reduce(0) { $0 + $1.count + 1 })
        var t = start
        return pieces.map { w in
            let d = duration * Double(w.count + 1) / total
            defer { t += d }
            return Word(text: w, start: t, end: t + d)
        }
    }
}

struct Marker: Identifiable, Codable, Equatable {
    var id = UUID()
    var time: Double
    var name = ""
}

/// The shape of the video.
struct ProjectFormat: Codable, Equatable {
    enum Aspect: String, Codable, CaseIterable, Identifiable {
        case auto, landscape, portrait, square, portrait4x5
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Same as first clip"
            case .landscape: return "Landscape 16:9"
            case .portrait: return "Vertical 9:16"
            case .square: return "Square 1:1"
            case .portrait4x5: return "Portrait 4:5"
            }
        }
        /// width / height
        var ratio: Double? {
            switch self {
            case .auto: return nil
            case .landscape: return 16.0 / 9
            case .portrait: return 9.0 / 16
            case .square: return 1
            case .portrait4x5: return 4.0 / 5
            }
        }
    }
    var aspect = Aspect.auto
    /// Clips of another shape fill the frame (cropping) instead of fitting inside it (bars).
    var fill = true
    /// What shows around clips that fit inside the frame: black bars or a blurred copy of the clip.
    var blurBackground = false

    init(aspect: Aspect = .auto, fill: Bool = true, blurBackground: Bool = false) {
        self.aspect = aspect
        self.fill = fill
        self.blurBackground = blurBackground
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? .auto
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? true
        blurBackground = try c.decodeIfPresent(Bool.self, forKey: .blurBackground) ?? false
    }

    /// Frame size for a project whose first clip is `source` (its long side is kept).
    func renderSize(source: CGSize) -> CGSize {
        guard let r = aspect.ratio else { return source }
        let long = max(source.width, source.height)
        let size = r >= 1 ? CGSize(width: long, height: long / r) : CGSize(width: long * r, height: long)
        return CGSize(width: (size.width / 2).rounded() * 2, height: (size.height / 2).rounded() * 2)
    }
}

// MARK: - Project

/// The whole edit. A plain value: copying it is how undo works.
struct Project: Codable, Equatable {
    var clips: [ClipItem] = []
    var music: [MusicItem] = []
    var titles: [TitleItem] = []
    var overlays: [OverlayItem] = []
    var markers: [Marker] = []
    var format = ProjectFormat()
    /// Fade to black at the very end, in seconds (0 = none).
    var fadeOut = 0.0
    /// Lower the clips' own sound while a song plays, so the music can be heard.
    var duckUnderMusic = true
    /// Media brought into the project but not necessarily on the timeline.
    var bin: [URL] = []
    /// Lanes switched off with their speaker button: "clips" (the videos' own sound), "overlays",
    /// or "audio0", "audio1"… (song/voiceover/effect lanes). Applies to playback and export.
    var mutedLanes: Set<String> = []
    /// Picture lanes switched off ("video", "titles", "captions", "overlay0"…) — not drawn in playback or export.
    var hiddenLanes: Set<String> = []
    /// Lanes that can't be changed on the timeline (same keys, plus "clipsound" and "audio0"…).
    var lockedLanes: Set<String> = []
    static func overlayLane(_ i: Int) -> String { "overlay\(i)" }

    static let clipSoundLane = "clips"
    static let overlaySoundLane = "overlays"
    static func audioLane(_ i: Int) -> String { "audio\(i)" }

    static let duckLevel = 0.25

    init(clips: [ClipItem] = [], music: [MusicItem] = [], titles: [TitleItem] = []) {
        self.clips = clips
        self.music = music
        self.titles = titles
    }

    // Older project files lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent([ClipItem].self, forKey: .clips) ?? []
        music = try c.decodeIfPresent([MusicItem].self, forKey: .music) ?? []
        titles = try c.decodeIfPresent([TitleItem].self, forKey: .titles) ?? []
        overlays = try c.decodeIfPresent([OverlayItem].self, forKey: .overlays) ?? []
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        format = try c.decodeIfPresent(ProjectFormat.self, forKey: .format) ?? ProjectFormat()
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        duckUnderMusic = try c.decodeIfPresent(Bool.self, forKey: .duckUnderMusic) ?? true
        bin = try c.decodeIfPresent([URL].self, forKey: .bin) ?? []
        mutedLanes = try c.decodeIfPresent(Set<String>.self, forKey: .mutedLanes) ?? []
        hiddenLanes = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenLanes) ?? []
        lockedLanes = try c.decodeIfPresent(Set<String>.self, forKey: .lockedLanes) ?? []
    }

    // MARK: Media

    /// Every original file the edit points at (not files Eddie made, like reversed copies).
    var mediaURLs: [URL] {
        var seen = Set<URL>(), out: [URL] = []
        for u in clips.map(\.url) + overlays.map(\.clip.url) + music.map(\.url) + bin where seen.insert(u).inserted { out.append(u) }
        return out
    }

    /// Points everything that used `old` at `new` (after a file was moved).
    mutating func relink(_ old: URL, to new: URL) {
        for i in clips.indices where clips[i].url == old { clips[i].url = new }
        for i in overlays.indices where overlays[i].clip.url == old { overlays[i].clip.url = new }
        for i in music.indices where music[i].url == old { music[i].url = new }
        for i in bin.indices where bin[i] == old { bin[i] = new }
    }

    var isEmpty: Bool { clips.isEmpty }

    func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    // MARK: Timing (transitions make neighbouring clips overlap)

    /// How much clip `i` overlaps the previous one (its transition length, kept to half of either clip).
    func overlap(at i: Int) -> Double {
        guard i > 0, i < clips.count, let t = clips[i].transitionIn else { return 0 }
        return max(0, min(t.duration, clips[i - 1].duration / 2, clips[i].duration / 2))
    }

    /// Timeline start of each clip, in order.
    var starts: [Double] {
        var out: [Double] = []
        var t = 0.0
        for i in clips.indices {
            if i > 0 { t += clips[i - 1].duration - overlap(at: i) }
            out.append(t)
        }
        return out
    }

    var duration: Double {
        guard let last = clips.indices.last else { return 0 }
        return starts[last] + clips[last].duration
    }

    func start(of id: UUID) -> Double? {
        guard let i = index(of: id) else { return nil }
        return starts[i]
    }

    /// The clip under a timeline time (the incoming one inside a transition) and the matching source time.
    func locate(_ time: Double) -> (index: Int, sourceTime: Double)? {
        guard !clips.isEmpty else { return nil }
        let t = min(max(0, time), duration)
        let s = starts
        var hit = clips.count - 1
        for i in clips.indices.reversed() where t >= s[i] { hit = i; break }
        let c = clips[hit]
        let local = min(max(0, t - s[hit]), c.duration)
        // A reversed clip plays from its end back to its start.
        return (hit, c.reversed ? c.sourceEnd - local * c.speed : c.sourceStart + local * c.speed)
    }

    /// The clips' own sound level over time: (start, end, level) pieces covering the whole timeline,
    /// with ducking applied wherever a song plays.
    func clipSoundLevels() -> [(start: Double, end: Double, level: Double)] {
        var cuts = Set(starts + [duration])
        if duckUnderMusic {
            for m in music { cuts.insert(max(0, m.start)); cuts.insert(min(duration, m.end)) }
        }
        let times = cuts.filter { $0 >= 0 && $0 <= duration }.sorted()
        var out: [(Double, Double, Double)] = []
        for (a, b) in zip(times, times.dropFirst()) where b - a > 1e-6 {
            let mid = (a + b) / 2
            guard let (i, _) = locate(mid) else { continue }
            let c = clips[i]
            var level = c.audioMuted ? 0 : c.volume
            if duckUnderMusic, music.contains(where: { $0.start <= mid && $0.end > mid }) { level *= Self.duckLevel }
            out.append((a, b, level))
        }
        return out
    }

    // MARK: Edits

    /// Cuts the clip under `time` in two. Returns the id of the new right-hand clip.
    @discardableResult
    mutating func split(at time: Double) -> UUID? {
        guard let (i, sourceTime) = locate(time) else { return nil }
        let c = clips[i]
        guard sourceTime - c.sourceStart >= ClipItem.minLength,
              c.sourceEnd - sourceTime >= ClipItem.minLength else { return nil }
        let localCut = (c.reversed ? c.sourceEnd - sourceTime : sourceTime - c.sourceStart) / c.speed
        var left = c, right = c
        if c.reversed {
            left.sourceStart = sourceTime
            right.sourceEnd = sourceTime
        } else {
            left.sourceEnd = sourceTime
            right.sourceStart = sourceTime
        }
        left.audioFadeOut = 0
        left.keyframes = c.keyframes.filter { $0.time <= localCut }
        right.id = UUID()
        right.transitionIn = nil
        right.audioFadeIn = 0
        right.keyframes = c.keyframes.filter { $0.time >= localCut }.map { var k = $0; k.id = UUID(); k.time -= localCut; return k }
        // Keep the framing continuous across the cut when it was animated.
        if !c.keyframes.isEmpty {
            let atCut = c.transform(at: localCut)
            if !left.keyframes.contains(where: { abs($0.time - localCut) < 1e-6 }) { left.keyframes.append(Keyframe(time: localCut, transform: atCut)) }
            if !right.keyframes.contains(where: { abs($0.time) < 1e-6 }) { right.keyframes.insert(Keyframe(time: 0, transform: atCut), at: 0) }
        }
        clips[i] = left
        clips.insert(right, at: i + 1)
        return right.id
    }

    mutating func move(_ id: UUID, to newIndex: Int) {
        guard let i = index(of: id) else { return }
        let c = clips.remove(at: i)
        clips.insert(c, at: min(max(0, newIndex), clips.count))
    }

    mutating func insert(_ new: [ClipItem], at index: Int) {
        clips.insert(contentsOf: new, at: min(max(0, index), clips.count))
    }

    /// Index of the first clip starting at or after `time` (where an insert at `time` goes).
    func insertionIndex(at time: Double) -> Int {
        starts.firstIndex { $0 >= time - 0.01 } ?? clips.count
    }

    /// Insert edit: cuts at `time` and pushes everything after it along.
    mutating func insert(_ new: [ClipItem], atTime time: Double) {
        if time > 0.01 && time < duration - 0.01 { split(at: time) }
        insert(new, at: insertionIndex(at: time))
    }

    /// Overwrite edit: the new clips replace whatever was on the timeline for their length.
    mutating func overwrite(_ new: [ClipItem], atTime time: Double) {
        let length = new.reduce(0) { $0 + $1.duration }
        let end = time + length
        if time > 0.01 && time < duration - 0.01 { split(at: time) }
        if end > 0.01 && end < duration - 0.01 { split(at: end) }
        let s = starts
        let doomed = clips.indices.filter { s[$0] >= time - 0.01 && s[$0] + clips[$0].duration <= end + 0.01 }.map { clips[$0].id }
        clips.removeAll { doomed.contains($0.id) }
        insert(new, at: insertionIndex(at: time))
    }

    mutating func remove(_ id: UUID) {
        // What leaves the timeline stays in the media bin.
        let gone = clips.filter { $0.id == id }.map(\.url) + overlays.filter { $0.id == id }.map(\.clip.url)
            + music.filter { $0.id == id }.map(\.url)
        for u in gone where !bin.contains(u) { bin.append(u) }
        clips.removeAll { $0.id == id }
        music.removeAll { $0.id == id }
        titles.removeAll { $0.id == id }
        overlays.removeAll { $0.id == id }
        markers.removeAll { $0.id == id }
    }

    @discardableResult
    mutating func duplicate(_ id: UUID) -> UUID? {
        guard let i = index(of: id) else { return nil }
        var copy = clips[i]
        copy.id = UUID()
        clips.insert(copy, at: i + 1)
        return copy.id
    }

    /// Trims a clip's in/out points (in source seconds), keeping at least `minLength`.
    mutating func trim(_ id: UUID, start: Double? = nil, end: Double? = nil, sourceDuration: Double) {
        if let i = index(of: id) {
            clips[i] = Self.trimmed(clips[i], start: start, end: end, sourceDuration: sourceDuration)
        } else if let i = overlays.firstIndex(where: { $0.id == id }) {
            let before = overlays[i].clip
            let after = Self.trimmed(before, start: start, end: end, sourceDuration: sourceDuration)
            overlays[i].clip = after
            // Trimming an overlay's start keeps its later frames in place on the timeline.
            overlays[i].start += (after.sourceStart - before.sourceStart) / max(after.speed, 0.01)
        }
    }

    private static func trimmed(_ clip: ClipItem, start: Double?, end: Double?, sourceDuration: Double) -> ClipItem {
        var c = clip
        // Photos can be stretched as long as you like.
        let limit = c.isPhoto ? 3600 : sourceDuration
        if let start { c.sourceStart = min(max(0, start), c.sourceEnd - ClipItem.minLength) }
        if let end { c.sourceEnd = max(min(limit, end), c.sourceStart + ClipItem.minLength) }
        return c
    }

    mutating func setSpeed(_ id: UUID, _ speed: Double) {
        let s = min(max(speed, 0.25), 4)
        if let i = index(of: id) { clips[i].speed = s }
        if let i = overlays.firstIndex(where: { $0.id == id }) { overlays[i].clip.speed = s }
    }

    /// Changes a clip wherever it is (main track or overlay track).
    mutating func updateClip(_ id: UUID, _ change: (inout ClipItem) -> Void) {
        if let i = index(of: id) { change(&clips[i]) }
        if let i = overlays.firstIndex(where: { $0.id == id }) { change(&overlays[i].clip) }
    }

    func clip(_ id: UUID) -> ClipItem? {
        clips.first { $0.id == id } ?? overlays.first { $0.id == id }?.clip
    }

    mutating func updateOverlay(_ id: UUID, _ change: (inout OverlayItem) -> Void) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        change(&overlays[i])
    }

    mutating func updateTitle(_ id: UUID, _ change: (inout TitleItem) -> Void) {
        guard let i = titles.firstIndex(where: { $0.id == id }) else { return }
        change(&titles[i])
    }

    mutating func updateMusic(_ id: UUID, _ change: (inout MusicItem) -> Void) {
        guard let i = music.firstIndex(where: { $0.id == id }) else { return }
        change(&music[i])
    }

    // MARK: Captions

    var captions: [TitleItem] { titles.filter(\.isCaption).sorted { $0.start < $1.start } }

    /// Removes stretches of the timeline (e.g. filler words or silences), closing the gaps. Titles, overlays,
    /// songs and markers after a cut move back with the picture. Ranges are timeline seconds.
    mutating func removeRanges(_ ranges: [(start: Double, end: Double)]) {
        // Merge, then cut from the end so earlier times stay valid.
        let merged = ranges.filter { $0.end - $0.start > 0.02 }.sorted { $0.start < $1.start }
            .reduce(into: [(start: Double, end: Double)]()) { acc, r in
                if let last = acc.last, r.start <= last.end + 0.01 { acc[acc.count - 1].end = max(last.end, r.end) } else { acc.append(r) }
            }
        for r in merged.reversed() {
            let a = max(0, r.start), b = min(duration, r.end)
            guard b - a > 0.02 else { continue }
            if b < duration - 0.01 { split(at: b) }
            if a > 0.01 { split(at: a) }
            let s = starts
            let doomed = clips.indices.filter { s[$0] >= a - 0.02 && s[$0] + clips[$0].duration <= b + 0.02 }.map { clips[$0].id }
            guard !doomed.isEmpty else { continue }
            let removed = doomed.compactMap { id in clips.first { $0.id == id } }.reduce(0) { $0 + $1.duration }
            clips.removeAll { doomed.contains($0.id) }
            // Everything that sat after the cut moves back; anything inside it goes.
            func shift(_ t: Double) -> Double { t >= b ? t - removed : t }
            titles = titles.compactMap { t in
                var t = t
                if t.start >= a && t.end <= b { return nil }
                t.start = shift(t.start)
                t.words = t.words.map { var w = $0; w.start = shift(w.start); w.end = shift(w.end); return w }
                return t
            }
            for i in overlays.indices { overlays[i].start = shift(overlays[i].start) }
            for i in music.indices { music[i].start = shift(music[i].start) }
            markers = markers.filter { !($0.time > a && $0.time < b) }.map { var m = $0; m.time = shift(m.time); return m }
        }
    }

    /// Clip boundaries plus overlay, title, song and marker edges — what dragged edges snap to.
    func edges(excluding id: UUID? = nil) -> [Double] {
        var out = starts + [duration]
        for (i, c) in clips.enumerated() { out.append(starts[i] + c.duration) }
        for o in overlays where o.id != id { out += [o.start, o.end] }
        for t in titles where t.id != id { out += [t.start, t.end] }
        for m in music where m.id != id { out += [m.start, m.end] }
        for m in markers where m.id != id { out.append(m.time) }
        return out + beatTimes(excluding: id)
    }

    /// Beats of the songs on the timeline (in timeline time), for snapping cuts to the music.
    func beatTimes(excluding id: UUID? = nil) -> [Double] {
        var out: [Double] = []
        for m in music where m.id != id && !m.beats.isEmpty {
            for b in m.beats where b >= m.sourceStart && b <= m.sourceEnd { out.append(m.start + b - m.sourceStart) }
        }
        return out
    }

    /// Clip starts as they'd be with `id` moved to `target` — used to open a gap while rearranging.
    func previewStarts(moving id: UUID, to target: Int) -> [UUID: Double] {
        var copy = self
        copy.move(id, to: target)
        return Dictionary(uniqueKeysWithValues: zip(copy.clips.map(\.id), copy.starts))
    }

    /// Where a clip dragged so its middle sits at `center` (seconds) would land:
    /// the number of other clips whose middle is to its left.
    func landingIndex(moving id: UUID, center: Double) -> Int {
        var copy = self
        guard let i = copy.index(of: id) else { return 0 }
        copy.clips.remove(at: i)
        return zip(copy.starts, copy.clips).filter { $0.0 + $0.1.duration / 2 < center }.count
    }
}

/// Snapping: moves `time` onto the nearest target within `tolerance` seconds.
enum Snap {
    static func apply(_ time: Double, to targets: [Double], tolerance: Double) -> (time: Double, target: Double?) {
        guard let best = targets.min(by: { abs($0 - time) < abs($1 - time) }), abs(best - time) <= tolerance else {
            return (time, nil)
        }
        return (best, best)
    }
}
