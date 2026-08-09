//! Minimal DNS wire codec. Port of `DNSMessage.swift`.
//!
//! Names are decoded label by label, lowercased, and joined with dots, so the
//! result never has a trailing dot. Compression pointers (RFC 1035 §4.1.4) are
//! followed with a hard jump limit so a malformed packet cannot loop forever;
//! every read is bounds-checked.

pub const TYPE_A: u16 = 1;
pub const TYPE_AAAA: u16 = 28;
pub const CLASS_IN: u16 = 1;

/// Maximum number of compression-pointer jumps tolerated in one name.
const MAX_POINTER_JUMPS: usize = 16;

/// A parsed DNS query: everything LocalDNS needs to decide and build a response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DnsQuery {
    /// Transaction ID from the query header; copied verbatim into the response.
    pub id: u16,
    /// Queried name, normalized (lowercase, no trailing dot), e.g. "api.myapp.test".
    pub name: String,
    /// Query type: 1 = A, 28 = AAAA; other values are passed through untouched.
    pub qtype: u16,
    /// Query class; only IN (1) is meaningful for this server.
    pub qclass: u16,
    /// The RD flag from the query header; copied into the response per RFC 1035.
    pub wants_recursion: bool,
    /// The original question-section bytes (wire-format name + QTYPE + QCLASS).
    /// Responses echo these verbatim so the 0xC00C owner-name pointer used by
    /// answer records always resolves to the first question.
    pub question: Vec<u8>,
}

impl DnsQuery {
    pub fn new(id: u16, name: impl Into<String>, qtype: u16) -> Self {
        Self {
            id,
            name: name.into(),
            qtype,
            qclass: CLASS_IN,
            wants_recursion: true,
            question: Vec::new(),
        }
    }
}

/// A single answer record (A or AAAA, class IN) for a response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DnsAnswer {
    pub qtype: u16,
    pub ttl: u32,
    /// Raw RDATA: 4 bytes for A, 16 bytes for AAAA.
    pub rdata: Vec<u8>,
}

/// Errors returned while decoding a wire packet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DnsParseError {
    PacketTooShort,
    MissingQuestion,
    InvalidPointer,
    PointerLoop,
    UnsupportedLabelType,
}

/// Parses a DNS query packet (12-byte header + first question).
/// Additional questions, if any, are ignored; the response echoes the first.
pub fn parse_query(data: &[u8]) -> Result<DnsQuery, DnsParseError> {
    if data.len() < 12 {
        return Err(DnsParseError::PacketTooShort);
    }
    let id = u16::from(data[0]) << 8 | u16::from(data[1]);
    let flags = u16::from(data[2]) << 8 | u16::from(data[3]);
    let qdcount = u16::from(data[4]) << 8 | u16::from(data[5]);
    if qdcount == 0 {
        return Err(DnsParseError::MissingQuestion);
    }
    let (name, question_end) = decode_name(data, 12)?;
    if question_end + 4 > data.len() {
        return Err(DnsParseError::PacketTooShort);
    }
    let qtype = u16::from(data[question_end]) << 8 | u16::from(data[question_end + 1]);
    let qclass = u16::from(data[question_end + 2]) << 8 | u16::from(data[question_end + 3]);
    let question = data[12..question_end + 4].to_vec();
    Ok(DnsQuery {
        id,
        name,
        qtype,
        qclass,
        wants_recursion: flags & 0x0100 != 0,
        question,
    })
}

