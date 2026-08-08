import XCTest

final class DNSMessageTests: XCTestCase {

    /// A wire query for "Foo.MyApp.TEST", type A, class IN, id 0x1234, RD set.
    private func makeQuery() -> Data {
        var data = Data()
        data.append(contentsOf: [0x12, 0x34])             // ID
        data.append(contentsOf: [0x01, 0x00])             // flags: RD
        data.append(contentsOf: [0x00, 0x01])             // QDCOUNT = 1
        data.append(contentsOf: [0x00, 0x00])             // ANCOUNT
        data.append(contentsOf: [0x00, 0x00])             // NSCOUNT
        data.append(contentsOf: [0x00, 0x00])             // ARCOUNT
        data.append(3); data.append(contentsOf: Array("Foo".utf8))
        data.append(5); data.append(contentsOf: Array("MyApp".utf8))
        data.append(4); data.append(contentsOf: Array("TEST".utf8))
        data.append(0)
        data.append(contentsOf: [0x00, 0x01])             // QTYPE = A
        data.append(contentsOf: [0x00, 0x01])             // QCLASS = IN
        return data
    }

    private func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    func testParseQueryNormalizesName() throws {
        let query = try DNSMessage.parseQuery(makeQuery())
        XCTAssertEqual(query.id, 0x1234)
        XCTAssertEqual(query.name, "foo.myapp.test")
        XCTAssertEqual(query.qtype, DNSMessage.typeA)
        XCTAssertEqual(query.qclass, DNSMessage.classIN)
        XCTAssertTrue(query.wantsRecursion)
    }

    func testAResponseBytesRoundTrip() throws {
        let query = try DNSMessage.parseQuery(makeQuery())
        let answer = DNSAnswer(qtype: DNSMessage.typeA, ttl: 60, rdata: Data([172, 30, 0, 3]))
        let bytes = [UInt8](DNSResponseBuilder.response(to: query, answers: [answer]))

        XCTAssertEqual(u16(bytes, 0), 0x1234)      // ID copied
        XCTAssertEqual(u16(bytes, 2), 0x8100)      // QR + RD, RA=0, RCODE=0
        XCTAssertEqual(u16(bytes, 4), 1)           // QDCOUNT
        XCTAssertEqual(u16(bytes, 6), 1)           // ANCOUNT
        XCTAssertEqual(u16(bytes, 8), 0)           // NSCOUNT
        XCTAssertEqual(u16(bytes, 10), 0)          // ARCOUNT

        // Question echoed verbatim from the original packet
        let queryBytes = [UInt8](makeQuery())
        XCTAssertEqual(Array(bytes[12 ..< queryBytes.count]), Array(queryBytes[12...]))

        // Answer record
        var offset = queryBytes.count
        XCTAssertEqual(u16(bytes, offset), 0xC00C) // owner name = pointer to first question
        offset += 2
        XCTAssertEqual(u16(bytes, offset), 1)      // TYPE A
        offset += 2
        XCTAssertEqual(u16(bytes, offset), 1)      // CLASS IN
        offset += 2
        XCTAssertEqual(u16(bytes, offset) << 16 | u16(bytes, offset + 2), 60) // TTL
        offset += 4
        XCTAssertEqual(u16(bytes, offset), 4)      // RDLENGTH
        offset += 2
        XCTAssertEqual(Array(bytes[offset ..< offset + 4]), [172, 30, 0, 3]) // RDATA
        XCTAssertEqual(bytes.count, offset + 4)    // nothing trailing
    }

    func testCompressionPointerInQuestionDecodes() throws {
        // Question name: "www" followed by a pointer to offset 35,
        // where the labels "example"."com" live later in the packet.
        var data = Data(repeating: 0, count: 12)
        data[0] = 0xAB; data[1] = 0xCD             // ID
        data[2] = 0x01                             // RD
        data[5] = 1                                // QDCOUNT
        data.append(3); data.append(contentsOf: Array("www".utf8))
        data.append(contentsOf: [0xC0, 0x23])       // pointer to offset 35
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // QTYPE A, QCLASS IN
        while data.count < 35 { data.append(0xFF) }
        data.append(7); data.append(contentsOf: Array("example".utf8))
        data.append(3); data.append(contentsOf: Array("com".utf8))
        data.append(0)

        let query = try DNSMessage.parseQuery(data)
        XCTAssertEqual(query.id, 0xABCD)
        XCTAssertEqual(query.name, "www.example.com")
        XCTAssertEqual(query.qtype, DNSMessage.typeA)
    }

