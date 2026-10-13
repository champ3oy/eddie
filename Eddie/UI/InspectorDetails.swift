import SwiftUI

/// Small shared pieces for the inspector rows.
enum Row {
    static func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Ink.primary).frame(width: 78, alignment: .leading)
    }

    static func value(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Ink.secondary)
            .frame(width: 40, alignment: .trailing)
    }

    static func slider(_ label: String, value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>,
                       origin: Double = 0, reset: Double = 0) -> some View {
        PillSlider(label: label, value: value, amount: binding, range: range, origin: origin, reset: reset)
    }

    static func segmented<T: Hashable>(_ options: [T], selected: T, title: @escaping (T) -> String,
                                       action: @escaping (T) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selected
                Button { action(o) } label: {
                    Text(title(o))
                        .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(on ? Color.black : Ink.secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(Capsule().fill(on ? Color.white : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: selected)
    }

    static func header(_ title: String, open: Binding<Bool>) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { open.wrappedValue.toggle() } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A menu shown as a pill: name on the left, current choice and a chevron on the right.
struct PillMenu<Items: View>: View {
    let label: String
    let value: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(Ink.primary)
                Spacer(minLength: 6)
                Text(value).foregroundStyle(Ink.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Footage type, transition, sound fades and framing for the selected clip (main track or overlay).
struct ClipDetails: View {
    @EnvironmentObject var model: EditorModel
    let clip: ClipItem
    @AppStorage("inspector.framingOpen") private var framingOpen = false

    private var overlay: OverlayItem? { model.project.overlays.first { $0.id == clip.id } }
    private var isFirst: Bool { model.project.clips.first?.id == clip.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassCard(title: overlay == nil ? "Footage & transition" : "Overlay") {
                Row.segmented(SourceProfile.allCases, selected: clip.profile, title: { $0.label }) { p in
                    model.updateClip(clip.id, undo: .push) { $0.profile = p }
                }
                .help("D-Log M footage gets the DJI look applied first. Pick Normal for phone or non-log clips.")

                if let overlay {
                    Row.segmented(["Full frame", "Picture in picture"], selected: clip.transform.scale < 0.95 ? "Picture in picture" : "Full frame", title: { $0 }) { s in
                        model.updateClip(clip.id, undo: .push) { $0.transform = s == "Picture in picture" ? EditorModel.pipTransform : .identity; $0.keyframes = [] }
                    }
                    Row.slider("Opacity", value: "\(Int(overlay.opacity * 100))%",
                               Binding(get: { overlay.opacity }, set: { v in model.updateOverlay(clip.id) { $0.opacity = v } }),
                               0...1, reset: 1)
                    PillMenu(label: "Blend", value: overlay.blend.label) {
                        ForEach(BlendMode.allCases) { b in
                            Button(b.label) { model.updateOverlay(clip.id, undo: .push) { $0.blend = b } }
                        }
                    }
                } else {
                    PillMenu(label: isFirst ? "Start" : "Transition in",
                             value: clip.transitionIn.map { isFirst ? "Fade from black" : $0.kind.label } ?? (isFirst ? "Cut in" : "Cut")) {
                        Button("None") { model.setTransition(nil, for: clip.id) }
                        Divider()
                        if isFirst {
                            Button("Fade from Black") { model.setTransition(Transition(kind: .dipToBlack, duration: 1), for: clip.id) }
                        } else {
                            ForEach(Transition.Kind.allCases) { k in
                                Button(k.label) { model.setTransition(Transition(kind: k, duration: clip.transitionIn?.duration ?? 0.6), for: clip.id) }
                            }
                        }
                    }
                    if let t = clip.transitionIn {
                        Row.slider("Length", value: String(format: "%.1f s", t.duration),
                                   Binding(get: { t.duration }, set: { d in model.updateClip(clip.id) { $0.transitionIn?.duration = d } }),
                                   0.2...3, reset: 0.6)
                    }
                }
            }

            if !clip.isPhoto && !clip.audioMuted {
                GlassCard(title: "Sound fades") {
                    HStack(spacing: 8) {
                        Row.slider("In", value: String(format: "%.1f s", clip.audioFadeIn),
                                   Binding(get: { clip.audioFadeIn }, set: { v in model.updateClip(clip.id) { $0.audioFadeIn = v } }),
                                   0...min(5, clip.duration / 2), reset: 0)
                        Row.slider("Out", value: String(format: "%.1f s", clip.audioFadeOut),
                                   Binding(get: { clip.audioFadeOut }, set: { v in model.updateClip(clip.id) { $0.audioFadeOut = v } }),
                                   0...min(5, clip.duration / 2), reset: 0)
                    }
                }
            }

            EffectsCard(clip: clip)
            MaskCard(clip: clip)
            ChromaKeyCard(clip: clip)

            GlassCard(title: "Framing" + (clip.keyframes.isEmpty ? "" : " · animated"), trailing: AnyView(
                Button { withAnimation(.easeOut(duration: 0.18)) { framingOpen.toggle() } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.secondary)
                        .rotationEffect(.degrees(framingOpen ? 0 : -90))
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(framingOpen ? "Hide framing" : "Show zoom, position, rotation and crop")
            )) {
                if framingOpen {
                    FramingControls(clip: clip, clock: model.clock)
                } else {
                    Button { withAnimation(.easeOut(duration: 0.18)) { framingOpen = true } } label: {
                        Text(clip.transform == .identity && clip.keyframes.isEmpty ? "As shot" : TimelineDescriber.framing(clip.transform))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Zoom, position, rotation and crop — at the playhead when the clip is animated.
struct FramingControls: View {
    @EnvironmentObject var model: EditorModel
    let clip: ClipItem
    @ObservedObject var clock: PlaybackClock

    private var t: Transform2D {
        let start = model.project.start(of: clip.id) ?? model.selectedOverlay?.start ?? 0
        return clip.transform(at: min(max(0, clock.time - start), clip.duration))
    }

    private func bind(_ key: WritableKeyPath<Transform2D, Double>) -> Binding<Double> {
        Binding(get: { t[keyPath: key] }, set: { v in model.setFraming { $0[keyPath: key] = v } })
    }

    var body: some View {
        let t = self.t
        VStack(alignment: .leading, spacing: 8) {
            Row.slider("Zoom", value: "\(Int((t.scale * 100).rounded()))%", bind(\.scale), 0.1...4, origin: 1, reset: 1)
            HStack(spacing: 8) {
                Row.slider("X", value: "\(Int((t.x * 100).rounded()))", bind(\.x), -1...1, origin: 0, reset: 0)
                Row.slider("Y", value: "\(Int((-t.y * 100).rounded()))",
                           Binding(get: { -t.y }, set: { v in model.setFraming { $0.y = -v } }), -1...1, origin: 0, reset: 0)
            }
            Row.slider("Rotate", value: "\(Int(t.rotation.rounded()))°", bind(\.rotation), -180...180, origin: 0, reset: 0)
            Text("CROP").font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.tertiary).padding(.top, 2)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Row.slider("Left", value: "\(Int(t.cropLeft * 100))%", bind(\.cropLeft), 0...0.45, reset: 0)
                    Row.slider("Right", value: "\(Int(t.cropRight * 100))%", bind(\.cropRight), 0...0.45, reset: 0)
                }
                GridRow {
                    Row.slider("Top", value: "\(Int(t.cropTop * 100))%", bind(\.cropTop), 0...0.45, reset: 0)
                    Row.slider("Bottom", value: "\(Int(t.cropBottom * 100))%", bind(\.cropBottom), 0...0.45, reset: 0)
                }
            }
            HStack(spacing: 6) {
                GlassPillButton(title: "Keyframe", icon: "diamond") { model.addKeyframe() }
                    .help("Remember this framing at the playhead — the clip animates between keyframes")
                GlassPillButton(title: "Slow zoom", icon: "arrow.up.left.and.arrow.down.right") { model.kenBurns(clip.id) }
                    .help("Ken Burns: a slow push-in across the whole clip")
                Spacer(minLength: 0)
                if !clip.keyframes.isEmpty {
                    Button { model.clearKeyframes(clip.id) } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                        .buttonStyle(.plain)
                        .glass(in: Circle(), interactive: true)
                        .help("Stop animating (\(clip.keyframes.count) keyframes)")
                }
                Button { model.updateClip(clip.id, undo: .push) { $0.transform = .identity; $0.keyframes = [] } } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .glass(in: Circle(), interactive: true)
                .help("Reset framing")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Ink.primary)
            .padding(.top, 2)
        }
    }
}

/// Shown when nothing is selected: the video's shape and ending.
struct ProjectSection: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        GlassCard(title: "Video") {
            PillMenu(label: "Shape", value: model.project.format.aspect.label) {
                ForEach(ProjectFormat.Aspect.allCases) { a in
                    Button(a.label) { model.setFormat { $0.aspect = a } }
                }
            }
            if model.project.format.aspect != .auto {
                Row.segmented([true, false], selected: model.project.format.fill, title: { $0 ? "Fill frame" : "Fit inside" }) { f in
                    model.setFormat { $0.fill = f }
                }
                if !model.project.format.fill {
                    Row.segmented([false, true], selected: model.project.format.blurBackground,
                                  title: { $0 ? "Blurred background" : "Black bars" }) { b in
                        model.setFormat { $0.blurBackground = b }
                    }
                }
            }
            Row.slider("Fade out at the end", value: model.project.fadeOut > 0 ? String(format: "%.1f s", model.project.fadeOut) : "Off",
                       Binding(get: { model.project.fadeOut }, set: { model.setFadeOut($0) }), 0...5, reset: 0)
        }
    }
}

// MARK: - Effects, mask, green screen

/// Looks on top of the grade: add from the menu, set each one's amount, remove.
struct EffectsCard: View {
    @EnvironmentObject var model: EditorModel
    let clip: ClipItem
    var body: some View {
        GlassCard(title: "Effects", trailing: AnyView(
            Menu {
                ForEach(ClipEffect.Kind.allCases) { k in
                    Button { model.addEffect(k, to: clip.id) } label: { Label(k.label, systemImage: k.icon) }
                        .disabled(clip.effects.contains { $0.kind == k })
                }
            } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.secondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Add an effect")
        )) {
            if clip.effects.isEmpty {
                Text("Blur, grain, glitch, VHS, light leaks, shake and more — add with +.")
                    .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
            }
            ForEach(clip.effects) { e in
                HStack(spacing: 6) {
                    if e.kind == .mirror {
                        Label(e.kind.label, systemImage: e.kind.icon).font(.system(size: 11.5)).foregroundStyle(Ink.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 28)
                    } else {
                        PillSlider(label: e.kind.label, value: "\(Int((e.amount * 100).rounded()))%",
                                   amount: Binding(get: { e.amount }, set: { v in
                                       model.updateClip(clip.id) { c in if let i = c.effects.firstIndex(where: { $0.id == e.id }) { c.effects[i].amount = v } }
                                   }), range: 0...1, reset: 0.5)
                    }
                    Button { model.updateClip(clip.id, undo: .push) { $0.effects.removeAll { $0.id == e.id } } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain).foregroundStyle(Ink.secondary).help("Remove \(e.kind.label)")
                }
            }
        }
    }
}

/// Cut the clip to a circle, rectangle or along a line, with a soft edge.
struct MaskCard: View {
    @EnvironmentObject var model: EditorModel
    let clip: ClipItem

    private func bind(_ key: WritableKeyPath<ClipMask, Double>) -> Binding<Double> {
        Binding(get: { clip.mask?[keyPath: key] ?? 0 }, set: { v in model.updateClip(clip.id) { $0.mask?[keyPath: key] = v } })
    }

    var body: some View {
        GlassCard(title: "Mask", trailing: AnyView(
            Toggle("", isOn: Binding(get: { clip.mask != nil }, set: { on in
                model.updateClip(clip.id, undo: .push) { $0.mask = on ? ClipMask() : nil }
            })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        )) {
            if let m = clip.mask {
                Row.segmented(ClipMask.Shape.allCases, selected: m.shape, title: { $0.label }) { shape in
                    model.updateClip(clip.id, undo: .push) { $0.mask?.shape = shape }
                }
                HStack(spacing: 8) {
                    Row.slider("X", value: "\(Int((m.centerX * 100).rounded()))", bind(\.centerX), 0...1, reset: 0.5)
                    Row.slider("Y", value: "\(Int((m.centerY * 100).rounded()))", bind(\.centerY), 0...1, reset: 0.5)
                }
                if m.shape != .linear {
                    HStack(spacing: 8) {
                        Row.slider("W", value: "\(Int((m.width * 100).rounded()))%", bind(\.width), 0.05...1.5, reset: 0.7)
                        Row.slider("H", value: "\(Int((m.height * 100).rounded()))%", bind(\.height), 0.05...1.5, reset: 0.7)
                    }
                }
                HStack(spacing: 8) {
                    Row.slider("Soft", value: "\(Int((m.feather * 100).rounded()))%", bind(\.feather), 0...1, reset: 0.15)
                    Row.slider("Turn", value: "\(Int(m.rotation.rounded()))°", bind(\.rotation), -180...180, origin: 0, reset: 0)
                }
                Toggle(isOn: Binding(get: { m.invert }, set: { v in model.updateClip(clip.id, undo: .push) { $0.mask?.invert = v } })) {
                    Text("Invert (keep the outside)").font(.system(size: 11.5)).foregroundStyle(Ink.primary)
                }
                .toggleStyle(.switch).controlSize(.mini)
            } else {
                Text("Show only part of the picture — a circle, a box, or one side of a line.")
                    .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
            }
        }
    }
}

/// Green screen: remove a color (green by default) so what's underneath shows through.
struct ChromaKeyCard: View {
    @EnvironmentObject var model: EditorModel
    let clip: ClipItem

    private func bind(_ key: WritableKeyPath<ChromaKey, Double>) -> Binding<Double> {
        Binding(get: { clip.chromaKey?[keyPath: key] ?? 0 }, set: { v in model.updateClip(clip.id) { $0.chromaKey?[keyPath: key] = v } })
    }

    var body: some View {
        GlassCard(title: "Green screen", trailing: AnyView(
            Toggle("", isOn: Binding(get: { clip.chromaKey != nil }, set: { on in
                model.updateClip(clip.id, undo: .push) { $0.chromaKey = on ? ChromaKey() : nil }
            })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        )) {
            if let k = clip.chromaKey {
                HStack(spacing: 8) {
                    Text("Key color").font(.system(size: 11.5)).foregroundStyle(Ink.primary)
                    Spacer()
                    ForEach(["#00FF00", "#0047FF"], id: \.self) { hex in
                        Button { model.updateClip(clip.id, undo: .push) { $0.chromaKey?.color = hex } } label: {
                            Circle().fill(Color(nsColor: TitleRenderer.color(hex))).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.white.opacity(k.color == hex ? 0.9 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain).help(hex == "#00FF00" ? "Green" : "Blue")
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: TitleRenderer.color(k.color)) },
                        set: { c in
                            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .green
                            let hex = String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
                            model.updateClip(clip.id) { $0.chromaKey?.color = hex }
                        }), supportsOpacity: false).labelsHidden().frame(width: 30).help("Any color")
                }
                Row.slider("Strength", value: "\(Int((k.tolerance * 100).rounded()))%", bind(\.tolerance), 0...1, reset: 0.35)
                Row.slider("Edge softness", value: "\(Int((k.softness * 100).rounded()))%", bind(\.softness), 0...1, reset: 0.15)
                Toggle(isOn: Binding(get: { k.despill }, set: { v in model.updateClip(clip.id, undo: .push) { $0.chromaKey?.despill = v } })) {
                    Text("Remove green spill from edges").font(.system(size: 11.5)).foregroundStyle(Ink.primary)
                }
                .toggleStyle(.switch).controlSize(.mini)
            } else {
                Text("Make a green (or any) background transparent — usually on an overlay above other footage.")
                    .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
