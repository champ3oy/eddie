import SwiftUI
import UniformTypeIdentifiers

/// The project's media: everything imported, whether or not it's on the timeline.
/// Drag onto the timeline, double-click to add at the end, right-click for more.
struct MediaBinView: View {
    @EnvironmentObject var model: EditorModel
    @State private var filter = Filter.all
    @State private var targeted = false

    enum Filter: String, CaseIterable { case all = "All", video = "Video", photo = "Photos", audio = "Audio" }

    private var items: [URL] {
        model.binItems.filter { url in
            switch filter {
            case .all: return true
            case .video: return !EditorModel.isAudioFile(url) && !EditorModel.isImageFile(url)
            case .photo: return EditorModel.isImageFile(url)
            case .audio: return EditorModel.isAudioFile(url)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Media").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                Spacer()
                Button { importFiles() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Import media into this project")
            }
            Row.segmented(Filter.allCases, selected: filter, title: { $0.rawValue }) { filter = $0 }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 10) {
                    ForEach(items, id: \.self) { url in
                        BinTile(url: url, uses: model.uses(of: url))
                            .onTapGesture(count: 2) { model.place([url], atTime: model.project.duration, lane: .main) }
                            .draggable(url)
                            .contextMenu { menu(url) }
                    }
                }
                .padding(.bottom, 10)
                // Fill the rest of the panel so a drop anywhere below the tiles lands too.
                Color.clear.frame(height: 200).contentShape(Rectangle())
            }
            .scrollIndicators(.never)
            if items.isEmpty {
                Text(filter == .all ? "Drop files here" : "Nothing here")
                    .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(targeted ? 0.5 : 0), lineWidth: 1.5).padding(4))
        // Files from Finder go into the bin only (not onto the timeline).
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                let urls = await FileDrop.urls(from: providers)
                    .filter { EditorModel.isAudioFile($0) || EditorModel.isImageFile($0) || UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
                model.importToBin(urls)
            }
            return true
        }
    }

    @ViewBuilder private func menu(_ url: URL) -> some View {
        if EditorModel.isAudioFile(url) {
            Button("Add as Music at Playhead") { model.addMusic(url) }
            Button("Add as Sound Effect at Playhead") { model.addMusic(url, kind: .effect) }
        } else {
            Button("Add to End of Timeline") { model.place([url], atTime: model.project.duration, lane: .main) }
            Button(model.editMode == .insert ? "Insert at Playhead" : "Overwrite at Playhead") {
                model.place([url], atTime: model.clock.time, lane: .main)
            }
            Button("Add as Overlay at Playhead") { model.place([url], atTime: model.clock.time, lane: .overlay) }
            Button("Add as Picture in Picture") { model.addOverlay(url, pictureInPicture: true) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Remove from Project", role: .destructive) { model.removeFromBin(url) }
            .disabled(model.uses(of: url) > 0)
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image, .audio]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK { model.importToBin(panel.urls) }
    }
}

private struct BinTile: View {
    let url: URL
    let uses: Int
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Ink.well)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: EditorModel.isAudioFile(url) ? "waveform" : (EditorModel.isImageFile(url) ? "photo" : "film"))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if uses > 0 {
                    Text("\(uses)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.85)))
                        .padding(4)
                        .help("Used \(uses) time\(uses == 1 ? "" : "s") on the timeline")
                }
            }
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: url) {
            guard !EditorModel.isAudioFile(url) else { return }
            image = await MediaCache.thumbnail(for: url, maxSide: 240)
        }
    }
}

/// Shown when a project's files were moved: find them, then open.
struct RelinkSheet: View {
    @EnvironmentObject var model: EditorModel
    @State private var message = ""

    var body: some View {
        let missing = model.relink?.missing ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text("Find moved files").font(.system(size: 15, weight: .semibold))
            Text(missing.isEmpty ? "Everything's found." : "This project uses \(missing.count) file\(missing.count == 1 ? "" : "s") that moved. Pick the folder they're in now and Eddie will find them by name.")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !missing.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(missing, id: \.self) { url in
                            HStack {
                                Image(systemName: "questionmark.square.dashed").foregroundStyle(Ink.tertiary)
                                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Locate…") { locate(url) }.controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(Ink.secondary) }
            HStack {
                Button("Search a Folder…") { searchFolder() }.disabled(missing.isEmpty)
                Spacer()
                Button("Cancel") { model.relink = nil }.keyboardShortcut(.cancelAction)
                Button(missing.isEmpty ? "Open" : "Open Without Them") { model.finishRelink() }
                    .keyboardShortcut(.defaultAction)
                    .tint(Color(white: 0.32))
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private func searchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search Here"
        if panel.runModal() == .OK, let url = panel.url {
            let n = model.relinkSearch(in: url)
            message = n == 0 ? "Nothing matching in \(url.lastPathComponent)." : "Found \(n)."
        }
    }

    private func locate(_ old: URL) {
        let panel = NSOpenPanel()
        panel.message = "Where is \(old.lastPathComponent)?"
        panel.prompt = "Use This File"
        if panel.runModal() == .OK, let url = panel.url { model.relinkFile(old, to: url) }
    }
}

/// Reads file URLs out of a drag from Finder.
enum FileDrop {
    @MainActor
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
            }) { urls.append(url) }
        }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
