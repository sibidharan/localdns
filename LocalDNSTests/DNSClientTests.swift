import Network
import XCTest

final class DNSClientTests: XCTestCase {

    func testEncodeQueryRoundTripsThroughParser() throws {
        let packet = try XCTUnwrap(DNSClient.encodeQuery(id: 0x4242, name: "Foo.MyApp.TEST", qtype: DNSMessage.typeA))
        let parsed = try DNSMessage.parseQuery(packet)
        XCTAssertEqual(parsed.id, 0x4242)
        XCTAssertEqual(parsed.name, "foo.myapp.test")
        XCTAssertEqual(parsed.qtype, DNSMessage.typeA)
        XCTAssertEqual(parsed.qclass, DNSMessage.classIN)
        XCTAssertTrue(parsed.wantsRecursion)
    }

    func testEncodeRejectsBadNames() {
        XCTAssertNil(DNSClient.encodeQuery(id: 1, name: "", qtype: DNSMessage.typeA))
        XCTAssertNil(DNSClient.encodeQuery(id: 1, name: ".", qtype: DNSMessage.typeA))
        let longLabel = String(repeating: "a", count: 64) + ".test"
        XCTAssertNil(DNSClient.encodeQuery(id: 1, name: longLabel, qtype: DNSMessage.typeA))
    }

    func testParseAResponse() throws {
        let queryPacket = try XCTUnwrap(DNSClient.encodeQuery(id: 7, name: "api.myapp.test", qtype: DNSMessage.typeA))
        let query = try DNSMessage.parseQuery(queryPacket)
        let response = DNSResponseBuilder.response(to: query, answers: [
            DNSAnswer(qtype: DNSMessage.typeA, ttl: 60, rdata: Data([172, 30, 0, 3])),
        ])
        let result = try DNSClient.parseResponse(response, expectedID: 7)
        XCTAssertEqual(result.rcode, 0)
        XCTAssertEqual(result.answers, ["172.30.0.3"])
    }

    func testParseAAAAResponse() throws {
        let queryPacket = try XCTUnwrap(DNSClient.encodeQuery(id: 8, name: "v6.test", qtype: DNSMessage.typeAAAA))
        let query = try DNSMessage.parseQuery(queryPacket)
        let response = DNSResponseBuilder.response(to: query, answers: [
            DNSAnswer(qtype: DNSMessage.typeAAAA, ttl: 60, rdata: IPv6Address("fd00::1")!.rawValue),
        ])
        let result = try DNSClient.parseResponse(response, expectedID: 8)
        XCTAssertEqual(result.rcode, 0)
        XCTAssertEqual(result.answers, ["fd00::1"])
    }

    func testParseNXDOMAIN() throws {
        let queryPacket = try XCTUnwrap(DNSClient.encodeQuery(id: 9, name: "nope.test", qtype: DNSMessage.typeA))
        let query = try DNSMessage.parseQuery(queryPacket)
        let response = DNSResponseBuilder.nxdomain(to: query)
        let result = try DNSClient.parseResponse(response, expectedID: 9)
        XCTAssertEqual(result.rcode, 3)
        XCTAssertEqual(result.answers, [])
    }

    func testParseRejectsWrongID() throws {
        let queryPacket = try XCTUnwrap(DNSClient.encodeQuery(id: 10, name: "a.test", qtype: DNSMessage.typeA))
        let query = try DNSMessage.parseQuery(queryPacket)
        let response = DNSResponseBuilder.empty(to: query)
        XCTAssertThrowsError(try DNSClient.parseResponse(response, expectedID: 999)) { error in
            XCTAssertEqual(error as? DNSClientError, .malformedResponse("id mismatch"))
        }
    }

    /// Full round-trip: real DNSServer on loopback + DNSClient.lookup.
    func testLiveLookupAgainstLocalServer() async throws {
        let port: UInt16 = 53153
        let rules = [DNSRule(pattern: "*.myapp.test", ipv4: "172.30.0.3")]
        let server = DNSServer(port: port) { query in
            DNSResolver.responseData(for: query, rules: rules)
        }
        try server.start()
        defer { server.stop() }

        for _ in 0 ..< 60 where !server.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(server.isRunning)

        let hit = try await DNSClient.lookup(name: "api.myapp.test", qtype: DNSMessage.typeA, port: port)
        XCTAssertEqual(hit.rcode, 0)
        XCTAssertEqual(hit.answers, ["172.30.0.3"])

        let apex = try await DNSClient.lookup(name: "myapp.test", qtype: DNSMessage.typeA, port: port)
        XCTAssertEqual(apex.answers, ["172.30.0.3"])

        let miss = try await DNSClient.lookup(name: "nope.test", qtype: DNSMessage.typeA, port: port)
        XCTAssertEqual(miss.rcode, 3)
        XCTAssertEqual(miss.answers, [])
    }
}
