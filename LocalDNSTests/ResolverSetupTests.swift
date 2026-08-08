import XCTest

final class ResolverSetupTests: XCTestCase {
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
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

    /// A path inside a temp parent, but the resolver dir itself is NOT created.
    private func makeMissingDir() -> URL {
        let parent = makeTempDir()
        return parent.appendingPathComponent("resolver", isDirectory: true)
    }

    private func write(_ content: String, _ name: String, in dir: URL) {
        try! content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: Zone derivation

    func testDesiredZones() {
        let rules = [
            DNSRule(pattern: "*.MyApp.TEST", ipv4: "172.30.0.3"),              // wildcard, normalized
            DNSRule(pattern: "host.exact.test", ipv4: "10.0.0.1"),             // exact → own zone
            DNSRule(pattern: "*.off.test", ipv4: "10.0.0.2", enabled: false),  // disabled → skipped
            DNSRule(pattern: "*.myapp.test.", ipv4: "172.30.0.9"),             // dup after normalize
        ]
        XCTAssertEqual(ResolverSetup.desiredZones(for: rules),
                       ["myapp.test", "host.exact.test"])
    }

    // MARK: File content

    func testFileContent() {
        XCTAssertEqual(ResolverSetup.fileContent(zone: "myapp.test", port: 15353),
                       "# LocalDNS\nnameserver 127.0.0.1\nport 15353\n")
    }

    // MARK: Scanning

    func testInstalledZonesMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(ResolverSetup.installedOwnedZones(resolverDir: missing), [])
        XCTAssertEqual(ResolverSetup.installedForeignZones(resolverDir: missing), [])
    }

