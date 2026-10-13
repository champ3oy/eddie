import SwiftUI

/// Editing timeline: header (transport, tools), a ruler, then lanes — AI grade, video, clip sound, music —
/// under one white playhead. Clips can be selected, dragged to reorder and trimmed from either edge.
struct TimelineView: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject var clock: PlaybackClock
    /// Timeline scale in points per second. Set once (fit to the edit) and then only changed by zooming —
    /// trimming or adding clips doesn't rescale the timeline. nil until there's something to fit.
    private var pps: CGFloat? {
        get { model.timelineScale }
        nonmutating set { model.timelineScale = newValue }
    }
    @State private var viewport: CGFloat = 800
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var pinchBase: CGFloat?
    // Rearranging: the dragged clip follows the pointer; the others slide aside to open a gap at `dragTarget`.
    @State private var dragID: UUID?
    @State private var dragDX: CGFloat = 0
    @State private var dragTarget = 0
    @State private var trimOrigin: (start: Double, end: Double)?
    @State private var musicOrigin: MusicItem?
    @State private var titleOrigin: TitleItem?
    /// Where a dragged edge snapped to (drawn as a yellow line).
    @State private var snapGuide: Double?
    // True while each kind of drag is in progress; they reset by themselves when macOS cancels a drag,
    // which is how a cancelled drag still gets cleaned up (see `.onChange` in `body`).
    @GestureState private var clipDragActive = false
    @GestureState private var trimDragActive = false
    @GestureState private var musicDragActive = false
    @GestureState private var titleDragActive = false
    @GestureState private var overlayDragActive = false
    @State private var overlayOrigin: OverlayItem?
    @State private var transitionEditor: UUID?
    @State private var showEndFade = false
    /// Which block the pointer is over (its fade handles show), and the fade being dragged.
    @State private var hoverKey: String?
    @State private var fadeOrigin: (key: String, value: Double)?
    @GestureState private var fadeDragActive = false

    private let gutter: CGFloat = 40
    private let rulerHeight: CGFloat = 22
    private let titleHeight: CGFloat = 22
    private let overlayHeight: CGFloat = 40
    private let gradeHeight: CGFloat = 22
    private let videoHeight: CGFloat = 60
    private let audioHeight: CGFloat = 26
    private let musicHeight: CGFloat = 32
    private let gap: CGFloat = 5

    /// Songs, voiceovers and effects stack on as many audio lanes as they use.
    private var audioLanes: Int { max(1, (model.project.music.map(\.lane).max() ?? 0) + 1) }
    private var musicLanesHeight: CGFloat { CGFloat(audioLanes) * musicHeight + CGFloat(audioLanes - 1) * gap }
    private var lanesHeight: CGFloat { titleHeight * 2 + overlayHeight + gradeHeight + videoHeight + audioHeight + musicLanesHeight + gap * 6 }

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(alignment: .top, spacing: 0) {
                gutterIcons.padding(.top, rulerHeight + 6)
                GeometryReader { geo in
                    let pps = scale
                    ScrollView(.horizontal) {
                        content(pps: pps)
                            .frame(width: contentWidth(pps: pps, viewport: geo.size.width), alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
                    // Pinch on the trackpad to zoom around the pointer's time.
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { v in
                            if pinchBase == nil { pinchBase = pps }
                            setScale((pinchBase ?? pps) * v.magnification, anchor: nil)
                        }
                        .onEnded { _ in pinchBase = nil })
                    .onAppear { viewport = geo.size.width; fitIfNeeded() }
                    .onChange(of: geo.size.width) { _, w in viewport = w; fitIfNeeded() }
                }
                .frame(height: rulerHeight + 6 + lanesHeight + 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.black)
        // Clean up drags that ended without an "ended" event (cancelled by the system).
        .onChange(of: clipDragActive) { _, active in
            if !active, dragID != nil { withAnimation(.spring(response: 0.3)) { dragID = nil; dragDX = 0 } }
        }
        .onChange(of: trimDragActive) { _, active in
            if !active, trimOrigin != nil { trimOrigin = nil; snapGuide = nil; model.endInteraction() }
        }
        .onChange(of: musicDragActive) { _, active in
            if !active, musicOrigin != nil { musicOrigin = nil; snapGuide = nil; model.endInteraction() }
        }
        .onChange(of: fadeDragActive) { _, active in
            if !active, fadeOrigin != nil { fadeOrigin = nil; model.endInteraction() }
        }
        .onChange(of: overlayDragActive) { _, active in
            if !active, overlayOrigin != nil { overlayOrigin = nil; snapGuide = nil; model.endInteraction() }
        }
        // A new project gets its own fit; adding the first clips fits once.
        .onChange(of: model.project.duration) { _, d in
            if d == 0 { pps = nil } else { fitIfNeeded() }
        }
        // While playing, page along so the playhead stays in view.
        .onChange(of: clock.time) { _, t in
            guard clock.playing, pps != nil else { return }
            let x = CGFloat(t) * scale
            if x > scrollX + viewport - 30 || x < scrollX { scrollPosition.scrollTo(x: max(0, x - 30)) }
        }
        .onChange(of: titleDragActive) { _, active in
            if !active, titleOrigin != nil { titleOrigin = nil; snapGuide = nil; model.endInteraction() }
        }
    }

    static let minScale: CGFloat = 0.5     // ~30 min across a laptop-wide timeline
    static let maxScale: CGFloat = 600     // a few frames per inch

    private var fitScale: CGFloat {
        min(Self.maxScale, max(Self.minScale, (viewport - 24) / CGFloat(max(model.project.duration, 1))))
    }

    private var scale: CGFloat { pps ?? fitScale }

    /// The whole edit plus room after it (half a screen, or up to the last title/song/overlay).
    private func contentWidth(pps: CGFloat, viewport: CGFloat) -> CGFloat {
        let p = model.project
        let lastItem = ([p.duration] + p.music.map(\.end) + p.titles.map(\.end) + p.overlays.map(\.end)).max() ?? 0
        return max(viewport, CGFloat(lastItem) * pps + viewport * 0.5)
    }

    /// Fixes the scale the first time there's something on the timeline (and for each project opened).
    private func fitIfNeeded() {
        // Wait for a real width — during layout the view can briefly be 0 wide, which would lock in a silly scale.
        guard model.project.duration > 0, viewport > 120 else { return }
        if pps == nil { pps = fitScale; return }
        // Until you zoom yourself, an edit that grows past the right edge is refitted. Shrinking never rescales.
        if !model.timelineZoomedByUser, CGFloat(model.project.duration) * scale > viewport - 24 { pps = fitScale }
    }

    /// Zooms, keeping the playhead (or the middle of the view, if the playhead is off screen) where it is.
    private func setScale(_ newValue: CGFloat, anchor: Double?) {
        let old = scale
        let new = min(Self.maxScale, max(Self.minScale, newValue))
        guard abs(new - old) > 0.0001 else { return }
        let playheadX = CGFloat(clock.time) * old - scrollX
        let t: Double, screenX: CGFloat
        if let anchor {
            t = anchor; screenX = CGFloat(anchor) * old - scrollX
        } else if playheadX >= 0 && playheadX <= viewport {
            t = clock.time; screenX = playheadX
        } else {
            t = Double((scrollX + viewport / 2) / old); screenX = viewport / 2
        }
        pps = new
        model.timelineZoomedByUser = true
        scrollPosition.scrollTo(x: max(0, CGFloat(t) * new - screenX))
    }

    private func zoomToFit() {
        pps = fitScale
        model.timelineZoomedByUser = false
        scrollPosition.scrollTo(x: 0)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Play / pause and the time — frame stepping is on ← / →.
            Button { model.togglePlay() } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .demoAnchor("play")
            .help("Play / pause (Space) — ← / → step one frame")

            (Text(timecode(clock.time)).foregroundStyle(Ink.primary)
                + Text("  /  " + timecode(clock.duration, tenths: false)).foregroundStyle(Ink.tertiary))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()

            Spacer()

            // The tools shrink to fit: everything, then the less common ones in a "More" menu, then the essentials.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { addTools; divider; editTools; editExtras; divider; viewTools }
                HStack(spacing: 4) { addTools; divider; editTools; divider; viewTools; moreMenu(extras: true, adds: false) }
                HStack(spacing: 4) { addClipsTool; titleTool; divider; splitTool; deleteTool; divider; zoomTools; moreMenu(extras: true, adds: true) }
                HStack(spacing: 4) { splitTool; zoomTools; moreMenu(extras: true, adds: true) }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Ink.primary)
        .padding(.leading, gutter - 4)
        .onReceive(NotificationCenter.default.publisher(for: .timelineZoom)) { note in
            if let factor = note.object as? CGFloat { factor == 0 ? zoomToFit() : setScale(scale * factor, anchor: nil) }
        }
    }

    // MARK: Header tools

    private var addClipsTool: some View {
        tool("plus.rectangle.on.rectangle", "Add clips or photos (⌘I)") { Panels.addClips(model) }
    }

    private var titleTool: some View {
        Menu {
            ForEach(TitleItem.Style.allCases) { style in
                Button(style.label) { model.addTitle(style: style) }
            }
            Divider()
            Button(model.captioning ? "Making Captions…" : "Auto Captions from Speech") { model.autoCaptions() }
                .disabled(model.captioning)
        } label: {
            Image(systemName: "textformat").font(.system(size: 13))
        } primaryAction: {
            model.addTitle()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 22)
        .help("Add title at the playhead (⌥⌘T) — hold for styles")
        .demoAnchor("tool-title")
        .disabled(!model.hasProject)
    }

    @ViewBuilder private var addTools: some View {
        addClipsTool
        tool("rectangle.on.rectangle", "Add overlay — B-roll or picture-in-picture (⇧⌘I)") { Panels.addOverlay(model) }
            .demoAnchor("tool-addOverlay")
            .disabled(!model.hasProject)
        Menu {
            Button("Add Music…") { Panels.addMusic(model) }
            Button("Add Sound Effects…") { Panels.addMusic(model, kind: .effect) }
        } label: {
            Image(systemName: "music.note").font(.system(size: 13))
        } primaryAction: {
            Panels.addMusic(model)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 22)
        .help("Add music (⌥⌘M) — hold for sound effects")
        .demoAnchor("tool-music")
        .disabled(!model.hasProject)
        RecordButton(recorder: model.recorder) { model.toggleVoiceover() }
            .disabled(!model.hasProject)
        titleTool
    }

    private var splitTool: some View {
        tool("scissors", "Split at playhead (⌘B)") { model.splitAtPlayhead() }
            .disabled(!model.hasProject)
    }

    private var deleteTool: some View {
        tool("trash", "Delete (⌫)") { model.deleteSelection() }
            .disabled(model.selection == nil)
    }

    @ViewBuilder private var editTools: some View {
        splitTool
        Button { model.bladeMode.toggle() } label: {
            Image(systemName: "scissors.badge.ellipsis")
                .font(.system(size: 13))
                .foregroundStyle(model.bladeMode ? Color.yellow : Ink.secondary)
                .frame(width: 26, height: 22)
        }
        .help(model.bladeMode ? "Blade tool on — click clips to cut them (B / Esc to stop)" : "Blade tool (B)")
        .disabled(!model.hasProject)
        deleteTool
    }

    /// Less common edit tools (moved into "More" when space is short).
    @ViewBuilder private var editExtras: some View {
        Button { model.editMode = model.editMode == .insert ? .overwrite : .insert } label: {
            Image(systemName: model.editMode == .insert ? "arrow.right.to.line" : "square.on.square.intersection.dashed")
                .font(.system(size: 13))
                .foregroundStyle(model.editMode == .overwrite ? Color.yellow : Ink.secondary)
                .frame(width: 26, height: 22)
        }
        .help(model.editMode == .insert ? "Insert: pasted and dropped clips push the rest along" : "Overwrite: pasted and dropped clips replace what's there")
        tool("flag", "Add marker (M)") { model.addMarker() }
            .disabled(!model.hasProject)
        tool("plus.square.on.square", "Duplicate clip") { model.duplicateSelection() }
            .disabled(model.selectedClip == nil)
    }

    @ViewBuilder private var zoomTools: some View {
        tool("minus.magnifyingglass", "Zoom out (⌘−)") { setScale(scale / 1.5, anchor: nil) }
            .disabled(scale <= Self.minScale)
        tool("plus.magnifyingglass", "Zoom in (⌘=)") { setScale(scale * 1.5, anchor: nil) }
            .disabled(scale >= Self.maxScale)
    }

    @ViewBuilder private var viewTools: some View {
        Button { model.snapping.toggle() } label: {
            Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                .font(.system(size: 13))
                .foregroundStyle(model.snapping ? Color.yellow : Ink.secondary)
                .frame(width: 26, height: 22)
        }
        .help(model.snapping ? "Snapping on (N)" : "Snapping off (N)")
        tool("minus.magnifyingglass", "Zoom out (⌘−)") { setScale(scale / 1.5, anchor: nil) }
            .disabled(scale <= Self.minScale)
        tool("arrow.left.and.right.square", "Zoom to fit (⇧Z)") { zoomToFit() }
            .disabled(!model.hasProject)
        tool("plus.magnifyingglass", "Zoom in (⌘=)") { setScale(scale * 1.5, anchor: nil) }
            .disabled(scale >= Self.maxScale)
    }

    /// Everything that didn't fit, as a menu.
    private func moreMenu(extras: Bool, adds: Bool) -> some View {
        Menu {
            if adds {
                Button("Add Overlay…") { Panels.addOverlay(model) }
                Button("Add Music…") { Panels.addMusic(model) }
                Button("Add Sound Effects…") { Panels.addMusic(model, kind: .effect) }
                Button(model.recorder.isRecording ? "Stop Recording" : "Record Voiceover") { model.toggleVoiceover() }
                Divider()
                Button(model.bladeMode ? "Blade Tool Off" : "Blade Tool (B)") { model.bladeMode.toggle() }
                Button(model.snapping ? "Turn Snapping Off (N)" : "Turn Snapping On (N)") { model.snapping.toggle() }
                Button("Zoom to Fit (⇧Z)") { zoomToFit() }
                Divider()
            }
            if extras {
                Picker("Paste and Drop", selection: $model.editMode) {
                    Text("Insert").tag(EditorModel.EditMode.insert)
                    Text("Overwrite").tag(EditorModel.EditMode.overwrite)
                }
                Button("Add Marker (M)") { model.addMarker() }
                Button("Duplicate Clip") { model.duplicateSelection() }.disabled(model.selectedClip == nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 22)
        .help("More tools")
        .disabled(!model.hasProject)
    }

    private var divider: some View { Rectangle().fill(Ink.hairline).frame(width: 1, height: 16).padding(.horizontal, 4) }

    private func tool(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13)).frame(width: 26, height: 22) }
            .help(help)
    }

    private var gutterIcons: some View {
        VStack(spacing: gap) {
            Image(systemName: "textformat").frame(height: titleHeight)
            Image(systemName: "captions.bubble").frame(height: titleHeight)
            Image(systemName: "rectangle.on.rectangle").frame(height: overlayHeight)
            Image(systemName: "wand.and.stars").frame(height: gradeHeight)
            Image(systemName: "film").frame(height: videoHeight)
            laneMute(Project.clipSoundLane, icon: "speaker.wave.2", name: "the videos' own sound")
                .frame(height: audioHeight)
            ForEach(0..<audioLanes, id: \.self) { i in
                laneMute(Project.audioLane(i), icon: "music.note", name: "this audio lane")
                    .frame(height: musicHeight)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Ink.secondary)
        .frame(width: gutter)
    }

    /// A lane's speaker button: click to switch that lane's sound off (shown crossed out) or back on.
    private func laneMute(_ lane: String, icon: String, name: String) -> some View {
        let off = model.project.mutedLanes.contains(lane)
        return Button { model.toggleLaneMute(lane) } label: {
            Image(systemName: off ? "speaker.slash.fill" : icon)
                .foregroundStyle(off ? Color.red.opacity(0.85) : Ink.secondary)
                .frame(width: gutter - 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(off ? "Turn \(name) back on" : "Mute \(name)")
    }

    // MARK: Content

    private func content(pps: CGFloat) -> some View {
        let starts = model.project.starts
        let titleTop = rulerHeight + 6
        let captionTop = titleTop + titleHeight + gap
        let overlayTop = captionTop + titleHeight + gap
        let laneTop = overlayTop + overlayHeight + gap
        let playheadX = CGFloat(clock.time) * pps
        return ZStack(alignment: .topLeading) {
            Ruler(duration: model.project.duration, pps: pps, height: rulerHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = Double(max(0, v.location.x) / pps)
                        model.seek(to: snapped(t, pps: pps, excluding: nil, playhead: false))
                    }
                    .onEnded { _ in snapGuide = nil })

            // Markers
            ForEach(model.project.markers) { m in
                MarkerFlag(name: m.name)
                    .offset(x: CGFloat(m.time) * pps - 5, y: 1)
                    .onTapGesture { model.seek(to: m.time) }
                    .help(m.name)
                    .contextMenu {
                        Button("Rename…") {
                            if let name = Panels.askName(title: "Rename Marker", current: m.name) { model.updateMarker(m.id) { $0.name = name } }
                        }
                        Button("Delete Marker", role: .destructive) { model.removeMarker(m.id) }
                    }
            }

            // Titles lane
            ForEach(model.project.titles) { item in
                titleBlock(item, pps: pps)
                    .offset(y: item.isCaption ? captionTop : titleTop)
            }

            // Overlay lane (B-roll, picture-in-picture)
            ForEach(model.project.overlays) { item in
                overlayBlock(item, pps: pps)
                    .offset(y: overlayTop)
            }

            // Grade lane
            ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { i, clip in
                GradeSegment(clip: clip, grading: model.gradingClipID == clip.id, selected: model.selectedIDs.contains(clip.id))
                    .frame(width: max(1, CGFloat(clip.duration) * pps - 2), height: gradeHeight)
                    .offset(x: clipX(clip, pps: pps) + 1, y: laneTop)
                    .onTapGesture(coordinateSpace: .named("timeline")) { loc in tap(clip.id, at: loc, pps: pps) }
            }

            // Video lane
            ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { i, clip in
                videoBlock(clip, x: clipX(clip, pps: pps), pps: pps)
                    .offset(y: laneTop + gradeHeight + gap)
                    .zIndex(dragID == clip.id ? 2 : 0)
            }

            // Transitions: a diamond at every cut (filled when there's one). The start and end fades are
            // the fade lines on the first and last clips.
            ForEach(Array(model.project.clips.enumerated()).filter { $0.offset > 0 }, id: \.element.id) { i, clip in
                let o = model.project.overlap(at: i)
                transitionBadge(clip, index: i)
                    .position(x: (CGFloat(starts[i]) + CGFloat(o) / 2) * pps, y: laneTop + gradeHeight + gap + videoHeight / 2)
                    .opacity(dragID == nil ? 1 : 0)
            }

            // Clip sound lane
            ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { i, clip in
                let w = max(1, CGFloat(clip.duration) * pps - 2)
                ClipSound(clip: clip, peaks: soundPeaks(clip))
                    .frame(width: w, height: audioHeight)
                    .overlay {
                        if !clip.isPhoto {
                            fadeLines(key: "sound-\(clip.id)", width: w, height: audioHeight, pps: pps,
                                      fadeIn: clip.audioFadeIn, fadeOut: clip.audioFadeOut, limit: min(5, clip.duration / 2),
                                      hint: "sound",
                                      setIn: { v in model.updateClip(clip.id, undo: .none) { $0.audioFadeIn = v } },
                                      setOut: { v in model.updateClip(clip.id, undo: .none) { $0.audioFadeOut = v } })
                        }
                    }
                    .onHover { hoverKey = $0 ? "sound-\(clip.id)" : (hoverKey == "sound-\(clip.id)" ? nil : hoverKey) }
                    .offset(x: clipX(clip, pps: pps) + 1, y: laneTop + gradeHeight + videoHeight + gap * 2)
                    .onTapGesture(coordinateSpace: .named("timeline")) { loc in tap(clip.id, at: loc, pps: pps) }
            }

            // Music lane
            ForEach(model.project.music) { item in
                musicBlock(item, pps: pps)
                    .offset(y: laneTop + gradeHeight + videoHeight + audioHeight + gap * 3 + CGFloat(item.lane) * (musicHeight + gap))
            }

            // Snap guide
            if let g = snapGuide {
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 1, height: titleTop + lanesHeight)
                    .offset(x: CGFloat(g) * pps - 0.5)
                    .allowsHitTesting(false)
            }

            // Playhead
            Rectangle()
                .fill(.white)
                .frame(width: 1.5, height: titleTop + lanesHeight)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(x: playheadX - 0.75)
                .allowsHitTesting(false)
            PlayheadCap()
                .fill(.white)
                .frame(width: 12, height: 10)
                .offset(x: playheadX - 6, y: rulerHeight - 10)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: "timeline")
        .pointerStyle(model.bladeMode ? .image(Image(systemName: "scissors"), hotSpot: .center) : nil)
        // Files dragged from the media bin or Finder land where they're dropped.
        .dropDestination(for: URL.self) { urls, location in
            let t = max(0, Double(location.x / pps))
            let lane: EditorModel.DropLane
            if location.y >= overlayTop - gap && location.y < laneTop { lane = .overlay }
            else if location.y >= laneTop + gradeHeight + videoHeight + audioHeight + gap * 3 { lane = .audio }
            else { lane = .main }
            let snappedT = lane == .main ? nearestCut(t) : t
            model.place(urls, atTime: snappedT, lane: lane)
            return true
        }
    }

    /// Clips drop between clips: the nearest cut to where they were let go.
    private func nearestCut(_ t: Double) -> Double {
        let cuts = model.project.starts + [model.project.duration]
        return cuts.min { abs($0 - t) < abs($1 - t) } ?? t
    }

    /// A click on any block: blade cuts there; ⌘- or ⇧-click adds to the selection; a plain click selects.
    private func tap(_ id: UUID, at location: CGPoint, pps: CGFloat) {
        if model.bladeMode {
            let t = snapped(Double(location.x / pps), pps: pps, excluding: nil)
            if model.project.clips.contains(where: { $0.id == id }) { model.blade(at: t) }
            else if model.project.overlays.contains(where: { $0.id == id }) { model.bladeOverlay(id, at: t) }
            snapGuide = nil
            return
        }
        let flags = NSEvent.modifierFlags
        model.select(id, adding: flags.contains(.command) || flags.contains(.shift))
    }

    /// Where a clip is drawn. While rearranging, the dragged clip follows the pointer and the
    /// others are laid out as if it were already at `dragTarget`, which opens a gap there.
    private func clipX(_ clip: ClipItem, pps: CGFloat) -> CGFloat {
        let p = model.project
        guard let id = dragID else { return CGFloat(p.start(of: clip.id) ?? 0) * pps }
        if clip.id == id { return CGFloat(p.start(of: id) ?? 0) * pps + dragDX }
        return CGFloat(p.previewStarts(moving: id, to: dragTarget)[clip.id] ?? 0) * pps
    }

    /// The slot the dragged clip would land in, from where its middle is now.
    private func landingIndex(for id: UUID, dx: CGFloat, pps: CGFloat) -> Int {
        let p = model.project
        guard let i = p.index(of: id) else { return 0 }
        let center = p.starts[i] + p.clips[i].duration / 2 + Double(dx / pps)
        return p.landingIndex(moving: id, center: center)
    }

    private func soundPeaks(_ clip: ClipItem) -> [Float] {
        guard let full = model.waveforms[clip.url] else { return [] }
        return Waveform.slice(full, duration: model.clipSourceDuration(clip), start: clip.sourceStart, end: clip.sourceEnd)
    }

    // MARK: Video clips

    private func videoBlock(_ clip: ClipItem, x: CGFloat, pps: CGFloat) -> some View {
        let width = max(1, CGFloat(clip.duration) * pps - 2)
        let selected = model.selectedIDs.contains(clip.id)
        let isFirst = model.project.clips.first?.id == clip.id
        let isLast = model.project.clips.last?.id == clip.id
        let fromBlack = isFirst ? (clip.transitionIn?.duration ?? 0) : 0
        return ZStack(alignment: .topLeading) {
            ClipFilmstrip(images: model.clipThumbs[clip.id] ?? [], aspect: model.renderSize.width / max(1, model.renderSize.height))
            ClipLabel(clip: clip)
                .padding(.vertical, 5)
                // Start the name after the fade-in so its handle stays clear.
                .padding(.leading, isFirst && fromBlack > 0 ? min(width / 2, CGFloat(fromBlack) * pps + 10) : 5)
            if selected {
                HStack {
                    trimHandle(clip, leading: true, pps: pps)
                    Spacer(minLength: 0)
                    trimHandle(clip, leading: false, pps: pps)
                }
            }
            // Fade handles go on top of the name and the trim handles.
            if (isFirst || isLast) && dragID == nil {
                fadeLines(key: "video-\(clip.id)", width: width, height: videoHeight, pps: pps,
                          fadeIn: fromBlack, fadeOut: isLast ? model.project.fadeOut : 0, limit: min(5, clip.duration / 2),
                          hint: "picture", showIn: isFirst, showOut: isLast,
                          setIn: { v in model.updateClip(clip.id, undo: .none) { $0.transitionIn = v > 0.04 ? Transition(kind: .dipToBlack, duration: v) : nil } },
                          setOut: { v in model.mutate(.none) { $0.fadeOut = v > 0.04 ? v : 0 } })
            }
        }
        .frame(width: width, height: videoHeight)
        .demoAnchor("clip-\(clip.id)")
        .clipShape(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1)
        )
        .onHover { hoverKey = $0 ? "video-\(clip.id)" : (hoverKey == "video-\(clip.id)" ? nil : hoverKey) }
        .scaleEffect(dragID == clip.id ? 1.03 : 1)
        .shadow(color: .black.opacity(dragID == clip.id ? 0.7 : 0), radius: 10, y: 6)
        .offset(x: x + 1)
        .onTapGesture(coordinateSpace: .named("timeline")) { loc in tap(clip.id, at: loc, pps: pps) }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("timeline"))
            .updating($clipDragActive) { _, active, _ in active = true }
            .onChanged { v in
                if dragID != clip.id {
                    model.selection = clip.id
                    dragTarget = model.project.index(of: clip.id) ?? 0
                    withAnimation(.easeOut(duration: 0.12)) { dragID = clip.id }
                }
                dragDX = v.translation.width
                let target = landingIndex(for: clip.id, dx: v.translation.width, pps: pps)
                if target != dragTarget {
                    // Neighbours slide aside to open the gap; a light tick on trackpads.
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { dragTarget = target }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { _ in
                let target = dragTarget
                let from = model.project.index(of: clip.id)
                // The clip glides from the pointer into its slot.
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                    if let from, target != from { model.moveClip(clip.id, to: target) }
                    dragID = nil
                    dragDX = 0
                }
            })
        .contextMenu { clipMenu(clip) }
    }

    private func trimHandle(_ clip: ClipItem, leading: Bool, pps: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 7)
            .overlay(Capsule().fill(Color.black.opacity(0.35)).frame(width: 1.5, height: 18))
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($trimDragActive) { _, active, _ in active = true }
                .onChanged { v in
                    if trimOrigin == nil {
                        trimOrigin = (clip.sourceStart, clip.sourceEnd)
                        model.beginInteraction()
                    }
                    guard let o = trimOrigin, let clipStart = model.project.start(of: clip.id) else { return }
                    // Work in timeline time so the moving edge can snap to the playhead and other edges.
                    if leading {
                        let t = clipStart + Double(v.translation.width / pps)
                        let s = snapped(t, pps: pps, excluding: nil)
                        model.trimClip(clip.id, start: o.start + (s - clipStart) * clip.speed)
                    } else {
                        let t = clipStart + (o.end - o.start) / clip.speed + Double(v.translation.width / pps)
                        let s = snapped(t, pps: pps, excluding: nil)
                        model.trimClip(clip.id, end: o.start + (s - clipStart) * clip.speed)
                    }
                }
                .onEnded { _ in
                    trimOrigin = nil
                    snapGuide = nil
                    model.endInteraction()
                })
    }

    @ViewBuilder
    private func clipMenu(_ clip: ClipItem) -> some View {
        Button("Split at Playhead") { model.splitAtPlayhead() }
        Button("Duplicate") { model.selection = clip.id; model.duplicateSelection() }
        Menu("Speed") {
            ForEach(ClipItem.speeds, id: \.self) { s in
                Button { model.setSpeed(s, for: clip.id) } label: {
                    if abs(clip.speed - s) < 0.001 { Label(Self.speedLabel(s), systemImage: "checkmark") } else { Text(Self.speedLabel(s)) }
                }
            }
        }
        Button(clip.audioMuted ? "Unmute Clip Audio" : "Mute Clip Audio") { model.toggleClipAudio(clip.id) }
        if !clip.isPhoto {
            Menu("Clean Up Sound") {
                Button("Normalize Loudness") { model.processClipAudio(clip.id, reduceNoise: false) }
                Button("Reduce Background Noise") { model.processClipAudio(clip.id, reduceNoise: true) }
                    .disabled(clip.reversed)
                if clip.audioOverride != nil && !clip.reversed { Button("Use Original Sound") { model.resetAudio(clip.id) } }
            }
            Button("Freeze Frame at Playhead") { model.freezeFrame() }
            Button(clip.reversed ? "Play Forwards" : "Reverse") { model.toggleReverse(clip.id) }
        }
        Divider()
        Button("Copy") { model.select(clip.id, adding: model.selectedIDs.contains(clip.id)); model.copySelection() }
        Button("Delete", role: .destructive) {
            if !model.selectedIDs.contains(clip.id) { model.selection = clip.id }
            model.deleteSelection()
        }
    }

    static func speedLabel(_ s: Double) -> String {
        switch s {
        case 0.25: return "¼×"
        case 0.5: return "½×"
        case 1.5: return "1½×"
        default: return s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
        }
    }

    // MARK: Fade lines

    /// Fades drawn on a block: the faded corner is shaded and a line runs from silence/black up to full.
    /// A dot at the top of each line (shown on hover, or whenever there's a fade) drags it longer or shorter.
    @ViewBuilder
    private func fadeLines(key: String, width: CGFloat, height: CGFloat, pps: CGFloat, fadeIn: Double, fadeOut: Double,
                           limit: Double, hint: String, showIn: Bool = true, showOut: Bool = true,
                           setIn: @escaping (Double) -> Void, setOut: @escaping (Double) -> Void) -> some View {
        let fi = min(CGFloat(fadeIn) * pps, width / 2), fo = min(CGFloat(fadeOut) * pps, width / 2)
        let active = hoverKey == key || fadeOrigin?.key.hasPrefix(key) == true
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let h = size.height, w = size.width
                // Each fade is a curve that rises from the bottom corner and eases into the top.
                if showIn && fi > 0.5 {
                    let bottom = CGPoint(x: 0, y: h), top = CGPoint(x: fi, y: 0), control = CGPoint(x: fi * 0.45, y: 0)
                    var shade = Path()
                    shade.move(to: .zero); shade.addLine(to: top); shade.addQuadCurve(to: bottom, control: control); shade.closeSubpath()
                    ctx.fill(shade, with: .color(.black.opacity(0.5)))
                    var line = Path()
                    line.move(to: bottom); line.addQuadCurve(to: top, control: control)
                    ctx.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                }
                if showOut && fo > 0.5 {
                    let bottom = CGPoint(x: w, y: h), top = CGPoint(x: w - fo, y: 0), control = CGPoint(x: w - fo * 0.45, y: 0)
                    var shade = Path()
                    shade.move(to: CGPoint(x: w, y: 0)); shade.addLine(to: top); shade.addQuadCurve(to: bottom, control: control); shade.closeSubpath()
                    ctx.fill(shade, with: .color(.black.opacity(0.5)))
                    var line = Path()
                    line.move(to: top); line.addQuadCurve(to: bottom, control: control)
                    ctx.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                }
            }
            .allowsHitTesting(false)
            // Dots sit at least 16 pt in from the edge, clear of the trim handles.
            if showIn && (active || fi > 0.5) && width > 40 {
                fadeDot(key: key + "-in", x: max(16, fi), value: fadeIn, limit: limit, pps: pps, sign: 1, set: setIn,
                        help: "Drag to fade the \(hint) in")
            }
            if showOut && (active || fo > 0.5) && width > 40 {
                fadeDot(key: key + "-out", x: min(width - 16, width - fo), value: fadeOut, limit: limit, pps: pps, sign: -1, set: setOut,
                        help: "Drag to fade the \(hint) out")
            }
        }
        .frame(width: width, height: height)
    }

    private func fadeDot(key: String, x: CGFloat, value: Double, limit: Double, pps: CGFloat, sign: Double,
                         set: @escaping (Double) -> Void, help: String) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .padding(5)
            .contentShape(Circle())
            .position(x: x, y: 6)
            .pointerStyle(.columnResize)
            .help(help)
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($fadeDragActive) { _, active, _ in active = true }
                .onChanged { v in
                    if fadeOrigin?.key != key { fadeOrigin = (key, value); model.beginInteraction() }
                    guard let o = fadeOrigin else { return }
                    let d = o.value + sign * Double(v.translation.width / pps)
                    set(min(max(0, (d * 10).rounded() / 10), limit))   // tenths of a second
                }
                .onEnded { _ in fadeOrigin = nil; model.endInteraction() })
    }

    // MARK: Transitions

    private func transitionBadge(_ clip: ClipItem, index: Int) -> some View {
        let has = clip.transitionIn != nil
        return Button { transitionEditor = clip.id } label: {
            Image(systemName: index == 0 ? (has ? "circle.righthalf.filled" : "circle.dashed") : (has ? "diamond.fill" : "diamond"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(has ? Color.white : Ink.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .help(index == 0 ? "Fade in from black" : (clip.transitionIn.map { $0.kind.label } ?? "Add a transition"))
        .popover(isPresented: Binding(get: { transitionEditor == clip.id }, set: { if !$0 { transitionEditor = nil } })) {
            TransitionEditor(clipID: clip.id, isFirst: index == 0).environmentObject(model)
        }
    }

    // MARK: Overlays

    private func overlayBlock(_ item: OverlayItem, pps: CGFloat) -> some View {
        let selected = model.selectedIDs.contains(item.id)
        let width = max(8, CGFloat(item.clip.duration) * pps)
        return ZStack(alignment: .topLeading) {
            ClipFilmstrip(images: model.clipThumbs[item.id] ?? [], aspect: model.renderSize.width / max(1, model.renderSize.height))
                .opacity(0.9)
            HStack(spacing: 4) {
                Image(systemName: item.clip.transform.scale < 0.95 ? "pip" : "rectangle.on.rectangle").font(.system(size: 9, weight: .bold))
                Text(item.clip.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .padding(4)
            if selected {
                HStack {
                    overlayTrimHandle(item, leading: true, pps: pps)
                    Spacer(minLength: 0)
                    overlayTrimHandle(item, leading: false, pps: pps)
                }
            }
        }
        .frame(width: width, height: overlayHeight)
        .clipShape(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous)
            .strokeBorder(selected ? Color.white : TrackColor.overlay, lineWidth: selected ? 2 : 1.5))
        .offset(x: CGFloat(item.start) * pps)
        .onTapGesture(coordinateSpace: .named("timeline")) { loc in tap(item.id, at: loc, pps: pps) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
            .updating($overlayDragActive) { _, active, _ in active = true }
            .onChanged { v in
                if overlayOrigin == nil { overlayOrigin = item; model.beginInteraction(); model.selection = item.id }
                guard let o = overlayOrigin else { return }
                let start = snappedMove(o.start + Double(v.translation.width / pps), length: o.clip.duration, pps: pps, excluding: item.id)
                model.updateOverlay(item.id, undo: .none) { $0.start = start }
            }
            .onEnded { _ in overlayOrigin = nil; snapGuide = nil; model.endInteraction() })
        .contextMenu {
            Button("Full Frame") { model.updateClip(item.id, undo: .push) { $0.transform = .identity; $0.keyframes = [] } }
            Button("Picture in Picture") { model.updateClip(item.id, undo: .push) { $0.transform = EditorModel.pipTransform; $0.keyframes = [] } }
            Button(item.clip.audioMuted ? "Turn Sound On" : "Turn Sound Off") { model.updateClip(item.id, undo: .push) { $0.audioMuted.toggle() } }
            Divider()
            Button("Delete", role: .destructive) { model.selection = item.id; model.deleteSelection() }
        }
    }

    private func overlayTrimHandle(_ item: OverlayItem, leading: Bool, pps: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 6)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($overlayDragActive) { _, active, _ in active = true }
                .onChanged { v in
                    if overlayOrigin == nil { overlayOrigin = item; model.beginInteraction() }
                    guard let o = overlayOrigin else { return }
                    let c = o.clip
                    if leading {
                        let t = snapped(o.start + Double(v.translation.width / pps), pps: pps, excluding: item.id)
                        model.trimClip(item.id, start: c.sourceStart + (t - o.start) * c.speed)
                    } else {
                        let t = snapped(o.end + Double(v.translation.width / pps), pps: pps, excluding: item.id)
                        model.trimClip(item.id, end: c.sourceStart + (t - o.start) * c.speed)
                    }
                }
                .onEnded { _ in overlayOrigin = nil; snapGuide = nil; model.endInteraction() })
    }

    // MARK: Music

    private func musicBlock(_ item: MusicItem, pps: CGFloat) -> some View {
        let selected = model.selectedIDs.contains(item.id)
        let full = model.waveforms[item.playURL] ?? []
        let peaks = Waveform.slice(full, duration: model.musicSourceDuration(item), start: item.sourceStart, end: item.sourceEnd)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous).fill(TrackColor.audio(item.kind))
            WaveformBars(peaks: peaks).padding(.horizontal, 6).padding(.vertical, 5)
            if !item.beats.isEmpty {
                BeatTicks(times: item.beats.filter { $0 >= item.sourceStart && $0 <= item.sourceEnd }.map { $0 - item.sourceStart }, pps: pps)
            }
            if model.audioJobs.contains(item.id) {
                ProgressView().controlSize(.mini).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8)
            }
            Label(item.name, systemImage: item.kind == .voiceover ? "mic.fill" : (item.kind == .effect ? "sparkles" : "music.note"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.25)))
                .padding(.leading, 6)
            if selected {
                HStack {
                    musicTrimHandle(item, leading: true, pps: pps)
                    Spacer(minLength: 0)
                    musicTrimHandle(item, leading: false, pps: pps)
                }
            }
            fadeLines(key: "music-\(item.id)", width: max(8, CGFloat(item.duration) * pps), height: musicHeight, pps: pps,
                      fadeIn: item.fadeIn, fadeOut: item.fadeOut, limit: min(10, item.duration / 2), hint: "sound",
                      setIn: { v in model.updateMusic(item.id, undo: .none) { $0.fadeIn = v } },
                      setOut: { v in model.updateMusic(item.id, undo: .none) { $0.fadeOut = v } })
        }
        .frame(width: max(8, CGFloat(item.duration) * pps), height: musicHeight)
        .demoAnchor("music-\(item.id)")
        .onHover { hoverKey = $0 ? "music-\(item.id)" : (hoverKey == "music-\(item.id)" ? nil : hoverKey) }
        .clipShape(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous)
            .strokeBorder(selected ? Color.white : .clear, lineWidth: 2))
        .offset(x: CGFloat(item.start) * pps)
        .onTapGesture(coordinateSpace: .named("timeline")) { loc in tap(item.id, at: loc, pps: pps) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
            .updating($musicDragActive) { _, active, _ in active = true }
            .onChanged { v in
                if musicOrigin == nil { musicOrigin = item; model.beginInteraction(); model.selection = item.id }
                guard let o = musicOrigin else { return }
                let start = snappedMove(o.start + Double(v.translation.width / pps), length: o.duration, pps: pps, excluding: item.id)
                // Dragging up or down moves it to another audio lane (one past the last makes a new lane).
                let lane = min(audioLanes, max(0, o.lane + Int((v.translation.height / (musicHeight + gap)).rounded())))
                model.updateMusic(item.id, undo: .none) { $0.start = start; $0.lane = lane }
            }
            .onEnded { _ in musicOrigin = nil; snapGuide = nil; model.endInteraction() })
        .contextMenu {
            Picker("Kind", selection: Binding(get: { item.kind }, set: { k in model.updateMusic(item.id, undo: .push) { $0.kind = k } })) {
                Text("Music").tag(MusicItem.Kind.music)
                Text("Voiceover").tag(MusicItem.Kind.voiceover)
                Text("Sound effect").tag(MusicItem.Kind.effect)
            }
            Button("Normalize Loudness") { model.normalize(item.id) }
            Button("Reduce Noise") { model.reduceNoise(musicID: item.id) }
            if item.processed != nil { Button("Use Original Sound") { model.resetAudio(item.id) } }
            Button(item.beats.isEmpty ? "Find the Beat (snap to it)" : "Find the Beat Again") { model.detectBeats(item.id) }
            Divider()
            Button("Delete", role: .destructive) { model.selection = item.id; model.deleteSelection() }
        }
    }

    private func musicTrimHandle(_ item: MusicItem, leading: Bool, pps: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 7)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($musicDragActive) { _, active, _ in active = true }
                .onChanged { v in
                    if musicOrigin == nil { musicOrigin = item; model.beginInteraction() }
                    guard let o = musicOrigin else { return }
                    let d = Double(v.translation.width / pps)
                    let full = model.musicSourceDuration(o)
                    let edge = snapped((leading ? o.start : o.end) + d, pps: pps, excluding: item.id) - (leading ? o.start : o.end)
                    model.updateMusic(item.id, undo: .none) { m in
                        if leading {
                            let newSourceStart = min(max(0, o.sourceStart + edge), o.sourceEnd - 0.5)
                            m.sourceStart = newSourceStart
                            m.start = max(0, o.start + (newSourceStart - o.sourceStart))
                        } else {
                            m.sourceEnd = max(min(full, o.sourceEnd + edge), o.sourceStart + 0.5)
                        }
                    }
                }
                .onEnded { _ in musicOrigin = nil; snapGuide = nil; model.endInteraction() })
    }

    // MARK: Titles

    private func titleBlock(_ item: TitleItem, pps: CGFloat) -> some View {
        let selected = model.selectedIDs.contains(item.id)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous).fill(item.isCaption ? TrackColor.caption : TrackColor.title)
            HStack(spacing: 5) {
                Image(systemName: item.isCaption ? "captions.bubble" : "textformat").font(.system(size: 10, weight: .semibold))
                Text(item.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            if selected {
                HStack {
                    titleTrimHandle(item, leading: true, pps: pps)
                    Spacer(minLength: 0)
                    titleTrimHandle(item, leading: false, pps: pps)
                }
            }
        }
        .frame(width: max(8, CGFloat(item.duration) * pps), height: titleHeight)
        .clipShape(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous)
            .strokeBorder(selected ? Color.white : .clear, lineWidth: 2))
        .offset(x: CGFloat(item.start) * pps)
        .onTapGesture(coordinateSpace: .named("timeline")) { loc in tap(item.id, at: loc, pps: pps) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
            .updating($titleDragActive) { _, active, _ in active = true }
            .onChanged { v in
                if titleOrigin == nil { titleOrigin = item; model.beginInteraction(); model.selection = item.id }
                guard let o = titleOrigin else { return }
                let start = snappedMove(o.start + Double(v.translation.width / pps), length: o.duration, pps: pps, excluding: item.id)
                model.updateTitle(item.id, undo: .none) { $0.start = start }
            }
            .onEnded { _ in titleOrigin = nil; snapGuide = nil; model.endInteraction() })
        .contextMenu {
            Menu("Style") {
                ForEach(TitleItem.Style.allCases) { style in
                    Button(style.label) { model.updateTitle(item.id, undo: .push) { $0.style = style } }
                }
            }
            Button("Delete", role: .destructive) { model.selection = item.id; model.deleteSelection() }
        }
    }

    private func titleTrimHandle(_ item: TitleItem, leading: Bool, pps: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 6)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($titleDragActive) { _, active, _ in active = true }
                .onChanged { v in
                    if titleOrigin == nil { titleOrigin = item; model.beginInteraction() }
                    guard let o = titleOrigin else { return }
                    let edge = snapped((leading ? o.start : o.end) + Double(v.translation.width / pps), pps: pps, excluding: item.id)
                    model.updateTitle(item.id, undo: .none) { t in
                        if leading {
                            let start = min(max(0, edge), o.end - TitleItem.minLength)
                            t.start = start
                            t.duration = o.end - start
                        } else {
                            t.duration = max(TitleItem.minLength, edge - o.start)
                        }
                    }
                }
                .onEnded { _ in titleOrigin = nil; snapGuide = nil; model.endInteraction() })
    }

    // MARK: Snapping

    /// Snaps a time to the playhead and to clip/title/song edges within 8 points, and shows the guide.
    private func snapped(_ t: Double, pps: CGFloat, excluding id: UUID?, playhead: Bool = true) -> Double {
        guard model.snapping else { snapGuide = nil; return t }
        var targets = model.project.edges(excluding: id)
        if playhead { targets.append(clock.time) }
        let r = Snap.apply(t, to: targets, tolerance: Double(8 / pps))
        snapGuide = r.target
        return max(0, r.time)
    }

    /// Snaps a moving item by whichever of its two ends is closer to a target.
    private func snappedMove(_ start: Double, length: Double, pps: CGFloat, excluding id: UUID) -> Double {
        let start = max(0, start)
        guard model.snapping else { snapGuide = nil; return start }
        let targets = model.project.edges(excluding: id) + [clock.time]
        let tolerance = Double(8 / pps)
        let a = Snap.apply(start, to: targets, tolerance: tolerance)
        let b = Snap.apply(start + length, to: targets, tolerance: tolerance)
        let da = a.target.map { abs($0 - start) } ?? .infinity
        let db = b.target.map { abs($0 - start - length) } ?? .infinity
        if da <= db, a.target != nil { snapGuide = a.target; return a.time }
        if let t = b.target { snapGuide = t; return max(0, t - length) }
        snapGuide = nil
        return start
    }

    /// HH:MM:SS:FF
    /// 0:12.4 (or 1:02:03.4 past an hour); totals without the tenth.
    private func timecode(_ s: Double, tenths: Bool = true) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = tenths ? (s * 10).rounded(.down) / 10 : s.rounded()
        let whole = Int(t)
        let base = whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
                                 : String(format: "%d:%02d", whole / 60, whole % 60)
        return tenths ? base + String(format: ".%d", Int(((t - Double(whole)) * 10).rounded())) : base
    }
}

