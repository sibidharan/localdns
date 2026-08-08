import XCTest

final class HostsImporterTests: XCTestCase {

    // MARK: Parsing

    func testParseBasics() {
        let text = """
        # full-line comment
        127.0.0.1 localhost
        172.30.0.3 api.myapp.test web.myapp.test # inline comment
        172.30.0.3\tdb.myapp.test

        ::1 ip6-localhost
        """
        let entries = HostsImporter.parse(text)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0], HostsEntry(ip: "127.0.0.1", names: ["localhost"]))
        XCTAssertEqual(entries[1], HostsEntry(ip: "172.30.0.3", names: ["api.myapp.test", "web.myapp.test"]))
        XCTAssertEqual(entries[2], HostsEntry(ip: "172.30.0.3", names: ["db.myapp.test"]))
        XCTAssertEqual(entries[3], HostsEntry(ip: "::1", names: ["ip6-localhost"]))
    }

    func testParseNormalizesNames() {
        let entries = HostsImporter.parse("10.0.0.5 UPPER.Test.\n")
        XCTAssertEqual(entries.first?.names, ["upper.test"])
    }

    func testParseSkipsBlankCommentAndAddressOnlyLines() {
        XCTAssertEqual(HostsImporter.parse("\n# nothing\n   \n\t\n10.0.0.1\n"), [])
    }

    // MARK: Suggestions

    func testSuggestionsGroupByAddressAndParent() {
        let entries = HostsImporter.parse("""
        172.30.0.3 api.myapp.test web.myapp.test
        172.30.0.3 db.myapp.test
        10.0.0.2 api.other.test web.other.test
        172.30.0.3 a.else.test b.else.test
        10.0.0.9 solo.test
        9.9.9.9 singlelabel
        """)
        let suggestions = HostsImporter.suggestions(entries: entries)
        XCTAssertEqual(suggestions.count, 3)

        let myapp = suggestions.first { $0.pattern == "*.myapp.test" }
        XCTAssertEqual(myapp?.ip, "172.30.0.3")
        XCTAssertEqual(myapp?.coveredHostnames, ["api.myapp.test", "db.myapp.test", "web.myapp.test"])
        XCTAssertEqual(myapp?.rule.ipv4, "172.30.0.3")
        XCTAssertEqual(myapp?.rule.group, "Imported")

        XCTAssertNotNil(suggestions.first { $0.pattern == "*.other.test" && $0.ip == "10.0.0.2" })
        XCTAssertNotNil(suggestions.first { $0.pattern == "*.else.test" && $0.ip == "172.30.0.3" })
        // one-host groups and single-label names never yield suggestions
        XCTAssertNil(suggestions.first { $0.pattern == "*.test" })
    }

    func testSuggestionsSkipIgnoredEntries() {
        let entries = HostsImporter.parse("""
        127.0.0.1 localhost
        255.255.255.255 broadcasthost
        ::1 localhost
        255.255.255.255 foo.bar.test baz.bar.test
        """)
        XCTAssertEqual(HostsImporter.suggestions(entries: entries), [])
    }

    func testIPv6Suggestion() {
        let entries = HostsImporter.parse("fd00::3 a.v6.test b.v6.test\n")
        let suggestions = HostsImporter.suggestions(entries: entries)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].pattern, "*.v6.test")
        XCTAssertEqual(suggestions[0].rule.ipv6, "fd00::3")
        XCTAssertNil(suggestions[0].rule.ipv4)
    }

    // MARK: Coverage

    func testUncovered() {
        let entries = HostsImporter.parse("""
        172.30.0.3 api.myapp.test db.myapp.test
        10.0.0.2 stray.other.test
        127.0.0.1 localhost
        9.9.9.9 singlelabel
        """)
        let rules = [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")]
        XCTAssertEqual(HostsImporter.uncovered(entries: entries, rules: rules), ["stray.other.test"])
        // a disabled rule covers nothing
        let disabled = [DNSRule(pattern: "*.myapp.test", ipv4: "1.2.3.4", enabled: false)]
        XCTAssertEqual(HostsImporter.uncovered(entries: entries, rules: disabled),
                       ["api.myapp.test", "db.myapp.test", "stray.other.test"])
    }
}
