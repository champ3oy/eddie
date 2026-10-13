import SwiftUI

/// Text tones for the black inspector (explicit, so they don't depend on vibrancy).
enum Ink {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.35)
    static let hairline = Color.white.opacity(0.08)
    static let well = Color.white.opacity(0.06)
}

/// Right-hand inspector: scope, AI, strength, then Light / Color controls.
struct InspectorView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let music = model.selectedMusic {
                        MusicSection(item: music)
                    } else if let title = model.selectedTitle {
                        TitleSection(item: title)
                    } else {
                        if let clip = model.selectedClip {
                            ClipSection(clip: clip)
                            ClipDetails(clip: clip)
                        } else {
                            ProjectSection()
                        }
                        HistogramView(scope: model.scope)
                        StrengthRow()
                        AdjustGroup(title: "Light", knobs: ["exposure", "contrast", "highlights", "shadows", "whites", "blacks"])
                        AdjustGroup(title: "Color", knobs: ["temperature", "tint", "vibrance", "saturation"])
                    }
                }
                .padding(14)
            }
            .scrollContentBackground(.hidden)
            // The AI chat is anchored to the bottom.
            ChatPanel()
                .background(
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.15))
                        .padding(.top, -24)
                        .allowsHitTesting(false)
                )
        }
        .background(Color.black)
        .disabled(!model.hasProject)
    }
}

// MARK: - Selected clip / song

struct ClipSection: View {
    @EnvironmentObject var model: EditorModel
    let clip: ClipItem

