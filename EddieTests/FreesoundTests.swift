import XCTest
@testable import Eddie

/// The Freesound sound effects library: only sounds free for any video, with credits kept.
final class FreesoundTests: XCTestCase {
    let json = """
    {"count":3,"next":"https://freesound.org/apiv2/search/text/?page=2","previous":null,"results":[
      {"id":101,"name":"Whoosh fast.wav","username":"alice","license":"http://creativecommons.org/publicdomain/zero/1.0/",
       "duration":0.8,"previews":{"preview-hq-mp3":"https://cdn.freesound.org/previews/0/101_hq.mp3","preview-lq-mp3":"https://cdn.freesound.org/previews/0/101_lq.mp3"},
       "images":{"waveform_m":"https://cdn.freesound.org/displays/0/101_wave_M.png"},"tags":["whoosh","fast"]},
      {"id":102,"name":"Pop","username":"bob","license":"https://creativecommons.org/licenses/by/4.0/",
       "duration":0.3,"previews":{"preview-hq-mp3":"https://cdn.freesound.org/previews/0/102_hq.mp3"}},
      {"id":103,"name":"Not for ads","username":"carol","license":"https://creativecommons.org/licenses/by-nc/4.0/",
       "duration":2,"previews":{"preview-hq-mp3":"https://cdn.freesound.org/previews/0/103_hq.mp3"}}
    ]}
    """

    func testOnlyFreeForAnyVideo() throws {
        let r = try Freesound.parse(Data(json.utf8))
        XCTAssertTrue(r.more)
        XCTAssertEqual(r.sounds.map(\.id), [101, 102], "non-commercial sounds are left out")
        XCTAssertEqual(r.sounds[0].license, .cc0)
        XCTAssertEqual(r.sounds[1].license, .by)
        XCTAssertEqual(r.sounds[0].name, "Whoosh fast", "file extensions are dropped from names")
        XCTAssertEqual(r.sounds[0].preview.lastPathComponent, "101_hq.mp3")
        XCTAssertNotNil(r.sounds[0].waveform)
        XCTAssertNil(Freesound.License(url: "https://creativecommons.org/licenses/sampling+/1.0/"))
    }

    func testCreditsTravelWithTheProject() throws {
        let sounds = try Freesound.parse(Data(json.utf8)).sounds
        var p = Project()
        XCTAssertNil(Freesound.credits(for: p))
        var a = MusicItem(url: URL(fileURLWithPath: "/tmp/a.mp3"), start: 0, sourceEnd: 1)
        a.kind = .effect
        a.credit = sounds[1].credit
        p.music = [a, a]
        let credits = try XCTUnwrap(Freesound.credits(for: p))
        XCTAssertTrue(credits.contains("“Pop” by bob (https://freesound.org/s/102/) — CC BY 4.0"))
        XCTAssertEqual(credits.components(separatedBy: "• ").count - 1, 1, "each sound is credited once")
        // Saved and reopened, the credit is still there; older projects without it still open.
        let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(reopened.music.first?.credit, a.credit)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        old.removeValue(forKey: "credit")
        XCTAssertNil(try JSONDecoder().decode(MusicItem.self, from: JSONSerialization.data(withJSONObject: old)).credit)
    }

    func testNoKeyInSourceBuilds() {
        XCTAssertFalse(Freesound.hasBuiltInKey)
    }
}