    func testNXDOMAINResponse() throws {
        let query = try DNSMessage.parseQuery(makeQuery())
        let bytes = [UInt8](DNSResponseBuilder.nxdomain(to: query))
        XCTAssertEqual(u16(bytes, 0), 0x1234)      // ID copied
        XCTAssertEqual(bytes[2] & 0x80, 0x80)      // QR set
        XCTAssertEqual(bytes[2] & 0x01, 0x01)      // RD copied
        XCTAssertEqual(bytes[3] & 0x0F, 3)         // RCODE = NXDOMAIN
        XCTAssertEqual(u16(bytes, 6), 0)           // ANCOUNT = 0
        XCTAssertEqual(u16(bytes, 4), 1)           // QDCOUNT = 1
    }

    func testRefusedResponse() throws {
        let query = try DNSMessage.parseQuery(makeQuery())
        let bytes = [UInt8](DNSResponseBuilder.refused(to: query))
        XCTAssertEqual(bytes[3] & 0x0F, 5)         // RCODE = REFUSED
    }

    func testEmptyResponseIsNoErrorNoAnswers() throws {
        let query = try DNSMessage.parseQuery(makeQuery())
        let bytes = [UInt8](DNSResponseBuilder.empty(to: query))
        XCTAssertEqual(bytes[3] & 0x0F, 0)         // RCODE = NOERROR
        XCTAssertEqual(u16(bytes, 6), 0)           // ANCOUNT = 0 (NODATA)
    }

    func testPointerLoopIsRejected() {
        var data = Data(repeating: 0, count: 12)
        data[5] = 1                                // QDCOUNT
        data.append(contentsOf: [0xC0, 0x0C])       // name = pointer to itself
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        XCTAssertThrowsError(try DNSMessage.parseQuery(data)) { error in
            XCTAssertEqual(error as? DNSParseError, .pointerLoop)
        }
    }

    func testTruncatedPacketsAreRejected() {
        XCTAssertThrowsError(try DNSMessage.parseQuery(Data([0x00, 0x01]))) { error in
            XCTAssertEqual(error as? DNSParseError, .packetTooShort)
        }
        // Header says one question, but the packet ends right after it starts
        var data = Data(repeating: 0, count: 12)
        data[5] = 1
        data.append(3); data.append(contentsOf: Array("ab".utf8))
        XCTAssertThrowsError(try DNSMessage.parseQuery(data)) { error in
            XCTAssertEqual(error as? DNSParseError, .packetTooShort)
        }
    }

    func testNoQuestionIsRejected() {
        let data = Data(repeating: 0, count: 12)   // QDCOUNT = 0
        XCTAssertThrowsError(try DNSMessage.parseQuery(data)) { error in
            XCTAssertEqual(error as? DNSParseError, .missingQuestion)
        }
    }

    /// Modern resolvers (including macOS and dig) attach an EDNS OPT pseudo-record
    /// in the additional section. The parser must tolerate it, and the response
    /// must stay well-formed (ARCOUNT = 0, question echoed verbatim).
    func testQueryWithEDNSAdditionalRecordIsTolerated() throws {
        var data = makeQuery()
        data[11] = 1                               // ARCOUNT = 1
        data.append(0)                             // NAME = root
        data.append(contentsOf: [0x00, 0x29])      // TYPE = OPT (41)
        data.append(contentsOf: [0x04, 0xD0])      // CLASS = UDP payload 1232
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // TTL (ext-rcode/flags)
        data.append(contentsOf: [0x00, 0x00])      // RDLENGTH = 0
        let query = try DNSMessage.parseQuery(data)
        XCTAssertEqual(query.name, "foo.myapp.test")

        let answer = DNSAnswer(qtype: DNSMessage.typeA, ttl: 60, rdata: Data([172, 30, 0, 3]))
        let bytes = [UInt8](DNSResponseBuilder.response(to: query, answers: [answer]))
        XCTAssertEqual(u16(bytes, 10), 0)          // response ARCOUNT = 0
        // Echoed question matches the original question bytes (not the OPT tail).
        let original = [UInt8](makeQuery())
        XCTAssertEqual(Array(bytes[12 ..< original.count]), Array(original[12...]))
    }
}