extension Notification.Name {
    static let timelineZoom = Notification.Name("eddie.timelineZoom")
}

/// Track colors: periwinkle grade, pink clip sound, orange music.
enum TrackColor {
    static let grade = Color(red: 0.42, green: 0.42, blue: 0.95)
    static let audio = Color(red: 0.86, green: 0.40, blue: 0.90)
    static let music = Color(red: 0.93, green: 0.52, blue: 0.25)
    static let title = Color(red: 0.20, green: 0.66, blue: 0.60)
    static let caption = Color(red: 0.30, green: 0.50, blue: 0.62)
    static let overlay = Color(red: 0.95, green: 0.78, blue: 0.30)
    static let voiceover = Color(red: 0.25, green: 0.55, blue: 0.85)
    static let effect = Color(red: 0.62, green: 0.42, blue: 0.86)
    static func audio(_ kind: MusicItem.Kind) -> Color {
        switch kind {
        case .music: return music
        case .voiceover: return voiceover
        case .effect: return effect
        }
    }
    static let empty = Color.white.opacity(0.07)
    /// Same corner radius on every track so they read as one family.
    static let radius: CGFloat = 7
}

// MARK: - Pieces

private struct Ruler: View {
    let duration: Double
    let pps: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { ctx, size in
            // Pick a label step that leaves at least ~70 pt between labels.
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { CGFloat($0) * pps >= 70 } ?? 600
            let minor = step / 5
            var t = 0.0
            while CGFloat(t) * pps <= size.width {
                let x = CGFloat(t) * pps
                let major = abs(t / step - (t / step).rounded()) < 0.001
                let h: CGFloat = major ? 8 : 4
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                         with: .color(.white.opacity(major ? 0.35 : 0.15)))
                if major {
                    let s = Int(t.rounded())
                    let label = step < 1 ? String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                                         : String(format: "%d:%02d", s / 60, s % 60)
                    ctx.draw(Text(label).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.45)),
                             at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
                t += minor
            }
        }
        .frame(height: height)
    }
}