    var body: some View {
        GlassCard {
            HStack(spacing: 6) {
                Image(systemName: clip.isPhoto ? "photo" : "film").foregroundStyle(Ink.secondary)
                Text(clip.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Self.duration(clip.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Ink.tertiary)
            }
            if !clip.isPhoto {
                Row.segmented(ClipItem.speeds, selected: ClipItem.speeds.first { abs(clip.speed - $0) < 0.001 } ?? 1,
                              title: { TimelineView.speedLabel($0) }) { model.setSpeed($0) }
                    .help("Speed")
                HStack(spacing: 8) {
                    Button { model.toggleClipAudio(clip.id) } label: {
                        Image(systemName: clip.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(clip.audioMuted ? Color.red.opacity(0.85) : Ink.primary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glass(in: Circle(), interactive: true)
                    .help(clip.audioMuted ? "Unmute clip sound" : "Mute clip sound")
                    PillSlider(label: "Clip sound", value: clip.audioMuted ? "Off" : "\(Int((clip.volume * 100).rounded()))%",
                               amount: Binding(get: { clip.audioMuted ? 0 : clip.volume }, set: { model.setClipVolume($0, for: clip.id) }),
                               range: 0...1, reset: 1)
                }
            }
        }
    }

    static func duration(_ s: Double) -> String {
        String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

struct MusicSection: View {
    @EnvironmentObject var model: EditorModel
    let item: MusicItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassCard {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .voiceover ? "mic.fill" : (item.kind == .effect ? "sparkles" : "music.note"))
                        .foregroundStyle(TrackColor.audio(item.kind))
                    Text(item.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ClipSection.duration(item.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Ink.tertiary)
                }
                PillSlider(label: "Volume", value: "\(Int((item.volume * 100).rounded()))%", amount: binding(\.volume), range: 0...1, reset: 0.8)
                PillSlider(label: "Starts at", value: Self.clock(item.sourceStart),
                           amount: Binding(get: { item.sourceStart }, set: { model.setSongOffset(item.id, to: $0) }),
                           range: 0...max(1, model.musicSourceDuration(item) - 0.5), reset: 0)
                if let loud = model.loudStart(of: item), item.sourceStart < loud - 1 {
                    HStack(spacing: 8) {
                        Text("Starts quietly — loud at \(Self.clock(loud)).")
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        GlassPillButton(title: "Skip intro", icon: "forward.end") { model.setSongOffset(item.id, to: loud, undo: .push) }
                    }
                }
            }
            GlassCard(title: "Fades") {
                HStack(spacing: 8) {
                    PillSlider(label: "In", value: String(format: "%.1f s", item.fadeIn), amount: binding(\.fadeIn), range: 0...5, reset: 1)
                    PillSlider(label: "Out", value: String(format: "%.1f s", item.fadeOut), amount: binding(\.fadeOut), range: 0...8, reset: 2)
                }
            }
            GlassCard {
                Toggle(isOn: Binding(get: { model.project.duckUnderMusic }, set: { model.setDuckUnderMusic($0) })) {
                    Text("Lower clip sound while music plays").font(.system(size: 11.5)).foregroundStyle(Ink.primary)
                }
                .toggleStyle(.switch).controlSize(.mini)
            }
            GlassPillButton(title: "Remove", icon: "trash") { model.deleteSelection() }
        }
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func binding(_ key: WritableKeyPath<MusicItem, Double>) -> Binding<Double> {
        Binding(get: { item[keyPath: key] }, set: { v in model.updateMusic(item.id) { $0[keyPath: key] = v } })
    }

    private func row<C: View>(_ label: String, value: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.primary).frame(width: 64, alignment: .leading)
            control()
            Text(value).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Ink.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct TitleSection: View {
    @EnvironmentObject var model: EditorModel
    let item: TitleItem
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassCard {
            HStack(spacing: 6) {
                Image(systemName: item.isCaption ? "captions.bubble" : "textformat").foregroundStyle(item.isCaption ? TrackColor.caption : TrackColor.title)
                Text(item.isCaption ? "Caption" : "Title").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                Spacer()
                Text(String(format: "%.1f s", item.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Ink.tertiary)
            }

            TextField("Text", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($editing)
                .demoAnchor("title-text")
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
                .onChange(of: text) { if text != item.text { model.updateTitle(item.id) { $0.text = text } } }

            Row.segmented(TitleItem.Style.allCases, selected: item.style, title: { $0.label }) { style in
                model.updateTitle(item.id, undo: .push) { t in
                    t.style = style; t.weight = nil; t.plate = nil; t.align = nil; t.x = nil; t.y = nil
                }
            }
            }

            GlassCard(title: "Look") {
            // Font family
            PillMenu(label: "Font", value: item.font) {
                ForEach(TitleRenderer.systemFamilies, id: \.self) { f in fontButton(f) }
                Divider()
                ForEach(Self.popularFonts, id: \.self) { f in fontButton(f) }
                Divider()
                Menu("All Fonts") {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { f in fontButton(f) }
                }
            }
            .demoAnchor("title-font")

            // Weight
            Row.segmented(TitleItem.Weight.allCases, selected: item.resolvedWeight, title: { $0.label }) { w in
                model.updateTitle(item.id, undo: .push) { $0.weight = w }
            }

            // Italic · alignment · color · plate
            HStack(spacing: 6) {
                toggleButton("italic", on: item.italic, help: "Italic") {
                    model.updateTitle(item.id, undo: .push) { $0.italic.toggle() }
                }
                ForEach(TitleItem.Align.allCases) { a in
                    toggleButton("text.align\(a.rawValue)", on: item.resolvedAlign == a, help: "Align \(a.rawValue)") {
                        model.updateTitle(item.id, undo: .push) { $0.align = a }
                    }
                }
                toggleButton("rectangle.fill", on: item.resolvedPlate, help: "Background plate") {
                    model.updateTitle(item.id, undo: .push) { $0.plate = !item.resolvedPlate }
                }
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .demoAnchor("title-color")
                    .frame(width: 30)
                    .help("Text color")
                Spacer(minLength: 0)
            }

            }

            GlassCard(title: "Effects") {
                HStack(spacing: 8) {
                    PillSlider(label: "Outline", value: item.outline > 0 ? "\(Int((item.outline * 100).rounded()))" : "Off",
                               amount: Binding(get: { item.outline }, set: { v in model.updateTitle(item.id) { $0.outline = v < 0.005 ? 0 : v } }),
                               range: 0...0.25, reset: 0)
                    colorWell(\.outlineColor, help: "Outline color")
                }
                HStack(spacing: 8) {
                    PillSlider(label: "Glow", value: item.glow > 0 ? "\(Int((item.glow * 100).rounded()))%" : "Off",
                               amount: Binding(get: { item.glow }, set: { v in model.updateTitle(item.id) { $0.glow = v < 0.01 ? 0 : v } }),
                               range: 0...1, reset: 0)
                    colorWell(\.glowColor, help: "Glow color")
                }
                PillMenu(label: "Animation", value: item.animation.label) {
                    ForEach(TitleItem.Animation.allCases) { a in
                        Button(a.label) { model.updateTitle(item.id, undo: .push) { $0.animation = a } }
                    }
                }
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { item.wordHighlight }, set: { v in model.updateTitle(item.id, undo: .push) { $0.wordHighlight = v } })) {
                        Text("Highlight each word as it's said").font(.system(size: 11.5)).foregroundStyle(Ink.primary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    Spacer(minLength: 0)
                    colorWell(\.highlightColor, help: "Highlight color")
                }
                if item.isCaption {
                    GlassPillButton(title: "Apply this look to all captions", icon: "square.on.square") {
                        let look = item
                        model.mutate(.push) { p in
                            for i in p.titles.indices where p.titles[i].isCaption {
                                let keep = p.titles[i]
                                p.titles[i] = look
                                p.titles[i].id = keep.id; p.titles[i].text = keep.text; p.titles[i].start = keep.start
                                p.titles[i].duration = keep.duration; p.titles[i].words = keep.words
                                if look.x == nil { p.titles[i].x = keep.x; p.titles[i].y = keep.y }
                            }
                        }
                    }
                }
            }

            GlassCard(title: "Placement") {
            HStack(spacing: 8) {
                PillSlider(label: "Size", value: "\(Int((item.size * 100).rounded()))%",
                           amount: Binding(get: { item.size }, set: { v in model.updateTitle(item.id) { $0.size = v } }),
                           range: 0.3...4, origin: 0.3, reset: 1)
                PillSlider(label: "Rotate", value: "\(Int(item.rotation.rounded()))°",
                           amount: Binding(get: { item.rotation }, set: { v in model.updateTitle(item.id) { $0.rotation = v } }),
                           range: -180...180, origin: 0, reset: 0)
            }

            Text("Drag the title on the video to move it; use the corners to resize and the top handle to rotate.")
                .font(.system(size: 11))
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                GlassPillButton(title: "Go to start", icon: "arrow.left.to.line") { model.seek(to: item.start) }
                GlassPillButton(title: "Reset", icon: "arrow.counterclockwise") {
                    model.updateTitle(item.id, undo: .push) { $0.x = nil; $0.y = nil; $0.rotation = 0 }
                }
                .disabled(item.x == nil && item.rotation == 0)
                Spacer(minLength: 0)
                Button { model.deleteSelection() } label: { Image(systemName: "trash").frame(width: 26, height: 26) }
                    .buttonStyle(.plain)
                    .glass(in: Circle(), interactive: true)
                    .help("Delete title")
            }
            }
        }
        .onAppear { text = item.text; editing = item.text == "Title" || item.text == "Caption" }
        .onChange(of: item.id) { text = item.text }
        // Text changed elsewhere (the AI, undo, the demo) shows up here too, unless you're typing.
        .onChange(of: item.text) { old, new in if text == old { text = new } }
    }

    static let popularFonts = ["Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Optima", "Didot", "Georgia",
                               "Baskerville", "Rockwell", "American Typewriter", "Courier New", "Copperplate",
                               "Marker Felt", "Chalkboard SE", "Snell Roundhand", "Impact"]
        .filter { NSFontManager.shared.availableFontFamilies.contains($0) }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: TitleRenderer.color(item.color)) },
                set: { c in
                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
                    let hex = String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
                    model.updateTitle(item.id) { $0.color = hex }
                })
    }

    private func colorWell(_ key: WritableKeyPath<TitleItem, String>, help: String) -> some View {
        ColorPicker("", selection: Binding(
            get: { Color(nsColor: TitleRenderer.color(item[keyPath: key])) },
            set: { c in
                let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
                let hex = String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
                model.updateTitle(item.id) { $0[keyPath: key] = hex }
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 30)
            .help(help)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Ink.primary).frame(width: 64, alignment: .leading)
    }

    private func fontButton(_ family: String) -> some View {
        Button { model.updateTitle(item.id, undo: .push) { $0.font = family } } label: {
            if item.font == family { Label(family, systemImage: "checkmark") } else { Text(family) }
        }
    }

    private func toggleButton(_ icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.black : Ink.secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white : Ink.well))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func segmented<T: Hashable>(_ options: [T], selected: T, title: @escaping (T) -> String,
                                        action: @escaping (T) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selected
                Button { action(o) } label: {
                    Text(title(o))
                        .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Ink.secondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Ink.well))
    }
}

