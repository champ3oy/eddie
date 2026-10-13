import AppKit
import Foundation

/// What the Projects screen shows for each project.
struct ProjectInfo: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var created: Date
    var modified: Date
    var duration: Double = 0
    var clipCount = 0
}

/// Projects saved on this Mac, one folder each:
///   ~/Library/Application Support/Eddie/Projects/<id>/project.json  — the edit
///                                                    /info.json     — name, dates, summary
///                                                    /thumbnail.jpg — first frame, graded
/// Videos stay where they are; projects only point to them.
@MainActor
final class ProjectLibrary: ObservableObject {
    static let shared = ProjectLibrary(root: ProjectLibrary.defaultRoot)

    /// The user's library — or a throwaway folder when running inside the test suite, so tests never touch real projects.
    static var defaultRoot: URL {
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["EDDIE_DEMO_OUT"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("EddieTestLibrary-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eddie/Projects", isDirectory: true)
    }

    let root: URL
    @Published private(set) var projects: [ProjectInfo] = []
    /// Bumped when a thumbnail changes, so the grid reloads images.
    @Published private(set) var thumbnailVersion = 0

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func projectFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("project.json") }
    private func infoFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("info.json") }
    func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumbnail.jpg") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Rescans the projects folder; newest edits first.
    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        projects = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")) else { return nil }
            return try? Self.decoder.decode(ProjectInfo.self, from: data)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// A new, empty project with a unique "Untitled Project" name.
    func create(name: String? = nil) throws -> ProjectInfo {
        let now = Date()
        let info = ProjectInfo(id: UUID(), name: name ?? uniqueName("Untitled Project"), created: now, modified: now)
        try write(Project(), info: info)
        reload()
        return info
    }

    func read(_ id: UUID) throws -> Project {
        // Waits for any autosave still being written, so this reads the latest.
        let url = projectFile(id)
        return try Self.decoder.decode(Project.self, from: Self.io.sync { try Data(contentsOf: url) })
    }

    func info(_ id: UUID) -> ProjectInfo? { projects.first { $0.id == id } }

    /// Saves the edit (and optionally a new thumbnail), updating the summary and modified date.
    /// `background`: encode and write off the main thread (autosave), in order with every other write.
    func save(_ project: Project, id: UUID, thumbnail: CGImage? = nil, background: Bool = false) throws {
        var info = self.info(id) ?? ProjectInfo(id: id, name: uniqueName("Untitled Project"), created: Date(), modified: Date())
        info.modified = Date()
        info.duration = project.duration
        info.clipCount = project.clips.count
        if background {
            let folder = folder(id), projectFile = projectFile(id), infoFile = infoFile(id), thumbURL = thumbnailURL(id)
            nonisolated(unsafe) let thumb = thumbnail
            Self.io.async {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Self.ioEncoder.encode(project).write(to: projectFile, options: .atomic)
                    try Self.ioEncoder.encode(info).write(to: infoFile, options: .atomic)
                    if let thumb { try Self.jpeg(thumb)?.write(to: thumbURL, options: .atomic) }
                } catch {
                    NSLog("Eddie: autosave failed: \(error.localizedDescription)")
                }
                if thumb != nil { DispatchQueue.main.async { MainActor.assumeIsolated { self.thumbnailVersion += 1 } } }
            }
        } else {
            try write(project, info: info)
            if let thumbnail { try writeThumbnail(thumbnail, id: id) }
        }
        if let i = projects.firstIndex(where: { $0.id == id }) {
            projects[i] = info
            projects.sort { $0.modified > $1.modified }
        } else {
            reload()
        }
    }

    /// Replaces just the thumbnail (doesn't count as an edit).
    func updateThumbnail(_ image: CGImage, id: UUID, background: Bool = false) throws {
        guard background else { try writeThumbnail(image, id: id); return }
        let url = thumbnailURL(id)
        nonisolated(unsafe) let image = image
        Self.io.async {
            try? Self.jpeg(image)?.write(to: url, options: .atomic)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.thumbnailVersion += 1 } }
        }
    }

    /// Project writes happen here, one at a time, so a background autosave never lands after a later save.
    private nonisolated static let io = DispatchQueue(label: "eddie.library.io", qos: .utility)
    private nonisolated static let ioEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    func rename(_ id: UUID, to name: String) throws {
        guard var info = info(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        info.name = trimmed
        let data = try Self.encoder.encode(info), url = infoFile(id)
        try Self.io.sync { try data.write(to: url, options: .atomic) }
        reload()
    }

    func duplicate(_ id: UUID) throws -> ProjectInfo {
        guard let original = info(id) else { throw CocoaError(.fileNoSuchFile) }
        let project = try read(id)
        let now = Date()
        let copy = ProjectInfo(id: UUID(), name: uniqueName("\(original.name) copy"), created: now, modified: now,
                               duration: original.duration, clipCount: original.clipCount)
        try write(project, info: copy)
        if FileManager.default.fileExists(atPath: thumbnailURL(id).path) {
            try? FileManager.default.copyItem(at: thumbnailURL(id), to: thumbnailURL(copy.id))
        }
        reload()
        return copy
    }

    /// Moves the project folder to the Trash (recoverable). Never touches the videos it uses.
    func delete(_ id: UUID) throws {
        let url = folder(id)
        try Self.io.sync { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        reload()
    }

    func revealInFinder(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([folder(id)])
    }

    /// Copies a standalone .eddie file into the library.
    func importFile(_ url: URL) throws -> ProjectInfo {
        let project = try Self.decoder.decode(Project.self, from: Data(contentsOf: url))
        let now = Date()
        let info = ProjectInfo(id: UUID(), name: uniqueName(url.deletingPathExtension().lastPathComponent), created: now,
                               modified: now, duration: project.duration, clipCount: project.clips.count)
        try write(project, info: info)
        reload()
        return info
    }

    func exportFile(_ id: UUID, to url: URL) throws {
        try Self.encoder.encode(read(id)).write(to: url, options: .atomic)
    }

    // MARK: Private

    private func write(_ project: Project, info: ProjectInfo) throws {
        let folder = folder(info.id), projectFile = projectFile(info.id), infoFile = infoFile(info.id)
        let projectData = try Self.encoder.encode(project), infoData = try Self.encoder.encode(info)
        try Self.io.sync {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try projectData.write(to: projectFile, options: .atomic)
            try infoData.write(to: infoFile, options: .atomic)
        }
    }

    private func writeThumbnail(_ image: CGImage, id: UUID) throws {
        guard let data = Self.jpeg(image) else { return }
        let url = thumbnailURL(id)
        try Self.io.sync { try data.write(to: url, options: .atomic) }
        thumbnailVersion += 1
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(projects.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