/// Decodes a possibly-compressed domain name starting at `offset`.
/// Returns the normalized (lowercased) name and the offset of the first byte
/// after the name: after the terminating zero, or after the first pointer.
pub fn decode_name(bytes: &[u8], offset: usize) -> Result<(String, usize), DnsParseError> {
    let mut labels: Vec<String> = Vec::new();
    let mut offset = offset;
    let mut next_offset: Option<usize> = None;
    let mut jumps = 0;
    loop {
        if offset >= bytes.len() {
            return Err(DnsParseError::PacketTooShort);
        }
        let length = bytes[offset] as usize;
        match length & 0xC0 {
            0x00 => {
                if length == 0 {
                    return Ok((labels.join("."), next_offset.unwrap_or(offset + 1)));
                }
                let label_start = offset + 1;
                if label_start + length > bytes.len() {
                    return Err(DnsParseError::PacketTooShort);
                }
                labels.push(
                    String::from_utf8_lossy(&bytes[label_start..label_start + length])
                        .to_lowercase(),
                );
                offset = label_start + length;
            }
            0xC0 => {
                if offset + 1 >= bytes.len() {
                    return Err(DnsParseError::PacketTooShort);
                }
                let pointer = ((length & 0x3F) << 8) | bytes[offset + 1] as usize;
                if pointer >= bytes.len() {
                    return Err(DnsParseError::InvalidPointer);
                }
                if next_offset.is_none() {
                    next_offset = Some(offset + 2);
                }
                jumps += 1;
                if jumps > MAX_POINTER_JUMPS {
                    return Err(DnsParseError::PointerLoop);
                }
                offset = pointer;
            }
            // 0x40 / 0x80 are reserved per RFC 6891
            _ => return Err(DnsParseError::UnsupportedLabelType),
        }
    }
}

/// Serializes wire-format responses to a parsed query. Port of `DNSResponseBuilder`.
pub mod response {
    use super::{DnsAnswer, DnsQuery, CLASS_IN};

    pub const RCODE_NOERROR: u8 = 0;
    pub const RCODE_NXDOMAIN: u8 = 3;
    pub const RCODE_REFUSED: u8 = 5;

    /// NOERROR response carrying `answers`.
    pub fn answers(query: &DnsQuery, answers: &[DnsAnswer]) -> Vec<u8> {
        build(query, RCODE_NOERROR, answers)
    }

    /// NOERROR response with an empty answer section (NODATA).
    pub fn empty(query: &DnsQuery) -> Vec<u8> {
        build(query, RCODE_NOERROR, &[])
    }

    /// NXDOMAIN (RCODE 3): the name does not exist.
    pub fn nxdomain(query: &DnsQuery) -> Vec<u8> {
        build(query, RCODE_NXDOMAIN, &[])
    }

    /// REFUSED (RCODE 5).
    pub fn refused(query: &DnsQuery) -> Vec<u8> {
        build(query, RCODE_REFUSED, &[])
    }

    /// Header: QR set, RD copied from the query, RA = 0, RCODE as given.
    /// The question is echoed verbatim; every answer's owner name is the
    /// compression pointer 0xC00C pointing at that first question.
    fn build(query: &DnsQuery, rcode: u8, answers: &[DnsAnswer]) -> Vec<u8> {
        let mut packet = Vec::with_capacity(12 + query.question.len() + answers.len() * 26);

        fn push_u16(packet: &mut Vec<u8>, value: u16) {
            packet.push((value >> 8) as u8);
            packet.push((value & 0xFF) as u8);
        }
        fn push_u32(packet: &mut Vec<u8>, value: u32) {
            packet.push((value >> 24) as u8);
            packet.push((value >> 16) as u8);
            packet.push((value >> 8) as u8);
            packet.push((value & 0xFF) as u8);
        }

        let mut flags: u16 = 0x8000; // QR = response
        if query.wants_recursion {
            flags |= 0x0100; // RD copied; RA stays 0
        }
        flags |= u16::from(rcode & 0x0F);

        push_u16(&mut packet, query.id);
        push_u16(&mut packet, flags);
        push_u16(&mut packet, 1); // QDCOUNT
        push_u16(&mut packet, answers.len() as u16); // ANCOUNT
        push_u16(&mut packet, 0); // NSCOUNT
        push_u16(&mut packet, 0); // ARCOUNT
        packet.extend_from_slice(&query.question);
        for answer in answers {
            push_u16(&mut packet, 0xC00C); // owner name → first question
            push_u16(&mut packet, answer.qtype);
            push_u16(&mut packet, CLASS_IN);
            push_u32(&mut packet, answer.ttl);
            push_u16(&mut packet, answer.rdata.len() as u16);
            packet.extend_from_slice(&answer.rdata);
        }
        packet
    }
}

