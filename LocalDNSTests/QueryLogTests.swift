import Network
import XCTest

final class QueryLogTests: XCTestCase {

    private func entry(_ n: Int) -> QueryLogEntry {
        QueryLogEntry(name: "host\(n).test", qtype: "A", outcome: .answered("10.0.0.\(n)"))
    }

    func testAppendKeepsNewestFirst() {
        let log = QueryLog(capacity: 10)
        log.append(entry(1))
        log.append(entry(2))
        XCTAssertEqual(log.entries.map(\.name), ["host2.test", "host1.test"])
        XCTAssertEqual(log.count, 2)
    }

    func testRingBufferCapsAtCapacity() {
        let log = QueryLog(capacity: 5)
        for i in 1 ... 7 { log.append(entry(i)) }
        XCTAssertEqual(log.count, 5)
        XCTAssertEqual(log.entries.map(\.name),
                       ["host7.test", "host6.test", "host5.test", "host4.test", "host3.test"])
    }

    func testWatchdogProbeEntriesAreNotRecorded() {
        let log = QueryLog(capacity: 5)
        log.append(QueryLogEntry(name: QueryLog.watchdogProbeName, qtype: "A", outcome: .nxdomain))
        XCTAssertEqual(log.count, 0)
        log.append(entry(1))
        XCTAssertEqual(log.entries.map(\.name), ["host1.test"])
    }

    func testClear() {
        let log = QueryLog(capacity: 3)
        log.append(entry(1))
        log.clear()
        XCTAssertEqual(log.count, 0)
        XCTAssertEqual(log.entries, [])
    }

    func testConcurrentAppendsStayConsistent() {
        let log = QueryLog(capacity: 50)
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            log.append(entry(i))
        }
        XCTAssertEqual(log.count, 50)
        XCTAssertEqual(Set(log.entries.map(\.id)).count, 50) // every retained entry intact
    }

    func testEntryFromQueryAndResolution() {
        let query = DNSQuery(id: 1, name: "api.myapp.test", qtype: DNSMessage.typeA)
        let entry = QueryLogEntry(query: query,
                                  resolution: .answers([DNSAnswer(qtype: DNSMessage.typeA, ttl: 60,
                                                                  rdata: Data([172, 30, 0, 3]))]),
                                  latencyMs: 1.5)
        XCTAssertEqual(entry.name, "api.myapp.test")
        XCTAssertEqual(entry.qtype, "A")
        XCTAssertEqual(entry.outcome, .answered("172.30.0.3"))
        XCTAssertEqual(entry.latencyMs, 1.5)

        let v6Query = DNSQuery(id: 2, name: "v6.test", qtype: DNSMessage.typeAAAA)
        let v6 = QueryLogEntry(query: v6Query,
                               resolution: .answers([DNSAnswer(qtype: DNSMessage.typeAAAA, ttl: 60,
                                                               rdata: IPv6Address("fd00::1")!.rawValue)]),
                               latencyMs: 0)
        XCTAssertEqual(v6.qtype, "AAAA")
        XCTAssertEqual(v6.outcome, .answered("fd00::1"))

        XCTAssertEqual(QueryLogEntry(query: query, resolution: .noData, latencyMs: 0).outcome, .noData)
        XCTAssertEqual(QueryLogEntry(query: query, resolution: .nxdomain, latencyMs: 0).outcome, .nxdomain)
        XCTAssertEqual(QueryLogEntry(query: DNSQuery(id: 3, name: "x.test", qtype: 15),
                                     resolution: .noData, latencyMs: 0).qtype, "TYPE15")
    }
}
