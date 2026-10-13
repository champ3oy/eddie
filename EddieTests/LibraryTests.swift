import XCTest
@testable import Eddie

@MainActor
final class LibraryTests: XCTestCase {
    func tempLibrary() -> ProjectLibrary {
        ProjectLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent("EddieLib-\(UUID().uuidString)"))
    }

    func testCreateSaveReadRenameDuplicateDelete() throws {
        let lib = tempLibrary()
        let a = try lib.create()
        let b = try lib.create()
        XCTAssertEqual(a.name, "Untitled Project")
        XCTAssertEqual(b.name, "Untitled Project 2", "names stay unique")

        var p = Project()
        p.clips = [ClipItem(url: URL(fileURLWithPath: "/tmp/x.mov"), sourceStart: 0, sourceEnd: 3)]
        try lib.save(p, id: a.id)
        XCTAssertEqual(try lib.read(a.id), p)
        XCTAssertEqual(lib.info(a.id)?.clipCount, 1)
        XCTAssertEqual(lib.projects.first?.id, a.id, "most recently edited first")

        try lib.rename(a.id, to: "Beach day")
        XCTAssertEqual(lib.info(a.id)?.name, "Beach day")

        let copy = try lib.duplicate(a.id)
        XCTAssertEqual(copy.name, "Beach day copy")
        XCTAssertEqual(try lib.read(copy.id), p)

        try lib.delete(b.id)
        XCTAssertNil(lib.info(b.id))
        XCTAssertEqual(lib.projects.count, 2)

        // A fresh library on the same folder sees the same projects (it's all on disk).
        let reopened = ProjectLibrary(root: lib.root)
        XCTAssertEqual(Set(reopened.projects.map(\.name)), ["Beach day", "Beach day copy"])
    }

    func testEditSaveComeBackAndContinue() async throws {
        let lib = tempLibrary()
        let videoURL = Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!

        // Session 1: make a project, add a clip, grade it, add a title.
        let first = EditorModel(library: lib)
        first.createProject()
        let id = try XCTUnwrap(first.currentProjectID)
        first.addClips([videoURL])
        for _ in 0..<100 where first.project.clips.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        var r = GradeRecipe(); r.exposure = 0.4
        first.setRecipe(r, resetIntensity: true)
        first.addTitle()
        first.saveNow()

        // Session 2: a new app launch opens it from the Projects screen.
        let second = EditorModel(library: ProjectLibrary(root: lib.root))
        XCTAssertTrue(second.showingLibrary)
        XCTAssertEqual(second.library.projects.map(\.id), [id])
        second.openProject(id: id)
        for _ in 0..<100 where second.project.clips.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(second.showingLibrary)
        XCTAssertEqual(second.project.clips.first?.recipe.exposure, 0.4)
        XCTAssertEqual(second.project.titles.count, 1)
        XCTAssertNotNil(second.player.currentItem, "ready to keep editing")

        // Opening alone isn't an edit.
        let modified = second.library.info(id)!.modified
        second.saveNow()
        XCTAssertEqual(second.library.info(id)!.modified, modified)
    }

    func testMissingVideosAskToRelink() async throws {
        let lib = tempLibrary()
        let info = try lib.create(name: "Old trip")
        var p = Project()
        p.clips = [ClipItem(url: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID()).mov"), sourceStart: 0, sourceEnd: 2)]
        try lib.save(p, id: info.id)
        let model = EditorModel(library: lib)
        model.openProject(id: info.id)
        XCTAssertEqual(model.relink?.missing.first?.lastPathComponent.hasPrefix("does-not-exist"), true)
        XCTAssertTrue(model.showingLibrary, "stays on the Projects screen until the files are found")
        // Pointing it at the file opens the project with the new location.
        let real = Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")!
        model.relinkFile(model.relink!.missing[0], to: real)
        model.finishRelink()
        for _ in 0..<60 where model.showingLibrary { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.showingLibrary)
        XCTAssertEqual(model.project.clips.first?.url, real)
        XCTAssertEqual(try lib.read(info.id).clips.first?.url, real, "the fix is saved")
    }
}