// Port of DNSMessageTests.swift — byte-for-byte assertions.
#[cfg(test)]
mod tests {
    use super::*;

    /// A wire query for "Foo.MyApp.TEST", type A, class IN, id 0x1234, RD set.
    fn make_query() -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(&[0x12, 0x34]); // ID
        data.extend_from_slice(&[0x01, 0x00]); // flags: RD
        data.extend_from_slice(&[0x00, 0x01]); // QDCOUNT = 1
        data.extend_from_slice(&[0x00, 0x00]); // ANCOUNT
        data.extend_from_slice(&[0x00, 0x00]); // NSCOUNT
        data.extend_from_slice(&[0x00, 0x00]); // ARCOUNT
        data.push(3);
        data.extend_from_slice(b"Foo");
        data.push(5);
        data.extend_from_slice(b"MyApp");
        data.push(4);
        data.extend_from_slice(b"TEST");
        data.push(0);
        data.extend_from_slice(&[0x00, 0x01]); // QTYPE = A
        data.extend_from_slice(&[0x00, 0x01]); // QCLASS = IN
        data
    }

    fn u16_at(bytes: &[u8], offset: usize) -> usize {
        (bytes[offset] as usize) << 8 | bytes[offset + 1] as usize
    }

    #[test]
    fn parse_query_normalizes_name() {
        let query = parse_query(&make_query()).unwrap();
        assert_eq!(query.id, 0x1234);
        assert_eq!(query.name, "foo.myapp.test");
        assert_eq!(query.qtype, TYPE_A);
        assert_eq!(query.qclass, CLASS_IN);
        assert!(query.wants_recursion);
    }

    #[test]
    fn a_response_bytes_round_trip() {
        let query = parse_query(&make_query()).unwrap();
        let answer = DnsAnswer {
            qtype: TYPE_A,
            ttl: 60,
            rdata: vec![172, 30, 0, 3],
        };
        let bytes = response::answers(&query, &[answer]);

        assert_eq!(u16_at(&bytes, 0), 0x1234); // ID copied
        assert_eq!(u16_at(&bytes, 2), 0x8100); // QR + RD, RA=0, RCODE=0
        assert_eq!(u16_at(&bytes, 4), 1); // QDCOUNT
        assert_eq!(u16_at(&bytes, 6), 1); // ANCOUNT
        assert_eq!(u16_at(&bytes, 8), 0); // NSCOUNT
        assert_eq!(u16_at(&bytes, 10), 0); // ARCOUNT

        // Question echoed verbatim from the original packet
        let query_bytes = make_query();
        assert_eq!(bytes[12..query_bytes.len()], query_bytes[12..]);

        // Answer record
        let mut offset = query_bytes.len();
        assert_eq!(u16_at(&bytes, offset), 0xC00C); // owner name = pointer to first question
        offset += 2;
        assert_eq!(u16_at(&bytes, offset), 1); // TYPE A
        offset += 2;
        assert_eq!(u16_at(&bytes, offset), 1); // CLASS IN
        offset += 2;
        assert_eq!(u16_at(&bytes, offset) << 16 | u16_at(&bytes, offset + 2), 60); // TTL
        offset += 4;
        assert_eq!(u16_at(&bytes, offset), 4); // RDLENGTH
        offset += 2;
        assert_eq!(bytes[offset..offset + 4], [172, 30, 0, 3]); // RDATA
        assert_eq!(bytes.len(), offset + 4); // nothing trailing
    }

    #[test]
    fn compression_pointer_in_question_decodes() {
        // Question name: "www" followed by a pointer to offset 35,
        // where the labels "example"."com" live later in the packet.
        let mut data = vec![0u8; 12];
        data[0] = 0xAB;
        data[1] = 0xCD; // ID
        data[2] = 0x01; // RD
        data[5] = 1; // QDCOUNT
        data.push(3);
        data.extend_from_slice(b"www");
        data.extend_from_slice(&[0xC0, 0x23]); // pointer to offset 35
        data.extend_from_slice(&[0x00, 0x01, 0x00, 0x01]); // QTYPE A, QCLASS IN
        while data.len() < 35 {
            data.push(0xFF);
        }
        data.push(7);
        data.extend_from_slice(b"example");
        data.push(3);
        data.extend_from_slice(b"com");
        data.push(0);

        let query = parse_query(&data).unwrap();
        assert_eq!(query.id, 0xABCD);
        assert_eq!(query.name, "www.example.com");
        assert_eq!(query.qtype, TYPE_A);
    }

    #[test]
    fn nxdomain_response() {
        let query = parse_query(&make_query()).unwrap();
        let bytes = response::nxdomain(&query);
        assert_eq!(u16_at(&bytes, 0), 0x1234); // ID copied
        assert_eq!(bytes[2] & 0x80, 0x80); // QR set
        assert_eq!(bytes[2] & 0x01, 0x01); // RD copied
        assert_eq!(bytes[3] & 0x0F, 3); // RCODE = NXDOMAIN
        assert_eq!(u16_at(&bytes, 6), 0); // ANCOUNT = 0
        assert_eq!(u16_at(&bytes, 4), 1); // QDCOUNT = 1
    }

    #[test]
    fn refused_response() {
        let query = parse_query(&make_query()).unwrap();
        let bytes = response::refused(&query);
        assert_eq!(bytes[3] & 0x0F, 5); // RCODE = REFUSED
    }

    #[test]
    fn empty_response_is_noerror_no_answers() {
        let query = parse_query(&make_query()).unwrap();
        let bytes = response::empty(&query);
        assert_eq!(bytes[3] & 0x0F, 0); // RCODE = NOERROR
        assert_eq!(u16_at(&bytes, 6), 0); // ANCOUNT = 0 (NODATA)
    }

    #[test]
    fn pointer_loop_is_rejected() {
        let mut data = vec![0u8; 12];
        data[5] = 1; // QDCOUNT
        data.extend_from_slice(&[0xC0, 0x0C]); // name = pointer to itself
        data.extend_from_slice(&[0x00, 0x01, 0x00, 0x01]);
        assert_eq!(parse_query(&data), Err(DnsParseError::PointerLoop));
    }

    #[test]
    fn truncated_packets_are_rejected() {
        assert_eq!(
            parse_query(&[0x00, 0x01]),
            Err(DnsParseError::PacketTooShort)
        );
        // Header says one question, but the packet ends right after it starts
        let mut data = vec![0u8; 12];
        data[5] = 1;
        data.push(3);
        data.extend_from_slice(b"ab");
        assert_eq!(parse_query(&data), Err(DnsParseError::PacketTooShort));
    }

    #[test]
    fn no_question_is_rejected() {
        let data = vec![0u8; 12]; // QDCOUNT = 0
        assert_eq!(parse_query(&data), Err(DnsParseError::MissingQuestion));
    }

    /// Modern resolvers (including macOS and dig) attach an EDNS OPT pseudo-record
    /// in the additional section. The parser must tolerate it, and the response
    /// must stay well-formed (ARCOUNT = 0, question echoed verbatim).
    #[test]
    fn query_with_edns_additional_record_is_tolerated() {
        let mut data = make_query();
        data[11] = 1; // ARCOUNT = 1
        data.push(0); // NAME = root
        data.extend_from_slice(&[0x00, 0x29]); // TYPE = OPT (41)
        data.extend_from_slice(&[0x04, 0xD0]); // CLASS = UDP payload 1232
        data.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // TTL (ext-rcode/flags)
        data.extend_from_slice(&[0x00, 0x00]); // RDLENGTH = 0
        let query = parse_query(&data).unwrap();
        assert_eq!(query.name, "foo.myapp.test");

        let answer = DnsAnswer {
            qtype: TYPE_A,
            ttl: 60,
            rdata: vec![172, 30, 0, 3],
        };
        let bytes = response::answers(&query, &[answer]);
        assert_eq!(u16_at(&bytes, 10), 0); // response ARCOUNT = 0
        // Echoed question matches the original question bytes (not the OPT tail).
        let original = make_query();
        assert_eq!(bytes[12..original.len()], original[12..]);
    }
}
