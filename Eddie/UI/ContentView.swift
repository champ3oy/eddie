import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: EditorModel
    @State private var showInspector = true
    @State private var dropTargeted = false
    @AppStorage("showMediaBin") private var showMedia = false
    @AppStorage("showCaptions") private var showCaptions = false
    /// The timeline's height limit chosen by dragging the handle above it (0 = automatic).
    @AppStorage("timelineHeight") private var timelineHeight = 0.0
    @State private var timelineShown: CGFloat = 0
    @State private var resizeStart: CGFloat?

    /// The line between the video and the timeline: drag it to give the timeline more or less room.
    /// Double-click goes back to automatic.
    private func resizeHandle(ceiling: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if resizeStart == nil { resizeStart = timelineShown }
                    timelineHeight = Double(min(max(160, (resizeStart ?? timelineShown) - v.translation.height), ceiling))
                }
                .onEnded { _ in resizeStart = nil })
            .onTapGesture(count: 2) { timelineHeight = 0 }
            .help("Drag to resize the timeline · double-click for automatic")
    }

    var body: some View {
        Group {
            if model.showingLibrary {
                ProjectsView(library: model.library)
            } else if model.hasProject {
                HStack(spacing: 0) {
                    if showCaptions {
                        CaptionsPanel()
                            .frame(width: 270)
                        Divider()
                    } else if showMedia {
                        MediaBinView()
                            .frame(width: 200)
                        Divider()
                    }
                    // The editor takes whatever width is left (it never pushes the panels off screen).
                    GeometryReader { geo in
                        // Automatically up to 45% of the height; dragged, whatever you chose (the video keeps at least 180 pt).
                        let ceiling = max(160, geo.size.height - 180)
                        let limit = timelineHeight > 0 ? min(max(timelineHeight, 160), ceiling) : min(ceiling, geo.size.height * 0.45)
                        VStack(spacing: 0) {
                            ViewerView()
                            resizeHandle(ceiling: ceiling)
                            TimelineView(clock: model.clock, maxHeight: limit)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timelineShown = $0 }
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
            } else {
                EmptyStateView(targeted: dropTargeted)
            }
        }
        .background(Color.black)
        .inspector(isPresented: Binding(get: { showInspector && !model.showingLibrary }, set: { showInspector = $0 })) {
            InspectorView()
                .inspectorColumnWidth(min: 270, ideal: 290, max: 380)
        }
        .toolbarBackground(Color.black, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .navigationTitle(model.showingLibrary ? "Eddie" : (model.fileName.isEmpty ? "Eddie" : model.fileName))
        .navigationSubtitle(model.showingLibrary ? "" : subtitle)
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            Task { @MainActor in
                let urls = await FileDrop.urls(from: providers)
                guard !urls.isEmpty else { return }
                // On the Projects screen a drop starts a new project; in the editor it adds to this one.
                if model.showingLibrary { model.createProject() }
                model.addClips(urls)
            }
            return true
        }
        .sheet(isPresented: $model.showingExport) { ExportSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingSoundLibrary) { SoundLibrarySheet().environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.relink != nil }, set: { if !$0 { model.relink = nil } })) {
            RelinkSheet().environmentObject(model)
        }
        .alert("Couldn't open the video", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var subtitle: String {
        guard model.hasProject else { return "" }
        let s = Int(model.project.duration.rounded())
        let n = model.project.clips.count
        return "\(n) clip\(n == 1 ? "" : "s") · \(Int(model.projectSize.width))×\(Int(model.projectSize.height)) · \(Int(model.frameRate.rounded())) fps · \(s / 60):\(String(format: "%02d", s % 60))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !model.showingLibrary {
        ToolbarItem(placement: .navigation) {
            Button { model.showProjects() } label: { Label("Projects", systemImage: "square.grid.2x2") }
                .help("All projects (⌘0) — this one is saved automatically")
        }
        ToolbarItem(placement: .navigation) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showMedia.toggle(); if showMedia { showCaptions = false } } } label: { Label("Media", systemImage: "photo.on.rectangle") }
                .help("Show or hide this project's media")
                .disabled(!model.hasProject)
        }
        ToolbarItem(placement: .navigation) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showCaptions.toggle(); if showCaptions { showMedia = false } } } label: { Label("Captions", systemImage: "captions.bubble") }
                .help("Captions: auto, typed or imported; styles, translation and the transcript")
                .disabled(!model.hasProject)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: Binding(
                get: { model.compare ? 2 : (model.mode == .original ? 0 : 1) },
                set: { v in
                    model.compare = v == 2
                    model.mode = v == 0 ? .original : .graded
                })) {
                Text("Original").tag(0)
                Text("Graded").tag(1)
                Text("Split").tag(2)
            }
            .pickerStyle(.segmented)
            .help("Show the camera original, the grade, or both side by side (⌘B)")
            .disabled(!model.hasProject)
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
            Button { Panels.export(model) } label: { ExportLabel(activity: model.activity) }
            .disabled(!model.hasProject || model.exportProgress != nil)
            .help("Export the graded video (⌘E)")
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector")
        }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var targeted: Bool
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 18) {
            Image("Mascot")
                .resizable()
                .frame(width: 72, height: 72)
            Text("Drop your video here")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.primary)
            openButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(targeted ? Color.white.opacity(0.5) : .clear)
                .padding(20)
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    @ViewBuilder private var openButton: some View {
        if #available(macOS 26.0, *) {
            Button("Open Video…") { Panels.open(model) }
                .demoAnchor("open-video")
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            Button("Open Video…") { Panels.open(model) }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }
}

/// The toolbar's Export button title; shows the percentage while exporting.
private struct ExportLabel: View {
    @ObservedObject var activity: Activity
    var body: some View {
        if let p = activity.exportProgress {
            Label("Exporting \(Int(p * 100))%", systemImage: "square.and.arrow.up")
        } else {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }
}
