import SwiftUI
import UniformTypeIdentifiers

/// Captions: make them (from speech, typed, or an SRT file), style them all at once, translate them,
/// tighten the edit, and fix the transcript line by line.
struct CaptionsPanel: View {
    @EnvironmentObject var model: EditorModel
    @State private var showScript = false
    @State private var bilingual = false

    static let languages = ["English", "Spanish", "French", "German", "Portuguese", "Italian", "Dutch", "Japanese",
                            "Korean", "Chinese (Simplified)", "Arabic", "Hindi", "Swahili", "Twi", "Yoruba"]
    static let speechLanguages: [(String, String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"), ("fr-FR", "French"),
        ("de-DE", "German"), ("pt-BR", "Portuguese"), ("it-IT", "Italian"), ("nl-NL", "Dutch"),
        ("ja-JP", "Japanese"), ("ko-KR", "Korean"), ("zh-CN", "Chinese"), ("ar-SA", "Arabic"), ("hi-IN", "Hindi"),
    ]

    var body: some View {
        let captions = model.project.captions
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Captions").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                if !captions.isEmpty {
                    Text("\(captions.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Ink.tertiary)
                }
                Spacer()
                Menu {
                    Button("Add Caption at Playhead") { model.addCaptionAtPlayhead() }
                    Button("Type or Paste Captions…") { showScript = true }
                    Divider()
                    Button("Import SRT…") { importSRT() }
                    Button("Export SRT…") { exportSRT() }.disabled(captions.isEmpty)
                    Divider()
                    Button("Remove All Captions", role: .destructive) { model.removeCaptions() }.disabled(captions.isEmpty)
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add, import or export captions")
            }

            // Make captions from speech.
            HStack(spacing: 6) {
                Button { model.autoCaptions() } label: {
                    Label(model.captioning ? "Listening…" : "Auto captions", systemImage: "waveform")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.primary)
                .glass(in: Capsule(), interactive: true)
                .disabled(!model.hasProject || model.captioning)
                .help("Listen to the clips (on this Mac) and caption what's said")
                Menu {
                    Picker("Spoken language", selection: $model.captionLanguage) {
                        ForEach(Self.speechLanguages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } label: {
                    Text(Self.speechLanguages.first { $0.0 == model.captionLanguage }?.1.components(separatedBy: " ").first ?? "Language")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The language spoken in the clips")
            }

            if let work = model.captionWork {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(work).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
            }

            // Look.
            Text("STYLE").font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.tertiary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(CaptionPreset.all) { preset in
                    PresetChip(preset: preset, selected: model.captionPreset == preset.name) {
                        model.applyCaptionPreset(preset.name)
                    }
                }
            }

            // Translate + tighten.
            HStack(spacing: 6) {
                Menu {
                    Toggle("Keep the original too (bilingual)", isOn: $bilingual)
                    Divider()
                    ForEach(Self.languages, id: \.self) { lang in
                        Button(lang) { model.translateCaptions(to: lang, bilingual: bilingual) }
                    }
                } label: {
                    Label("Translate", systemImage: "character.bubble").font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(captions.isEmpty || model.captionWork != nil)
                .help("Translate every caption with the AI in Settings")
                Spacer()
                Menu {
                    Button("Remove Filler Words (um, uh…)") { model.removeFillerWords() }
                    Button("Remove Pauses Longer Than 0.7 s") { model.removeSilences(minimum: 0.7) }
                    Button("Remove Pauses Longer Than 1.5 s") { model.removeSilences(minimum: 1.5) }
                } label: {
                    Label("Tighten", systemImage: "scissors").font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.hasProject || model.captionWork != nil)
                .help("Cut filler words or long pauses out of the edit")
            }
            .foregroundStyle(Ink.secondary)

            Rectangle().fill(Ink.hairline).frame(height: 1)

            // The transcript.
            if captions.isEmpty {
                Text("No captions yet. Use Auto captions, type them, or import an SRT file.")
                    .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(captions) { c in
                                CaptionRow(caption: c, clock: model.clock.coarse).id(c.id)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selection) { _, id in
                        if let id, captions.contains(where: { $0.id == id }) { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .sheet(isPresented: $showScript) { ScriptSheet().environmentObject(model) }
    }

    private func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, .plainText]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let replace = model.project.captions.isEmpty || NSAlert.ask("Replace the current captions?",
                                                                     info: "Or keep them and add the imported ones.",
                                                                     yes: "Replace", no: "Add")
        model.importSRT(url, replacing: replace)
    }

    private func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        let base = (model.fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "captions" : base).srt"
        if panel.runModal() == .OK, let url = panel.url { model.exportSRT(to: url) }
    }
}

/// One caption in the transcript: its time (click to jump there), editable text, split/merge/delete.
private struct CaptionRow: View {
    @EnvironmentObject var model: EditorModel
    let caption: TitleItem
    @ObservedObject var clock: PlaybackClock.Ticker
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var editing: Bool

    var body: some View {
        let live = clock.time >= caption.start && clock.time < caption.end
        let selected = model.selection == caption.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    model.selection = caption.id
                    model.seek(to: caption.start + 0.05)
                } label: {
                    Text(Self.clock(caption.start))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(live ? Color.yellow : Ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("Jump here")
                Spacer()
                if hovering || selected {
                    HStack(spacing: 8) {
                        icon("scissors", "Split at the playhead (or in the middle)") { model.splitCaption(caption.id) }
                        icon("arrow.down.to.line.compact", "Merge with the next caption") { model.mergeCaptionWithNext(caption.id) }
                        icon("trash", "Delete") { model.mutate(.push) { $0.titles.removeAll { $0.id == caption.id } } }
                    }
                }
            }
            TextField("Caption", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Ink.primary)
                .lineLimit(1...4)
                .focused($editing)
                .onSubmit { commit() }
                .onChange(of: editing) { _, now in if !now { commit() } }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Color.white.opacity(0.12) : (live ? Color.white.opacity(0.06) : Color.clear)))
        .onHover { hovering = $0 }
        .onAppear { text = caption.text }
        .onChange(of: caption.text) { _, t in if !editing { text = t } }
        .onTapGesture { model.selection = caption.id }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != caption.text else { return }
        if t.isEmpty { text = caption.text; return }
        model.updateTitle(caption.id, undo: .push) { $0.text = t }
    }

    private func icon(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 10)) }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .help(help)
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
}