private struct PlayheadCap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The clip's AI grade: purple when graded, sliding stripes while the AI works on it.
private struct GradeSegment: View {
    let clip: ClipItem
    let grading: Bool
    let selected: Bool

    var body: some View {
        let graded = !clip.recipe.isNeutral
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous)
                .fill(graded ? TrackColor.grade.opacity(selected ? 1 : 0.8) : TrackColor.empty)
            if grading {
                MovingStripes(color: graded ? .white.opacity(0.18) : TrackColor.grade.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous))
            }
            HStack(spacing: 5) {
                Image(systemName: graded ? "sparkles" : "circle.dashed").font(.system(size: 10, weight: .semibold))
                Text(graded ? clip.effectiveRecipe.summary : (grading ? "Grading…" : "No grade"))
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(graded ? .white : Ink.tertiary)
            .padding(.horizontal, 7)
        }
        .clipped()
    }
}

/// Slanted bars sliding sideways — the "working" pattern.
struct MovingStripes: View {
    var color: Color
    var stripe: CGFloat = 8
    var speed: Double = 40   // points per second

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            Canvas { ctx, size in
                let period = stripe * 2
                let shift = CGFloat(context.date.timeIntervalSinceReferenceDate * speed).truncatingRemainder(dividingBy: period)
                var x = -size.height - period + shift
                while x < size.width + size.height {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    p.addLine(to: CGPoint(x: x + size.height + stripe, y: 0))
                    p.addLine(to: CGPoint(x: x + stripe, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(color))
                    x += period
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Thumbnails tiled across a clip.
private struct ClipFilmstrip: View {
    let images: [CGImage]
    let aspect: CGFloat

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if images.isEmpty {
                    TrackColor.empty
                } else {
                    let cells = max(1, Int((geo.size.width / (geo.size.height * aspect)).rounded(.up)))
                    ForEach(0..<cells, id: \.self) { i in
                        let img = images[min(images.count - 1, i * images.count / cells)]
                        Color.clear
                            .overlay(Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill))
                            .clipped()
                    }
                }
            }
        }
    }
}

