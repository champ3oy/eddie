import SwiftUI
import UniformTypeIdentifiers

@main
struct EddieApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = EditorModel.shared

    init() {
        Self.forgetOversizedWindow()
    }

    /// Early builds opened nearly full screen and macOS remembers that size. Once, before the window
    /// exists, drop a remembered size that's bigger than the new default so the smaller one applies.
    private static func forgetOversizedWindow() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "windowSizeReset.v2") else { return }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("NSWindow Frame") {
            let parts = (value as? String)?.split(separator: " ").compactMap { Double($0) } ?? []
            if parts.count >= 4, parts[2] > 1280 || parts[3] > 820 { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: "windowSizeReset.v2")
    }

    /// Sends ⌘X/C/V/A to a focused text field instead of the timeline. Returns true if it did.
    @MainActor static func forwardToTextField(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        // First launch: about three-quarters of the screen, centered (never bigger than 1280 × 820).
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect.size
            let size = CGSize(width: min(1280, max(980, screen.width * 0.74)),
                              height: min(820, max(640, screen.height * 0.78)))
            return WindowPlacement(.center, size: size)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.createProject() }.keyboardShortcut("n")
                Button("Show Projects") { model.showProjects() }.keyboardShortcut("0")
                Button("Rename Project…") { Panels.renameProject(model) }
                    .disabled(model.currentProjectID == nil || model.showingLibrary)
                Divider()
                Button("Import Project File…") { Panels.importProject(model) }
                Divider()
                Button("Add Clips…") { Panels.addClips(model) }.keyboardShortcut("i")
                Button("Add Overlay…") { Panels.addOverlay(model) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.hasProject)
                Button("Add Sound Effect…") { Panels.addMusic(model, kind: .effect) }
                    .disabled(!model.hasProject)
                Button(model.recorder.isRecording ? "Stop Recording" : "Record Voiceover") { model.toggleVoiceover() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.hasProject)
                Button("Add Music…") { Panels.addMusic(model) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                    .disabled(!model.hasProject)
            }
            CommandGroup(replacing: .saveItem) {
                // Projects save themselves; ⌘S just saves right away.
                Button("Save") { model.saveNow() }
                    .keyboardShortcut("s")
                    .disabled(model.currentProjectID == nil)
                Button("Export Project File…") { Panels.exportProjectFile(model) }
                    .disabled(model.currentProjectID == nil)
                Divider()
                Button("Export Video…") { Panels.export(model) }
                    .keyboardShortcut("e")
                    .disabled(!model.hasProject)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { if !Self.forwardToTextField(#selector(NSText.cut(_:))) { model.cutSelection() } }
                    .keyboardShortcut("x")
                Button("Copy") { if !Self.forwardToTextField(#selector(NSText.copy(_:))) { model.copySelection() } }
                    .keyboardShortcut("c")
                Button("Paste") { if !Self.forwardToTextField(#selector(NSText.paste(_:))) { model.paste() } }
                    .keyboardShortcut("v")
                Button("Select All") { if !Self.forwardToTextField(#selector(NSText.selectAll(_:))) { model.selectAll() } }
                    .keyboardShortcut("a")
                Divider()
                Picker("Paste and Drop", selection: $model.editMode) {
                    Text("Insert (push clips along)").tag(EditorModel.EditMode.insert)
                    Text("Overwrite (replace what's there)").tag(EditorModel.EditMode.overwrite)
                }
            }
            CommandMenu("Clip") {
                Button("Add Title") { model.addTitle() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(!model.hasProject)
                Button(model.captioning ? "Making Captions…" : "Auto Captions") { model.autoCaptions() }
                    .disabled(!model.hasProject || model.captioning)
                Button("Remove Auto Captions") { model.removeCaptions() }
                    .disabled(!model.project.titles.contains { $0.isCaption })
                Button(model.snapping ? "Turn Snapping Off  (N)" : "Turn Snapping On  (N)") { model.snapping.toggle() }
                Divider()
                Button("Split at Playhead") { model.splitAtPlayhead() }
                    .keyboardShortcut("b")
                    .disabled(!model.hasProject)
                Button("Duplicate") { model.duplicateSelection() }
                    .keyboardShortcut("d")
                    .disabled(model.selectedClip == nil)
                Button(model.bladeMode ? "Blade Tool On  (B)" : "Blade Tool  (B)") { model.bladeMode.toggle() }
                Button("Freeze Frame") { model.freezeFrame() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.hasProject)
                Button(model.selectedClip?.reversed == true ? "Play Forwards" : "Reverse") { model.toggleReverse() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.selectedClip == nil || model.selectedClip?.isPhoto == true)
                Button("Add Marker  (M)") { model.addMarker() }
                    .disabled(!model.hasProject)
                Button("Delete  (⌫)") { model.deleteSelection() }
                    .disabled(model.selection == nil)
                Divider()
                Menu("Speed") {
                    ForEach(ClipItem.speeds, id: \.self) { s in
                        Button(TimelineView.speedLabel(s)) { model.setSpeed(s) }
                    }
                }
                .disabled(model.selectedClip == nil)
                Button(model.selectedClip?.audioMuted == true ? "Unmute Clip Audio" : "Mute Clip Audio") { model.toggleClipAudio() }
                    .disabled(model.selectedClip == nil)
                Divider()
                Button("Auto Grade All Clips") { model.autoGradeAll() }
                    .disabled(!model.hasProject || model.busy)
            }
            CommandMenu("Playback") {
                // Space, ← and → also work when no text field is being edited (see AppDelegate).
                Button("Play / Pause  (Space)") { model.togglePlay() }
                    .disabled(!model.hasProject)
                Button("Previous Frame  (←)") { model.step(frames: -1) }
                    .disabled(!model.hasProject)
                Button("Next Frame  (→)") { model.step(frames: 1) }
                    .disabled(!model.hasProject)
                Divider()
                Button("Compare Before / After") { model.compare.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!model.hasProject)
                Divider()
                Button("Zoom In") { NotificationCenter.default.post(name: .timelineZoom, object: CGFloat(1.5)) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { NotificationCenter.default.post(name: .timelineZoom, object: CGFloat(1 / 1.5)) }
                    .keyboardShortcut("-")
                // ⇧Z is handled in the key monitor so it never steals a capital Z from a text field.
                Button("Zoom to Fit  (⇧Z)") { NotificationCenter.default.post(name: .timelineZoom, object: CGFloat(0)) }
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// Opens videos dropped on the Dock icon or chosen with "Open With".
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { EditorModel.shared.saveNow() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DemoDirector.startIfRequested()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if DemoDirector.requested { DemoAnchors.enabled = true }
        Self.migrateSettings()
        // Dark only: windows, menus, popovers and Settings.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installPlaybackKeys()
    }

    /// Settings saved under the app's earlier identifier (provider, model names, LUT, panels) are copied over once.
    private static func migrateSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromOldIdentifier"),
              let old = UserDefaults(suiteName: "co.morpheusgh.eddie")?.persistentDomain(forName: "co.morpheusgh.eddie") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedFromOldIdentifier")
    }

    /// Space plays/pauses, ←/→ step one frame, ⌫ deletes the selection, J/K/L shuttle, M marker, B blade,
    /// ↑/↓ jump between cuts and markers — unless the user is typing in a text field.
    private var keyMonitor: Any?
    private func installPlaybackKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            let model = MainActor.assumeIsolated { EditorModel.shared }
            if MainActor.assumeIsolated({ model.showingLibrary }) { return event }
            switch event.keyCode {
            case 49: MainActor.assumeIsolated { model.togglePlay() }
            case 123: MainActor.assumeIsolated { model.step(frames: -1) }
            case 124: MainActor.assumeIsolated { model.step(frames: 1) }
            case 51, 117: MainActor.assumeIsolated { model.deleteSelection() }   // ⌫, ⌦
            case 45: MainActor.assumeIsolated { model.snapping.toggle() }        // N
            case 38: MainActor.assumeIsolated { model.shuttle("j") }
            case 40: MainActor.assumeIsolated { model.shuttle("k") }
            case 37: MainActor.assumeIsolated { model.shuttle("l") }
            case 6 where event.modifierFlags.contains(.shift):                  // ⇧Z
                NotificationCenter.default.post(name: .timelineZoom, object: CGFloat(0))
            case 46: MainActor.assumeIsolated { model.addMarker() }              // M
            case 11: MainActor.assumeIsolated { model.bladeMode.toggle() }       // B
            case 0: MainActor.assumeIsolated { model.bladeMode = false }         // A — back to the select tool
            case 53: MainActor.assumeIsolated {                                   // esc
                if model.recorder.isRecording { model.toggleVoiceover() }
                model.bladeMode = false
                model.extraSelection = []
            }
            case 126: MainActor.assumeIsolated { model.jump(forward: false) }    // ↑ previous cut / marker
            case 125: MainActor.assumeIsolated { model.jump(forward: true) }     // ↓ next cut / marker
            default: return event
            }
            return MainActor.assumeIsolated { model.hasProject } ? nil : event
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let model = EditorModel.shared
            if let project = urls.first(where: { $0.pathExtension == "eddie" }) { model.importProjectFile(project) }
            else { model.addClips(urls) }
        }
    }
}

@MainActor
enum Panels {
    static let projectType = UTType(filenameExtension: "eddie") ?? .json

    static func addClips(_ model: EditorModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { model.addClips(panel.urls) }
    }

    static func addOverlay(_ model: EditorModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.prompt = "Add Overlay"
        if panel.runModal() == .OK, let url = panel.url { model.addOverlay(url) }
    }

    /// Kept for the empty screen: same as adding clips.
    static func open(_ model: EditorModel) { addClips(model) }

    static func addMusic(_ model: EditorModel, kind: MusicItem.Kind = .music) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = kind == .effect
        panel.prompt = "Add"
        if panel.runModal() == .OK { for url in panel.urls { model.addMusic(url, kind: kind) } }
    }

    static func exportProjectFile(_ model: EditorModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectType]
        panel.nameFieldStringValue = (model.fileName.isEmpty ? "Untitled" : model.fileName) + ".eddie"
        if panel.runModal() == .OK, let url = panel.url { model.exportProjectFile(to: url) }
    }

    static func importProject(_ model: EditorModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        if panel.runModal() == .OK, let url = panel.url { model.importProjectFile(url) }
    }

    static func renameProject(_ model: EditorModel) {
        guard let id = model.currentProjectID, let info = model.library.info(id) else { return }
        if let name = askName(title: "Rename Project", current: info.name) { model.renameCurrentProject(name) }
    }

    /// A small native prompt for a name.
    static func askName(title: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Opens the export sheet (format, size, frame rate), which then asks where to save.
    static func export(_ model: EditorModel) {
        guard model.hasProject else { return }
        model.showingExport = true
    }

    static func saveExport(_ model: EditorModel, settings: ExportSettings) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.codec == .h264 ? .mpeg4Movie : .quickTimeMovie]
        let base = (model.fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "video" : base).\(settings.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url, settings: settings) }
    }

    static func chooseLUT(_ model: EditorModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { model.useLUT(at: url) }
    }
}
