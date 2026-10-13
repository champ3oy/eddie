import AppKit
import SwiftUI

/// The sticker picker: every emoji (browse by category or search by name), plus GIPHY stickers and GIFs.
struct StickerPicker: View {
    let pickEmoji: (String) -> Void
    let pickGiphy: (Giphy.Item, Giphy.Kind) -> Void

    enum Tab: String, CaseIterable { case emoji = "Emoji", stickers = "Stickers", gifs = "GIFs" }
    @AppStorage("stickerTab") private var tab = Tab.emoji
    @State private var query = ""
    @FocusState private var focused: Bool

    static let width: CGFloat = 8 * 34 + 7 * 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            searchField

            switch tab {
            case .emoji: EmojiGrid(query: query, pick: pickEmoji)
            case .stickers: GiphyGrid(query: query, kind: .stickers, pick: { pickGiphy($0, .stickers) })
            case .gifs: GiphyGrid(query: query, kind: .gifs, pick: { pickGiphy($0, .gifs) })
            }
        }
        .frame(width: Self.width)
        .padding(10)
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Ink.tertiary)
            TextField(tab == .emoji ? "Search emoji" : "Search GIPHY", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit {
                    if tab == .emoji, let first = EmojiCatalog.search(query).first { pickEmoji(first) }
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

// MARK: Emoji

private struct EmojiGrid: View {
    let query: String
    let pick: (String) -> Void
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8)

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    section("Favorites", EditorModel.stickerEmoji)
                    ForEach(EmojiCatalog.byGroup, id: \.group) { g in section(g.group, g.emoji) }
                }
            } else {
                let results = EmojiCatalog.search(query)
                if results.isEmpty {
                    Text("No emoji for “\(query)”").font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) { ForEach(results, id: \.self, content: cell) }
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(height: 8 * 38)
    }

    private func section(_ title: String, _ emoji: [String]) -> some View {
        Section {
            ForEach(emoji, id: \.self, content: cell)
        } header: {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .background(.regularMaterial)
        }
    }

    private func cell(_ e: String) -> some View {
        Button { pick(e) } label: {
            Text(e).font(.system(size: 24)).frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(EmojiCatalog.name(of: e) ?? e)
    }
}

// MARK: GIPHY

private struct GiphyGrid: View {
    let query: String
    let kind: Giphy.Kind
    let pick: (Giphy.Item) -> Void
    @State private var items: [Giphy.Item] = []
    @State private var error: String?
    @State private var loading = false
    @State private var exhausted = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: kind == .gifs ? 3 : 4)
    }

    var body: some View {
        VStack(spacing: 6) {
            if !Giphy.hasKey {
                VStack(spacing: 8) {
                    Text("Add your GIPHY API key in Settings to search stickers and GIFs.")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    SettingsLink { Text("Open Settings") }
                }
                .frame(maxWidth: .infinity, minHeight: 8 * 38)
            } else if let error, items.isEmpty {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 8 * 38)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(items) { item in
                            Button { pick(item) } label: {
                                AnimatedPreview(url: item.preview)
                                    .aspectRatio(1, contentMode: .fit)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(kind == .gifs ? 0.06 : 0.03)))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.title)
                            .onAppear { if item.id == items.last?.id { Task { await load(more: true) } } }
                        }
                    }
                    if loading { ProgressView().controlSize(.small).padding(6) }
                }
                .frame(height: 8 * 38)
            }
            // GIPHY's terms ask for this on every screen that shows their results.
            Text("Powered by GIPHY").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // Waits for a pause in typing before searching.
        .task(id: "\(kind.rawValue)|\(query)") {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 350))
            guard !Task.isCancelled else { return }
            await load(more: false)
        }
    }

    private func load(more: Bool) async {
        guard Giphy.hasKey, !loading, !(more && exhausted) else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await Giphy.search(query, kind: kind, offset: more ? items.count : 0)
            if more {
                let known = Set(items.map(\.id))
                items += page.filter { !known.contains($0.id) }
            } else {
                items = page
            }
            exhausted = page.isEmpty
            error = items.isEmpty ? "Nothing on GIPHY for “\(query)”." : nil
        } catch {
            if !more { items = [] }
            self.error = error.localizedDescription
        }
    }
}

/// A small looping GIF (AppKit's image view animates GIFs; SwiftUI's Image doesn't).
struct AnimatedPreview: NSViewRepresentable {
    let url: URL
    private static let cache = NSCache<NSURL, NSImage>()

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        guard v.identifier?.rawValue != url.absoluteString else { return }
        v.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        if let hit = Self.cache.object(forKey: url as NSURL) { v.image = hit; return }
        v.image = nil
        let url = self.url
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            Self.cache.setObject(image, forKey: url as NSURL)
            if v.identifier?.rawValue == url.absoluteString { v.image = image }
        }
    }
}
