import XCTest

@testable import osasfom_cadCore

/// The recent-projects list behind the welcome screen. Ordering, duplicates
/// and pruning are exactly the parts that look trivial and then quietly go
/// wrong, so they are pinned here rather than left to the UI.
final class RecentProjectsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "osasfom_cad.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(limit: Int = RecentProjects.defaultLimit) -> RecentProjects {
        RecentProjects(defaults: defaults, key: "recents", limit: limit)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/osasfom/\(name).osasfomcad")
    }

    func testMostRecentlyRecordedComesFirst() {
        let store = makeStore()
        store.record(url("a"))
        store.record(url("b"))
        store.record(url("c"))

        XCTAssertEqual(store.entries.map(\.name), ["c", "b", "a"])
    }

    /// Re-opening a project must move it up, not add a second row.
    func testRecordingTheSameProjectAgainMovesItToTheFront() {
        let store = makeStore()
        store.record(url("a"))
        store.record(url("b"))
        store.record(url("a"))

        XCTAssertEqual(store.entries.map(\.name), ["a", "b"])
        XCTAssertEqual(store.entries.count, 2, "no duplicate row")
    }

    /// The same file reached by a non-canonical path is the same project.
    func testPathsAreStandardizedBeforeComparing() {
        let store = makeStore()
        store.record(URL(fileURLWithPath: "/tmp/osasfom/a.osasfomcad"))
        store.record(URL(fileURLWithPath: "/tmp/osasfom/./a.osasfomcad"))

        XCTAssertEqual(store.entries.count, 1)
    }

    func testListIsCappedAtTheLimitDroppingTheOldest() {
        let store = makeStore(limit: 3)
        for name in ["a", "b", "c", "d", "e"] { store.record(url(name)) }

        XCTAssertEqual(store.entries.map(\.name), ["e", "d", "c"])
    }

    func testEntriesSurviveAcrossInstances() {
        let first = makeStore()
        first.record(url("saved"))

        let second = makeStore()
        XCTAssertEqual(second.entries.map(\.name), ["saved"])
    }

    func testRemoveDropsOnlyThatEntry() {
        let store = makeStore()
        store.record(url("a"))
        store.record(url("b"))

        store.remove(url("a"))
        XCTAssertEqual(store.entries.map(\.name), ["b"])
    }

    func testClearEmptiesTheListAndPersistsThat() {
        let store = makeStore()
        store.record(url("a"))
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(makeStore().entries.isEmpty, "clearing has to stick")
    }

    /// A deleted project stays listed but is marked, so the row can explain
    /// itself instead of silently disappearing.
    func testMissingFilesAreFlaggedButNotDroppedAutomatically() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let present = directory.appendingPathComponent("here.osasfomcad")
        try Data("{}".utf8).write(to: present)
        let absent = directory.appendingPathComponent("gone.osasfomcad")

        let store = makeStore()
        store.record(present)
        store.record(absent)

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(try XCTUnwrap(store.entries.first { $0.name == "gone" }).stillExists)
        XCTAssertTrue(try XCTUnwrap(store.entries.first { $0.name == "here" }).stillExists)

        store.removeMissing()
        XCTAssertEqual(store.entries.map(\.name), ["here"])

        try FileManager.default.removeItem(at: directory)
    }

    func testEntryNameAndLocationAreReadable() {
        let store = makeStore()
        store.record(URL(fileURLWithPath: "/Users/someone/Desktop/patch.osasfomcad"))

        let entry = store.entries[0]
        XCTAssertEqual(entry.name, "patch", "extension stripped")
        XCTAssertEqual(entry.location, "/Users/someone/Desktop")
    }

    /// A corrupt preference should cost the recent list, not the launch.
    func testGarbageInStorageDecodesToAnEmptyListInsteadOfCrashing() {
        defaults.set(["not a dictionary", 42, ["opened": 1.0]], forKey: "recents")

        XCTAssertTrue(makeStore().entries.isEmpty)
    }
}
