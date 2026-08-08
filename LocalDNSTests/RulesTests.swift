import XCTest

final class RulesTests: XCTestCase {

    private func makeQuery(_ name: String, qtype: UInt16 = DNSMessage.typeA) -> DNSQuery {
        DNSQuery(id: 1, name: DNSRule.normalize(name), qtype: qtype)
    }

    // MARK: Matching

    func testWildcardMatchesApexAndDeepSubdomains() {
        let rule = DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")
        XCTAssertTrue(rule.matches(name: "myapp.test"))        // apex itself
        XCTAssertTrue(rule.matches(name: "api.myapp.test"))
        XCTAssertTrue(rule.matches(name: "a.b.c.myapp.test"))  // any depth
        XCTAssertTrue(rule.matches(name: "API.MyApp.TEST."))   // normalization
        XCTAssertFalse(rule.matches(name: "other.test"))
        XCTAssertFalse(rule.matches(name: "notmyapp.test"))
        XCTAssertFalse(rule.matches(name: "myapp.test.evil.com"))
    }

    func testExactRuleMatchesOnlyEqualNames() {
        let rule = DNSRule(pattern: "host.test", ipv4: "10.0.0.1")
        XCTAssertTrue(rule.matches(name: "host.test"))
        XCTAssertTrue(rule.matches(name: "HOST.test."))
        XCTAssertFalse(rule.matches(name: "sub.host.test"))
        XCTAssertFalse(rule.matches(name: "host.testx"))
    }

    func testRuleDefaults() {
        let rule = DNSRule(pattern: "x.test")
        XCTAssertEqual(rule.ttl, 60)
        XCTAssertEqual(rule.group, "Default")
        XCTAssertTrue(rule.enabled)
        XCTAssertNil(rule.ipv4)
        XCTAssertNil(rule.ipv6)
    }

    // MARK: Resolution

    func testLongestPatternWins() {
        let broad = DNSRule(pattern: "*.test", ipv4: "10.0.0.1")
        let specific = DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")
        let rules = [broad, specific]

        guard case .answers(let hit) = DNSResolver.resolve(makeQuery("api.myapp.test"), rules: rules) else {
            return XCTFail("expected answers for api.myapp.test")
        }
        XCTAssertEqual(hit.first?.rdata, Data([172, 30, 0, 3]))

        guard case .answers(let other) = DNSResolver.resolve(makeQuery("elsewhere.test"), rules: rules) else {
            return XCTFail("expected answers for elsewhere.test")
        }
        XCTAssertEqual(other.first?.rdata, Data([10, 0, 0, 1]))
    }

    func testDisabledRuleIsSkipped() {
        let rule = DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3", enabled: false)
        XCTAssertEqual(DNSResolver.resolve(makeQuery("api.myapp.test"), rules: [rule]), .nxdomain)
    }

    func testWrongFamilyYieldsNoData() {
        let v4only = DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")
        XCTAssertEqual(DNSResolver.resolve(makeQuery("api.myapp.test", qtype: DNSMessage.typeAAAA),
                                         rules: [v4only]), .noData)
        let v6only = DNSRule(pattern: "*.myapp.test", ipv6: "fd00::3")
        XCTAssertEqual(DNSResolver.resolve(makeQuery("api.myapp.test"),
                                         rules: [v6only]), .noData)
    }

    func testRightFamilyYieldsAnswer() {
        let rule = DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3", ipv6: "fd00::3", ttl: 120)
        guard case .answers(let answers) = DNSResolver.resolve(makeQuery("api.myapp.test"), rules: [rule]) else {
            return XCTFail("expected A answer")
        }
        XCTAssertEqual(answers, [DNSAnswer(qtype: DNSMessage.typeA, ttl: 120, rdata: Data([172, 30, 0, 3]))])

        guard case .answers(let v6) = DNSResolver.resolve(makeQuery("api.myapp.test", qtype: DNSMessage.typeAAAA),
                                                          rules: [rule]) else {
            return XCTFail("expected AAAA answer")
        }
        XCTAssertEqual(v6.count, 1)
        XCTAssertEqual(v6[0].qtype, DNSMessage.typeAAAA)
        XCTAssertEqual(v6[0].rdata.count, 16)
    }

    func testInvalidIPAddressYieldsNoData() {
        let rule = DNSRule(pattern: "bad.test", ipv4: "999.1.2.3")
        XCTAssertEqual(DNSResolver.resolve(makeQuery("bad.test"), rules: [rule]), .noData)
    }

    func testUnsupportedQueryTypeIsNoDataWhenNameMatches() {
        let rule = DNSRule(pattern: "*.test", ipv4: "10.0.0.1")
        XCTAssertEqual(DNSResolver.resolve(makeQuery("x.test", qtype: 15), rules: [rule]), .noData) // MX
    }

    func testUnknownNameIsNXDOMAIN() {
        let rule = DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")
        XCTAssertEqual(DNSResolver.resolve(makeQuery("other.example"), rules: [rule]), .nxdomain)
        XCTAssertEqual(DNSResolver.resolve(makeQuery("api.myapp.test"), rules: []), .nxdomain)
    }

    // MARK: RuleStore

    func testRuleStoreSaveLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")

        let rules = [
            DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3", ttl: 120, group: "Docker"),
            DNSRule(pattern: "exact.test", ipv6: "fd00::1", enabled: false),
        ]
        try RuleStore(fileURL: file, rules: rules).save()

        let loaded = RuleStore(fileURL: file)
        XCTAssertEqual(loaded.rules, rules)
    }

    func testRuleStoreStartsEmptyWhenFileMissing() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("rules.json")
        XCTAssertEqual(RuleStore(fileURL: file).rules, [])
    }
}
