import XCTest

final class ResolverAccessTests: XCTestCase {
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDNSTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdDirs.append(url)
        return url
    }

    private func makeBookmarkURL() -> URL {
        makeTempDir().appendingPathComponent("resolver.bookmark")
    }

    func testTerminalCommandShape() {
        XCTAssertTrue(ResolverAccess.terminalCommand.contains("mkdir -p /etc/resolver"))
        XCTAssertTrue(ResolverAccess.terminalCommand.contains("chmod +a"))
        XCTAssertTrue(ResolverAccess.terminalCommand.contains("$USER"))
        XCTAssertTrue(ResolverAccess.terminalCommand.contains("add_file"))
        XCTAssertTrue(ResolverAccess.terminalCommand.contains("delete_child"))
    }

    func testSaveResolveRoundTrip() throws {
        let target = makeTempDir()          // stands in for /etc/resolver
        let bookmarkURL = makeBookmarkURL()

        try ResolverAccess.saveBookmark(for: target, to: bookmarkURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarkURL.path))

        let resolved = ResolverAccess.resolveBookmark(from: bookmarkURL)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.standardizedFileURL.path, target.standardizedFileURL.path)
        XCTAssertEqual(ResolverAccess.activeAccessURL?.path, resolved?.path)
    }

    func testResolveMissingBookmarkIsNil() {
        let bookmarkURL = makeTempDir().appendingPathComponent("never-written.bookmark")
        XCTAssertNil(ResolverAccess.resolveBookmark(from: bookmarkURL))
    }

    func testResolveCorruptBookmarkIsNil() {
        let bookmarkURL = makeBookmarkURL()
        try! Data("not a bookmark".utf8).write(to: bookmarkURL)
        XCTAssertNil(ResolverAccess.resolveBookmark(from: bookmarkURL))
    }

    func testClearBookmark() throws {
        let target = makeTempDir()
        let bookmarkURL = makeBookmarkURL()
        try ResolverAccess.saveBookmark(for: target, to: bookmarkURL)
        ResolverAccess.clearBookmark(at: bookmarkURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookmarkURL.path))
        XCTAssertNil(ResolverAccess.activeAccessURL)
        XCTAssertNil(ResolverAccess.resolveBookmark(from: bookmarkURL))
    }
}