// MARK: - Histogram

struct HistogramView: View {
    @ObservedObject var scope: ScopeMonitor

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.well)
            // Quarter gridlines
            HStack(spacing: 0) {
                ForEach(0..<4) { i in
                    Rectangle().fill(i == 0 ? .clear : Ink.hairline).frame(width: 1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 6)
            if let h = scope.histogram {
                Canvas { ctx, size in
                    let inset = CGRect(x: 0, y: 8, width: size.width, height: size.height - 10)
                    ctx.blendMode = .plusLighter
                    fill(ctx, h.red, .init(red: 1, green: 0.25, blue: 0.25), in: inset)
                    fill(ctx, h.green, .init(red: 0.3, green: 1, blue: 0.35), in: inset)
                    fill(ctx, h.blue, .init(red: 0.3, green: 0.45, blue: 1), in: inset)
                    ctx.blendMode = .normal
                    ctx.stroke(path(h.luma, in: inset, closed: false), with: .color(.white.opacity(0.7)), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    clipMark(h.clippedShadows, help: "Shadows are clipping")
                    Spacer()
                    clipMark(h.clippedHighlights, help: "Highlights are clipping")
                }
                .padding(6)
            } else {
                Text("Histogram")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 96)
    }

    private func clipMark(_ on: Bool, help: String) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 7))
            .foregroundStyle(on ? Color.white : Ink.tertiary.opacity(0.5))
            .help(on ? help : "")
    }

    private func path(_ bins: [Float], in r: CGRect, closed: Bool) -> Path {
        var p = Path()
        let n = bins.count
        guard n > 1 else { return p }
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(n - 1),
                    y: r.maxY - r.height * CGFloat(sqrt(bins[i])))   // sqrt keeps small bins visible
        }
        if closed { p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: pt(0)) } else { p.move(to: pt(0)) }
        for i in 1..<n { p.addLine(to: pt(i)) }
        if closed { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath() }
        return p
    }

    private func fill(_ ctx: GraphicsContext, _ bins: [Float], _ color: Color, in r: CGRect) {
        ctx.fill(path(bins, in: r, closed: true), with: .color(color.opacity(0.45)))
    }
}