private struct ClipLabel: View {
    let clip: ClipItem

    var body: some View {
        HStack(spacing: 4) {
            if clip.isPhoto { Image(systemName: "photo").font(.system(size: 9)) }
            if !clip.keyframes.isEmpty { Image(systemName: "diamond.fill").font(.system(size: 7)) }
            if clip.speed != 1 {
                Text(TimelineView.speedLabel(clip.speed)).font(.system(size: 10, weight: .bold).monospacedDigit())
            }
            if clip.audioMuted { Image(systemName: "speaker.slash.fill").font(.system(size: 9)) }
            Text(clip.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }
}

private struct ClipSound: View {
    let clip: ClipItem
    let peaks: [Float]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TrackColor.radius, style: .continuous)
                .fill(TrackColor.audio.opacity(clip.audioMuted ? 0.25 : 0.9))
            WaveformBars(peaks: peaks).padding(.horizontal, 4).padding(.vertical, 4)
        }
    }
}

private struct WaveformBars: View {
    let peaks: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let barW: CGFloat = 2, gap: CGFloat = 1.5
            let bars = Int(size.width / (barW + gap))
            guard bars > 0 else { return }
            for b in 0..<bars {
                let p = CGFloat(peaks[min(peaks.count - 1, b * peaks.count / bars)])
                let h = max(1.5, p * size.height)
                let rect = CGRect(x: CGFloat(b) * (barW + gap), y: (size.height - h) / 2, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.55)))
            }
        }
    }
}

