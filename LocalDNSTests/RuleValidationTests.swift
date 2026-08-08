import XCTest

final class RuleValidationTests: XCTestCase {

    // MARK: Existing syntax behavior (preserved from the sheet's validator)

    func testValidPatternsPass() {
        XCTAssertNil(RuleValidation.patternError(for: "*.myapp.test"))
        XCTAssertNil(RuleValidation.patternError(for: "host.test"))
        XCTAssertNil(RuleValidation.patternError(for: "*.local.selfmade.codes"))
        XCTAssertNil(RuleValidation.patternError(for: "  *.spaced.test  ")) // trimmed
    }

    func testSyntaxErrors() {
        XCTAssertNotNil(RuleValidation.patternError(for: ""))
        XCTAssertNotNil(RuleValidation.patternError(for: "bad pattern"))     // space
        XCTAssertNotNil(RuleValidation.patternError(for: "foo.*.test"))      // * mid-name
        XCTAssertNotNil(RuleValidation.patternError(for: "single"))          // < 2 labels
        XCTAssertNotNil(RuleValidation.patternError(for: "a..test"))         // empty label
        XCTAssertNotNil(RuleValidation.patternError(for: "-a.test"))         // leading -
        XCTAssertNotNil(RuleValidation.patternError(for: "a-.test"))         // trailing -
        XCTAssertNotNil(RuleValidation.patternError(for: "münchen.test"))    // non-ascii
    }

    // MARK: Public-suffix foot-guns

    /// Single-label TLDs are already rejected by the two-label minimum.
    func testTLDWildcardsAreBlocked() {
        XCTAssertNotNil(RuleValidation.patternError(for: "*.com"))
        XCTAssertNotNil(RuleValidation.patternError(for: "*.test"))
        XCTAssertNotNil(RuleValidation.patternError(for: "*.local"))
        XCTAssertNotNil(RuleValidation.patternError(for: "*.in"))
    }

    /// Multi-label public suffixes pass the two-label check but must still be
    /// blocked — wildcarding them breaks ordinary browsing.
    func testPublicSuffixWildcardsAreBlocked() {
        for suffix in ["co.uk", "com.au", "co.in", "com.br"] {
                XCTAssertNotNil(RuleValidation.patternError(for: "*.\(suffix)"),
                                "*.\(suffix) should be blocked")
        }
    }

    /// Wildcarding YOUR OWN zone under a public suffix is fine.
    func testOwnZoneUnderPublicSuffixIsAllowed() {
        XCTAssertNil(RuleValidation.patternError(for: "*.myapp.co.uk"))
    }

    /// Exact rules on public suffixes are not blocked (they only claim one name;
    /// the zone-wide effect is a documented trade-off).
    func testExactRuleOnPublicSuffixIsAllowed() {
        XCTAssertNil(RuleValidation.patternError(for: "host.co.uk"))
    }

    // MARK: .local warning

    func testUsesLocalTLD() {
        XCTAssertTrue(RuleValidation.usesLocalTLD("*.myapp.local"))
        XCTAssertTrue(RuleValidation.usesLocalTLD("host.local"))
        XCTAssertTrue(RuleValidation.usesLocalTLD("*.deep.myapp.local"))
        XCTAssertFalse(RuleValidation.usesLocalTLD("*.myapp.test"))
        XCTAssertFalse(RuleValidation.usesLocalTLD("local.selfmade.codes")) // not the TLD
        XCTAssertFalse(RuleValidation.usesLocalTLD("*.localselfmade.codes"))
    }
}
