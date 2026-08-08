import Foundation

/// A parsed DNS query: everything LocalDNS needs to decide and build a response.
public struct DNSQuery: Equatable, Sendable {
    /// Transaction ID from the query header; copied verbatim into the response.
    public let id: UInt16
    /// Queried name, normalized (lowercase, no trailing dot), e.g. "api.myapp.test".
    public let name: String
    /// Query type: 1 = A, 28 = AAAA; other values are passed through untouched.
    public let qtype: UInt16
    /// Query class; only IN (1) is meaningful for this server.
    public let qclass: UInt16
    /// The RD flag from the query header; copied into the response per RFC 1035.
    public let wantsRecursion: Bool
    /// The original question-section bytes (wire-format name + QTYPE + QCLASS).
    /// Responses echo these verbatim so the 0xC00C owner-name pointer used by
    /// answer records always resolves to the first question.
    public let question: Data

    public init(id: UInt16, name: String, qtype: UInt16, qclass: UInt16 = DNSMessage.classIN,
                wantsRecursion: Bool = true, question: Data = Data()) {
        self.id = id
        self.name = name
        self.qtype = qtype
        self.qclass = qclass
        self.wantsRecursion = wantsRecursion
        self.question = question
    }
}

/// A single answer record (A or AAAA, class IN) for a response.
public struct DNSAnswer: Equatable, Sendable {
    public let qtype: UInt16
    public let ttl: UInt32
    /// Raw RDATA: 4 bytes for A, 16 bytes for AAAA.
    public let rdata: Data

    public init(qtype: UInt16, ttl: UInt32, rdata: Data) {
        self.qtype = qtype
        self.ttl = ttl
        self.rdata = rdata
    }
}

/// Errors thrown while decoding a wire packet.
public enum DNSParseError: Error, Equatable {
    case packetTooShort
    case missingQuestion
    case invalidPointer
    case pointerLoop
    case unsupportedLabelType
}

/// Minimal DNS wire codec.
///
/// Names are decoded label by label, lowercased, and joined with dots, so the
/// result never has a trailing dot. Compression pointers (RFC 1035 §4.1.4) are
/// followed with a hard jump limit so a malformed packet cannot loop forever;
/// every read is bounds-checked.
public enum DNSMessage {
    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28
    public static let classIN: UInt16 = 1

    /// Maximum number of compression-pointer jumps tolerated in one name.
    static let maxPointerJumps = 16

    /// Parses a DNS query packet (12-byte header + first question).
    /// Additional questions, if any, are ignored; the response echoes the first.
    public static func parseQuery(_ data: Data) throws -> DNSQuery {
        guard data.count >= 12 else { throw DNSParseError.packetTooShort }
        let bytes = [UInt8](data)
        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let qdcount = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard qdcount > 0 else { throw DNSParseError.missingQuestion }
        let (name, questionEnd) = try decodeName(bytes, offset: 12)
        guard questionEnd + 4 <= bytes.count else { throw DNSParseError.packetTooShort }
        let qtype = UInt16(bytes[questionEnd]) << 8 | UInt16(bytes[questionEnd + 1])
        let qclass = UInt16(bytes[questionEnd + 2]) << 8 | UInt16(bytes[questionEnd + 3])
        let question = Data(bytes[12 ..< questionEnd + 4])
        return DNSQuery(id: id, name: name, qtype: qtype, qclass: qclass,
                        wantsRecursion: flags & 0x0100 != 0, question: question)
    }

    /// Decodes a possibly-compressed domain name starting at `offset`.
    /// Returns the normalized (lowercased) name and the offset of the first byte
    /// after the name: after the terminating zero, or after the first pointer.
    static func decodeName(_ bytes: [UInt8], offset: Int) throws -> (name: String, nextOffset: Int) {
        var labels: [String] = []
        var offset = offset
        var nextOffset: Int?
        var jumps = 0
        while true {
            guard offset < bytes.count else { throw DNSParseError.packetTooShort }
            let length = Int(bytes[offset])
            switch length & 0xC0 {
            case 0x00:
                if length == 0 {
                    return (labels.joined(separator: "."), nextOffset ?? (offset + 1))
                }
                let labelStart = offset + 1
                guard labelStart + length <= bytes.count else { throw DNSParseError.packetTooShort }
                labels.append(String(decoding: bytes[labelStart ..< labelStart + length], as: UTF8.self).lowercased())
                offset = labelStart + length
            case 0xC0:
                guard offset + 1 < bytes.count else { throw DNSParseError.packetTooShort }
                let pointer = ((length & 0x3F) << 8) | Int(bytes[offset + 1])
                guard pointer < bytes.count else { throw DNSParseError.invalidPointer }
                if nextOffset == nil { nextOffset = offset + 2 }
                jumps += 1
                guard jumps <= maxPointerJumps else { throw DNSParseError.pointerLoop }
                offset = pointer
            default: // 0x40 / 0x80 are reserved per RFC 6891
                throw DNSParseError.unsupportedLabelType
            }
        }
    }
}

/// Serializes wire-format responses to a parsed query.
public enum DNSResponseBuilder {
    public static let rcodeNoError: UInt8 = 0
    public static let rcodeNXDomain: UInt8 = 3
    public static let rcodeRefused: UInt8 = 5

    /// NOERROR response carrying `answers`.
    public static func response(to query: DNSQuery, answers: [DNSAnswer]) -> Data {
        build(query, rcode: rcodeNoError, answers: answers)
    }

    /// NOERROR response with an empty answer section (NODATA).
    public static func empty(to query: DNSQuery) -> Data {
        build(query, rcode: rcodeNoError, answers: [])
    }

    /// NXDOMAIN (RCODE 3): the name does not exist.
    public static func nxdomain(to query: DNSQuery) -> Data {
        build(query, rcode: rcodeNXDomain, answers: [])
    }

    /// REFUSED (RCODE 5).
    public static func refused(to query: DNSQuery) -> Data {
        build(query, rcode: rcodeRefused, answers: [])
    }

    /// Header: QR set, RD copied from the query, RA = 0, RCODE as given.
    /// The question is echoed verbatim; every answer's owner name is the
    /// compression pointer 0xC00C pointing at that first question.
    private static func build(_ query: DNSQuery, rcode: UInt8, answers: [DNSAnswer]) -> Data {
        var packet = Data()
        packet.reserveCapacity(12 + query.question.count + answers.count * 26)

        func appendU16(_ value: UInt16) {
            packet.append(UInt8(value >> 8))
            packet.append(UInt8(value & 0xFF))
        }
        func appendU32(_ value: UInt32) {
            packet.append(UInt8((value >> 24) & 0xFF))
            packet.append(UInt8((value >> 16) & 0xFF))
            packet.append(UInt8((value >> 8) & 0xFF))
            packet.append(UInt8(value & 0xFF))
        }

        var flags: UInt16 = 0x8000                  // QR = response
        if query.wantsRecursion { flags |= 0x0100 } // RD copied; RA stays 0
        flags |= UInt16(rcode & 0x0F)

        appendU16(query.id)
        appendU16(flags)
        appendU16(1)                         // QDCOUNT
        appendU16(UInt16(answers.count))     // ANCOUNT
        appendU16(0)                         // NSCOUNT
        appendU16(0)                         // ARCOUNT
        packet.append(contentsOf: query.question)
        for answer in answers {
            appendU16(0xC00C)                // owner name → first question
            appendU16(answer.qtype)
            appendU16(DNSMessage.classIN)
            appendU32(answer.ttl)
            appendU16(UInt16(answer.rdata.count))
            packet.append(contentsOf: answer.rdata)
        }
        return packet
    }
}