/// A marker on the ruler.
struct MarkerFlag: View {
    let name: String
    var body: some View {
        Image(systemName: "flag.fill")
            .font(.system(size: 9))
            .foregroundStyle(Color.yellow)
            .frame(width: 10, height: 12)
            .contentShape(Rectangle())
    }
}

/// Little ticks on a song at each beat.
struct BeatTicks: View {
    let times: [Double]
    let pps: CGFloat
    var body: some View {
        Canvas { ctx, size in
            for t in times {
                let x = CGFloat(t) * pps
                guard x < size.width else { break }
                ctx.fill(Path(CGRect(x: x - 0.5, y: size.height - 6, width: 1, height: 6)), with: .color(.white.opacity(0.7)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Record a voiceover: red while recording, with a level meter.
struct RecordButton: View {
    @ObservedObject var recorder: VoiceRecorder
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(recorder.isRecording ? Color.red : Ink.primary)
                if recorder.isRecording {
                    Capsule().fill(Color.red.opacity(0.8))
                        .frame(width: 4 + CGFloat(min(1, recorder.level * 3)) * 26, height: 4)
                        .frame(width: 30, alignment: .leading)
                }
            }
            .frame(minWidth: 26, minHeight: 22)
        }
        .help(recorder.isRecording ? "Stop recording" : "Record a voiceover from the playhead")
    }
}
