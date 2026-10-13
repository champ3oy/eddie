import SwiftUI

/// The Projects screen: every saved project as a card. Click to open, right-click for more.
struct ProjectsView: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject var library: ProjectLibrary
    @State private var toDelete: ProjectInfo?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 22)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects").font(.system(size: 26, weight: .bold)).foregroundStyle(Ink.primary)
                if !library.projects.isEmpty {
                    Text("\(library.projects.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.tertiary)
                }
                Spacer()
                newButton
            }

            if library.projects.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(library.projects) { info in
                            ProjectCard(info: info, library: library) { model.openProject(id: info.id) }
                                .contextMenu { menu(info) }
                        }
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .onAppear { library.reload() }
        .alert("Move “\(toDelete?.name ?? "")” to the Trash?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let id = toDelete?.id { try? library.delete(id) }
                toDelete = nil
            }
            Button("Cancel", role: .cancel) { toDelete = nil }
        } message: {
            Text("Your videos aren't touched — only the edit is removed. You can get it back from the Trash.")
        }
    }

    @ViewBuilder private var newButton: some View {
        if #available(macOS 26.0, *) {
            Button { model.createProject() } label: { Label("New Project", systemImage: "plus") }
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            Button { model.createProject() } label: { Label("New Project", systemImage: "plus") }
                .controlSize(.large)
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image("Mascot").resizable().frame(width: 72, height: 72)
            Text("No projects yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.primary)
            Text("Create one, or drop videos here to start.").font(.system(size: 13)).foregroundStyle(Ink.secondary)
            newButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(_ info: ProjectInfo) -> some View {
        Button("Open") { model.openProject(id: info.id) }
        Button("Rename…") {
            if let name = Panels.askName(title: "Rename Project", current: info.name) { try? library.rename(info.id, to: name) }
        }
        Button("Duplicate") { _ = try? library.duplicate(info.id) }
        Button("Show in Finder") { library.revealInFinder(info.id) }
        Divider()
        Button("Move to Trash…", role: .destructive) { toDelete = info }
    }
}

private struct ProjectCard: View {
    let info: ProjectInfo
    @ObservedObject var library: ProjectLibrary
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.well)
                    if let image = thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film").font(.system(size: 26, weight: .light)).foregroundStyle(Ink.tertiary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovering ? 0.55 : 0.08), lineWidth: hovering ? 2 : 1)
                )
                .scaleEffect(hovering ? 1.015 : 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var thumbnail: NSImage? {
        _ = library.thumbnailVersion   // reload when a thumbnail is rewritten
        return NSImage(contentsOf: library.thumbnailURL(info.id))
    }

    private var subtitle: String {
        var parts: [String] = []
        if info.clipCount > 0 {
            parts.append("\(info.clipCount) clip\(info.clipCount == 1 ? "" : "s")")
            let s = Int(info.duration.rounded())
            parts.append(String(format: "%d:%02d", s / 60, s % 60))
        } else {
            parts.append("Empty")
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        parts.append("Edited " + f.localizedString(for: info.modified, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }
}