// MARK: - Strength

struct StrengthRow: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        GlassCard {
            PillSlider(label: "Strength", value: "\(Int((model.intensity * 100).rounded()))%",
                       amount: $model.intensity, range: 0...1.5, reset: 1)
        }
        .disabled(model.recipe.isNeutral)
        .opacity(model.recipe.isNeutral ? 0.5 : 1)
        .help("Scales the whole grade. 100% is what the AI chose. Double-click to go back to 100%.")
    }
}

// MARK: - Light / Color groups

struct AdjustGroup: View {
    @EnvironmentObject var model: EditorModel
    let title: String
    let knobs: [String]
    @AppStorage private var expanded: Bool

    init(title: String, knobs: [String]) {
        self.title = title
        self.knobs = knobs
        _expanded = AppStorage(wrappedValue: true, "inspector.\(title).expanded")
    }

    private var items: [GradeRecipe.Knob] { GradeRecipe.knobs.filter { knobs.contains($0.name) } }
    private var modified: Bool { items.contains { abs(model.recipe[keyPath: $0.key]) > 0.0001 } }

    var body: some View {
        GlassCard(title: title, trailing: AnyView(HStack(spacing: 4) {
            Button { for k in items { model.recipe[keyPath: k.key] = 0 } } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(modified ? Ink.secondary : Ink.tertiary.opacity(0.5))
            .disabled(!modified)
            .help("Reset \(title)")
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: 20, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide \(title)" : "Show \(title)")
        })) {
            if expanded {
                VStack(spacing: 7) {
                    ForEach(items, id: \.name) { knob in
                        KnobRow(knob: knob, value: Binding(
                            get: { model.recipe[keyPath: knob.key] },
                            set: { model.recipe[keyPath: knob.key] = $0 }))
                    }
                }
            } else {
                Button { withAnimation(.easeOut(duration: 0.18)) { expanded = true } } label: {
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Contrast −18 · Shadows +12", or "No changes".
    private var summary: String {
        let parts = items.compactMap { k -> String? in
            let v = model.recipe[keyPath: k.key]
            guard abs(v) > 0.004 else { return nil }
            return "\(k.label) " + KnobRow.format(k, v)
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }
}

/// One knob as a pill slider: name · amount from the middle · value.
struct KnobRow: View {
    let knob: GradeRecipe.Knob
    @Binding var value: Double

    var body: some View {
        PillSlider(label: knob.label, value: Self.format(knob, value), amount: $value, range: knob.range,
                   origin: 0, reset: 0, height: 26, track: Self.track(knob.name), dimAtDefault: true)
            .help(knob.help + " Double-click to reset.")
    }

    static func format(_ knob: GradeRecipe.Knob, _ value: Double) -> String {
        if knob.name == "exposure" { return abs(value) < 0.005 ? "0.00" : String(format: "%+.2f", value) }
        return abs(value) < 0.5 ? "0" : String(format: "%+.0f", value)
    }

    /// Tracks that show what the slider does.
    static func track(_ name: String) -> [Color]? {
        switch name {
        case "exposure": return [Color(white: 0.12), Color(white: 0.85)]
        case "temperature": return [Color(red: 0.25, green: 0.5, blue: 1), Color(white: 0.75), Color(red: 1, green: 0.78, blue: 0.2)]
        case "tint": return [Color(red: 0.3, green: 0.8, blue: 0.35), Color(white: 0.75), Color(red: 0.9, green: 0.3, blue: 0.85)]
        case "saturation", "vibrance":
            return [Color(white: 0.55), Color(red: 1, green: 0.35, blue: 0.35), Color(red: 1, green: 0.8, blue: 0.2),
                    Color(red: 0.3, green: 0.85, blue: 0.4), Color(red: 0.3, green: 0.5, blue: 1)]
        default: return nil
        }
    }
}

/// Thin slider that fills from its origin (0) toward the value — the way pro color tools show ± adjustments.
/// Optional gradient track; double-click resets.
struct GradeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var origin: Double = 0
    var resetValue: Double = 0
    var track: [Color]? = nil
    var ticks: [Double] = []
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pos = { (v: Double) in CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) * w }
            let x = pos(value), o = pos(origin)
            ZStack(alignment: .leading) {
                if let track {
                    Capsule()
                        .fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                        .opacity(0.55)
                        .frame(height: 3)
                } else {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: 3)
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: abs(x - o), height: 3)
                        .offset(x: min(x, o))
                }
                ForEach(ticks, id: \.self) { t in
                    Rectangle().fill(Ink.tertiary).frame(width: 1, height: 7).offset(x: pos(t))
                }
                if track != nil, origin > range.lowerBound {
                    Rectangle().fill(Ink.secondary).frame(width: 1, height: 7).offset(x: o)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
                    .offset(x: x - 5.5)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                let p = min(max(g.location.x / w, 0), 1)
                var v = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                // Gentle snap to the reset value.
                if abs(v - resetValue) < (range.upperBound - range.lowerBound) * 0.015 { v = resetValue }
                value = v
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { value = resetValue } })
        }
        .frame(height: 16)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Activity log, kept for debugging.
struct ActivityLog: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        List(model.log) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                if let d = entry.detail { Text(d).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        }
    }
}
