import AVFoundation
import SwiftUI

/// Sound effects from Freesound.org: search, listen, add at the playhead. Only CC0 and CC BY sounds are
/// shown (free for any video); credits for CC BY ones are kept and can be copied for the video description.
struct SoundLibrarySheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sounds: [Freesound.Sound] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var playing: Int?
    @State private var player = AVPlayer()
    @State private var added: Set<Int> = []
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sound effects").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("from Freesound.org").font(.system(size: 11)).foregroundStyle(Ink.tertiary)
            }
            searchField

            Group {
                if !Freesound.hasKey {
                    message("Add a Freesound API key in Settings to search over 600,000 free sound effects.") {
                        SettingsLink { Text("Open Settings") }
                    }
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestions
                } else if let error, sounds.isEmpty {
                    message(error) { EmptyView() }
                } else if sounds.isEmpty && !loading {
                    message("No free sounds for “\(query)”. Try another word.") { EmptyView() }
                } else {
                    results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Text("Only sounds free for any video (CC0 and CC BY). CC BY sounds need a credit — Eddie keeps it for you.")
                    .font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let credits = Freesound.credits(for: model.project) {
                    Button(copied ? "Copied" : "Copy Credits") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(credits, forType: .string)
                        copied = true
                    }
                    .help("Copies the credits for the Freesound sounds in this project, ready for your video's description")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 600, height: 540)
        .onAppear { focused = true }
        .onDisappear { player.pause() }
        // Waits for a pause in typing before searching.
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { sounds = []; error = nil; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await load(page: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Ink.tertiary)
            TextField("Search sounds — whoosh, pop, applause…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if loading { ProgressView().controlSize(.mini) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Freesound.suggestions, id: \.self) { s in
                    Button { query = s } label: {
                        Text(s).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(sounds) { s in
                    row(s).onAppear { if s.id == sounds.last?.id, more { Task { await load(page: page + 1) } } }
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    private func row(_ s: Freesound.Sound) -> some View {
        HStack(spacing: 10) {
            Button { toggle(s) } label: {
                Image(systemName: playing == s.id ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(playing == s.id ? 0.25 : 0.1)))
            }
            .buttonStyle(.plain)
            .help(playing == s.id ? "Stop" : "Listen")

            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(String(format: "%.1f s", s.duration))
                    Text("·")
                    Text(s.author).lineLimit(1)
                    Text(s.license.label)
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(s.license == .cc0 ? 0.08 : 0.16)))
                        .help(s.license == .cc0 ? "Free to use, no credit needed" : "Free to use with a credit to the author (Eddie keeps it)")
                }
                .font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let w = s.waveform {
                AsyncImage(url: w) { img in img.resizable().interpolation(.medium) } placeholder: { Color.clear }
                    .frame(width: 110, height: 26)
                    .opacity(0.7)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Button(added.contains(s.id) ? "Added" : "Add") {
                model.addFreesound(s)
                added.insert(s.id)
            }
            .disabled(!model.hasProject)
            .help("Add at the playhead")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(playing == s.id ? 0.06 : 0.02)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.addFreesound(s); added.insert(s.id) }
    }

    private func message<A: View>(_ text: String, @ViewBuilder action: () -> A) -> some View {
        VStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            action()
        }
        .frame(maxWidth: 360)
    }

    private func toggle(_ s: Freesound.Sound) {
        if playing == s.id {
            player.pause()
            playing = nil
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: s.preview))
        player.play()
        playing = s.id
        // Clear the stop button when the preview ends.
        let id = s.id
        Task {
            try? await Task.sleep(for: .seconds(s.duration + 0.5))
            if playing == id, player.rate == 0 { playing = nil }
        }
    }

    private func load(page p: Int) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await Freesound.search(query, page: p)
            if p == 1 { sounds = r.sounds } else {
                let known = Set(sounds.map(\.id))
                sounds += r.sounds.filter { !known.contains($0.id) }
            }
            page = p
            more = r.more
            error = nil
        } catch {
            if p == 1 { sounds = [] }
            self.error = error.localizedDescription
        }
    }
}