/// A caption style shown in its own look.
private struct PresetChip: View {
    let preset: CaptionPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        var sample = TitleItem(text: "Aa", start: 0)
        preset.apply(&sample)
        return Button(action: action) {
            HStack(spacing: 6) {
                Text("Aa")
                    .font(Font(TitleRenderer.font(sample, pointSize: 13)))
                    .foregroundStyle(Color(nsColor: TitleRenderer.color(sample.wordHighlight ? sample.highlightColor : sample.color)))
                    .shadow(color: sample.glow > 0 ? Color(nsColor: TitleRenderer.color(sample.glowColor)) : .clear, radius: 3)
                Text(preset.name).font(.system(size: 11)).foregroundStyle(Ink.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.6 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Apply \(preset.name) to all captions")
    }
}

/// Type or paste a script; each line becomes a caption.
private struct ScriptSheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var script = ""
    @State private var fromPlayhead = false
    @State private var replacing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type or paste captions").font(.system(size: 15, weight: .semibold))
            Text("One caption per line. Long lines are split, and the captions are spread over the video by length — fix any timing on the captions lane afterwards.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $script)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                .frame(minHeight: 200)
            Toggle("Start at the playhead", isOn: $fromPlayhead)
            Toggle("Replace the current captions", isOn: $replacing)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Captions") {
                    model.addManualCaptions(script, fromPlayhead: fromPlayhead, replacing: replacing)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(Color(white: 0.32))
                .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

extension NSAlert {
    /// A two-button question; true for `yes`.
    static func ask(_ message: String, info: String, yes: String, no: String) -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: yes)
        a.addButton(withTitle: no)
        return a.runModal() == .alertFirstButtonReturn
    }
}