    func testInstalledZonesDistinguishesOwnedFromForeign() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "owned.test", port: 15353), "owned.test", in: dir)
        write("nameserver 8.8.8.8\n", "foreign.test", in: dir)
        write("", "empty.test", in: dir)
        // marker present but NOT on the first line → foreign
        write("nameserver 127.0.0.1\n# LocalDNS\n", "sneaky.test", in: dir)

        XCTAssertEqual(ResolverSetup.installedOwnedZones(resolverDir: dir), ["owned.test"])
        XCTAssertEqual(ResolverSetup.installedForeignZones(resolverDir: dir),
                       ["foreign.test", "empty.test", "sneaky.test"])
    }

    // MARK: Planning

    func testPlanInstallsNewZones() {
        let dir = makeTempDir()
        let plan = ResolverSetup.plan(rules: [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")],
                                      port: 15353, resolverDir: dir)
        XCTAssertEqual(plan.installs, ["myapp.test"])
        XCTAssertEqual(plan.removals, [])
        XCTAssertEqual(plan.conflicts, [])
        XCTAssertFalse(plan.isNoop)
    }

    func testPlanIsNoopWhenCurrent() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "myapp.test", port: 15353), "myapp.test", in: dir)
        let plan = ResolverSetup.plan(rules: [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")],
                                      port: 15353, resolverDir: dir)
        XCTAssertTrue(plan.isNoop)
        XCTAssertEqual(plan.conflicts, [])
    }

    func testPlanReinstallsStaleOwnedFile() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "myapp.test", port: 9999), "myapp.test", in: dir) // wrong port
        let plan = ResolverSetup.plan(rules: [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")],
                                      port: 15353, resolverDir: dir)
        XCTAssertEqual(plan.installs, ["myapp.test"])
        XCTAssertEqual(plan.removals, [])
    }

    func testPlanRemovesOnlyOwnedStaleZones() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "old.test", port: 15353), "old.test", in: dir)
        write("nameserver 8.8.8.8\n", "keep.test", in: dir) // foreign: never removed
        let plan = ResolverSetup.plan(rules: [], port: 15353, resolverDir: dir)
        XCTAssertEqual(plan.removals, ["old.test"])
        XCTAssertEqual(plan.installs, [])
    }

    func testPlanReportsConflictForForeignZone() {
        let dir = makeTempDir()
        write("nameserver 10.1.2.3\n", "myapp.test", in: dir) // foreign file for a desired zone
        let plan = ResolverSetup.plan(rules: [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")],
                                      port: 15353, resolverDir: dir)
        XCTAssertEqual(plan.conflicts, ["myapp.test"])
        XCTAssertEqual(plan.installs, [])
        XCTAssertTrue(plan.isNoop)
    }

    // MARK: Direct-write sync

    func testSyncWritesNewFiles() {
        let dir = makeTempDir()
        let rules = [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")]
        let outcome = ResolverSetup.sync(rules: rules, port: 15353, resolverDir: dir)
        XCTAssertEqual(outcome, .applied(conflicts: []))
        XCTAssertEqual(read("myapp.test", in: dir),
                       ResolverSetup.fileContent(zone: "myapp.test", port: 15353))
        XCTAssertEqual(ResolverSetup.installedOwnedZones(resolverDir: dir), ["myapp.test"])
    }

    func testSyncRewritesStaleOwnedContent() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "myapp.test", port: 9999), "myapp.test", in: dir)
        let rules = [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")]
        let outcome = ResolverSetup.sync(rules: rules, port: 15353, resolverDir: dir)
        XCTAssertEqual(outcome, .applied(conflicts: []))
        XCTAssertEqual(read("myapp.test", in: dir),
                       ResolverSetup.fileContent(zone: "myapp.test", port: 15353))
    }

    func testSyncDeletesOnlyOwnedStaleFiles() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "old.test", port: 15353), "old.test", in: dir)
        write("nameserver 8.8.8.8\n", "keep.test", in: dir)
        let outcome = ResolverSetup.sync(rules: [], port: 15353, resolverDir: dir)
        XCTAssertEqual(outcome, .applied(conflicts: []))
        XCTAssertNil(read("old.test", in: dir))
        XCTAssertEqual(read("keep.test", in: dir), "nameserver 8.8.8.8\n") // foreign untouched
    }

    func testSyncReportsConflictAndLeavesForeignUntouched() {
        let dir = makeTempDir()
        write("nameserver 10.1.2.3\n", "myapp.test", in: dir) // foreign file for a desired zone
        let rules = [
            DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3"),
            DNSRule(pattern: "*.other.test", ipv4: "10.0.0.9"),
        ]
        let outcome = ResolverSetup.sync(rules: rules, port: 15353, resolverDir: dir)
        XCTAssertEqual(outcome, .applied(conflicts: ["myapp.test"]))
        XCTAssertEqual(read("myapp.test", in: dir), "nameserver 10.1.2.3\n") // not overwritten
        XCTAssertNotNil(read("other.test", in: dir)) // non-conflicted zone installed
    }

    func testSyncConflictOnlyIsUpToDateWithConflicts() {
        let dir = makeTempDir()
        write("nameserver 10.1.2.3\n", "myapp.test", in: dir)
        let rules = [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")]
        let outcome = ResolverSetup.sync(rules: rules, port: 15353, resolverDir: dir)
        XCTAssertEqual(outcome, .upToDate(conflicts: ["myapp.test"]))
        XCTAssertEqual(read("myapp.test", in: dir), "nameserver 10.1.2.3\n")
    }

    func testSyncMissingDirectoryIsAccessDenied() {
        let missing = makeMissingDir()
        let rules = [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")]
        let outcome = ResolverSetup.sync(rules: rules, port: 15353, resolverDir: missing)
        XCTAssertEqual(outcome, .accessDenied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path)) // never created
    }

    func testSyncNoopWhenCurrent() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "myapp.test", port: 15353), "myapp.test", in: dir)
        let rules = [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")]
        XCTAssertEqual(ResolverSetup.sync(rules: rules, port: 15353, resolverDir: dir),
                       .upToDate(conflicts: []))
    }

    // MARK: uninstallAll

    func testUninstallAllRemovesOwnedOnly() {
        let dir = makeTempDir()
        write(ResolverSetup.fileContent(zone: "a.test", port: 15353), "a.test", in: dir)
        write(ResolverSetup.fileContent(zone: "b.test", port: 15353), "b.test", in: dir)
        write("nameserver 8.8.8.8\n", "keep.test", in: dir)
        let outcome = ResolverSetup.uninstallAll(resolverDir: dir)
        XCTAssertEqual(outcome, .applied(conflicts: []))
        XCTAssertEqual(ResolverSetup.installedOwnedZones(resolverDir: dir), [])
        XCTAssertEqual(read("keep.test", in: dir), "nameserver 8.8.8.8\n")
    }

    func testUninstallAllMissingDirectoryIsAccessDenied() {
        XCTAssertEqual(ResolverSetup.uninstallAll(resolverDir: makeMissingDir()), .accessDenied)
    }

    func testUninstallAllNothingOwnedIsUpToDate() {
        let dir = makeTempDir()
        write("nameserver 8.8.8.8\n", "keep.test", in: dir)
        XCTAssertEqual(ResolverSetup.uninstallAll(resolverDir: dir), .upToDate(conflicts: []))
        XCTAssertEqual(read("keep.test", in: dir), "nameserver 8.8.8.8\n")
    }

    // MARK: probeAccess

    func testProbeAccessWritableDirectory() {
        let dir = makeTempDir()
        XCTAssertTrue(ResolverSetup.probeAccess(resolverDir: dir))
        // leaves nothing behind
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
    }

    func testProbeAccessMissingDirectory() {
        XCTAssertFalse(ResolverSetup.probeAccess(resolverDir: makeMissingDir()))
    }

    func testProbeAccessReadOnlyDirectory() {
        let dir = makeTempDir()
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertFalse(ResolverSetup.probeAccess(resolverDir: dir))
        // tearDown restores 0o755 before deleting
    }
}
