import SwiftUI

/// Popover for the transition into a clip (or, on the first clip, its fade from black).
struct TransitionEditor: View {
    @EnvironmentObject var model: EditorModel
    let clipID: UUID
    let isFirst: Bool

    private var clip: ClipItem? { model.project.clip(clipID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isFirst ? "Fade in from black" : "Transition").font(.system(size: 13, weight: .semibold))
            if !isFirst {
                Picker("Kind", selection: Binding(get: { clip?.transitionIn?.kind }, set: { kind in
                    if let kind { model.setTransition(Transition(kind: kind, duration: clip?.transitionIn?.duration ?? 0.6), for: clipID) }
                    else { model.setTransition(nil, for: clipID) }
                })) {
                    Text("None (cut)").tag(Transition.Kind?.none)
                    ForEach(Transition.Kind.allCases) { Text($0.label).tag(Transition.Kind?.some($0)) }
                }
                .pickerStyle(.radioGroup)
            } else {
                Toggle("Fade in", isOn: Binding(get: { clip?.transitionIn != nil }, set: { on in
                    model.setTransition(on ? Transition(kind: .dipToBlack, duration: 1) : nil, for: clipID)
                }))
            }
            if let t = clip?.transitionIn {
                HStack {
                    Text("Length").font(.system(size: 12))
                    Slider(value: Binding(get: { t.duration }, set: { d in
                        model.updateClip(clipID) { $0.transitionIn?.duration = d }
                    }), in: 0.2...3)
                    Text(String(format: "%.1f s", t.duration)).font(.system(size: 11).monospacedDigit()).frame(width: 40)
                }
            }
            Button("Apply to every cut") {
                guard let t = clip?.transitionIn, !isFirst else { return }
                model.mutate(.push) { p in for i in p.clips.indices where i > 0 { p.clips[i].transitionIn = t } }
            }
            .disabled(isFirst || clip?.transitionIn == nil)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 260)
    }
}

/// Popover for the fade to black at the end of the video.
struct EndFadeEditor: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Fade out to black at the end", isOn: Binding(get: { model.project.fadeOut > 0 }, set: { model.setFadeOut($0 ? 1.5 : 0) }))
            if model.project.fadeOut > 0 {
                HStack {
                    Text("Length").font(.system(size: 12))
                    Slider(value: Binding(get: { model.project.fadeOut }, set: { model.setFadeOut($0) }), in: 0.3...5)
                    Text(String(format: "%.1f s", model.project.fadeOut)).font(.system(size: 11).monospacedDigit()).frame(width: 40)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
