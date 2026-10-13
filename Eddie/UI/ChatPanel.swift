import SwiftUI

/// AI colorist anchored to the bottom of the inspector: suggestion chips and a Liquid Glass composer.
/// Progress shows on the timeline's AI Grade track; only errors appear here.
struct ChatPanel: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Settings") { openSettings() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 11.5))
            }
            if model.busy, let status = model.status {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status).foregroundStyle(Ink.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
            } else if let reply = model.assistantReply {
                // Long answers scroll inside a short box instead of stretching the window.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Ink.secondary)
                    ScrollView {
                        Text(reply)
                            .foregroundStyle(Ink.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                    Button { model.assistantReply = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Ink.tertiary)
                }
                .font(.system(size: 12))
            }
            PresetStrip()
            Composer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

// MARK: - Glass helpers

extension View {
    /// Liquid Glass on macOS 26+, a dark material before that.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

// MARK: - Presets

/// One-click looks, each previewed on the frame under the playhead.
struct PresetStrip: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Preset.all) { preset in
                    PresetTile(preset: preset, image: model.presetThumbs[preset.name],
                               active: model.activePreset == preset.name) { model.apply(preset) }
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
        .disabled(model.busy || model.selectedClip == nil)
        .opacity(model.busy ? 0.5 : 1)
    }
}

private struct PresetTile: View {
    let preset: Preset
    let image: CGImage?
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    private let size: CGFloat = 44

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size - 6, height: size - 6)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .frame(width: size, height: size)
                .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: true)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(active ? 0.9 : (hovering ? 0.35 : 0)), lineWidth: active ? 1.5 : 1)
                )
                Text(preset.name)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
                    .foregroundStyle(active || hovering ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(active ? "Remove \(preset.name)" : "Apply \(preset.name)")
    }
}

// MARK: - Composer

struct Composer: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.openSettings) private var openSettings
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask Eddie to edit or color…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(primaryAction)
                .disabled(model.busy)

            HStack(spacing: 8) {
                providerMenu
                Spacer()
                actionButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(focused ? Color.white.opacity(0.25) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var providerMenu: some View {
        Menu {
            Picker("Provider", selection: Binding(get: { model.providerKind }, set: { model.setProvider($0) })) {
                ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Auto Grade All Clips") { model.autoGradeAll() }
                .disabled(model.busy || model.project.clips.count < 2)
            Button("AI Settings…") { openSettings() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 10, weight: .semibold))
                Text(model.providerKind.label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.providerName)
    }

    /// Empty → Auto Grade, text → send, busy → stop.
    private var actionButton: some View {
        let icon = model.busy ? "stop.fill" : (trimmed.isEmpty ? "wand.and.stars" : "arrow.up")
        let help = model.busy ? "Stop" : (trimmed.isEmpty ? "Auto Grade" : "Send")
        return Button(action: primaryAction) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(model.busy ? Color.white : Color.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(model.busy ? Color.white.opacity(0.2) : Color.white))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .demoAnchor("auto-grade")
        .keyboardShortcut(.return, modifiers: [.command])
        .help(help)
        .disabled(!model.hasProject)
    }

    private func primaryAction() {
        if model.busy { model.cancelAI(); return }
        if trimmed.isEmpty { model.autoGrade() } else { model.ask(trimmed); text = "" }
    }
}
