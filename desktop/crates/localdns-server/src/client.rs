//! Minimal DNS client, used by the in-app self-test to verify the server
//! answers on its loopback endpoint. Port of `DNSClient.swift`: codec parts are
//! pure functions (unit-tested without any network traffic); `lookup` does one
//! UDP round-trip.

use std::fmt;
use std::net::{Ipv6Addr, SocketAddr};
use std::time::Duration;

use tokio::net::UdpSocket;

use localdns_core::message::{self, TYPE_A, TYPE_AAAA};
use localdns_core::rules::normalize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DnsClientError {
    InvalidName,
    Timeout,
    Network(String),
    MalformedResponse(String),
}

impl fmt::Display for DnsClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DnsClientError::InvalidName => write!(f, "Invalid query name."),
            DnsClientError::Timeout => write!(f, "Timed out waiting for a response."),
            DnsClientError::Network(message) => write!(f, "{message}"),
            DnsClientError::MalformedResponse(detail) => {
                write!(f, "Malformed response ({detail}).")
            }
        }
    }
}

impl std::error::Error for DnsClientError {}

/// The parsed result of one lookup: header RCODE plus the A/AAAA answers
/// formatted as address strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DnsLookupResult {
    pub rcode: u8,
    pub answers: Vec<String>,
}

/// Builds a wire-format query for `name` (RD set, one question, class IN).
/// Returns None for empty names, oversized labels, or oversized packets.
pub fn encode_query(id: u16, name: &str, qtype: u16) -> Option<Vec<u8>> {
    let normalized = normalize(name);
    if normalized.is_empty() {
        return None;
    }
    let mut question = Vec::new();
    for label in normalized.split('.') {
        if label.len() > 63 {
            return None;
        }
        question.push(label.len() as u8);
        question.extend_from_slice(label.as_bytes());
    }
    question.push(0);
    if question.len() > 255 {
        return None;
    }

    let mut data = Vec::with_capacity(12 + question.len() + 4);
    let push_u16 = |data: &mut Vec<u8>, value: u16| {
        data.push((value >> 8) as u8);
        data.push((value & 0xFF) as u8);
    };
    push_u16(&mut data, id);
    push_u16(&mut data, 0x0100); // RD
    push_u16(&mut data, 1); // QDCOUNT
    push_u16(&mut data, 0); // ANCOUNT
    push_u16(&mut data, 0); // NSCOUNT
    push_u16(&mut data, 0); // ARCOUNT
    data.extend_from_slice(&question);
    push_u16(&mut data, qtype);
    push_u16(&mut data, message::CLASS_IN);
    Some(data)
}

/// Parses a response packet: verifies the transaction id, reads the RCODE,
/// skips the question section, and decodes A/AAAA answers to text.
pub fn parse_response(data: &[u8], expected_id: u16) -> Result<DnsLookupResult, DnsClientError> {
    if data.len() < 12 {
        return Err(DnsClientError::MalformedResponse("short header".into()));
    }
    let u16_at = |offset: usize| u16::from(data[offset]) << 8 | u16::from(data[offset + 1]);
    if u16_at(0) != expected_id {
        return Err(DnsClientError::MalformedResponse("id mismatch".into()));
    }
    let rcode = (u16_at(2) & 0x000F) as u8;
    let qdcount = u16_at(4) as usize;
    let ancount = u16_at(6) as usize;

    let mut offset = 12;
    for _ in 0..qdcount {
        offset = skip_name(data, offset)? + 4;
        if offset > data.len() {
            return Err(DnsClientError::MalformedResponse("question overrun".into()));
        }
    }

    let mut answers = Vec::new();
    for _ in 0..ancount {
        let name_end = skip_name(data, offset)?;
        if name_end + 10 > data.len() {
            return Err(DnsClientError::MalformedResponse("answer overrun".into()));
        }
        let rtype = u16_at(name_end);
        let rdlength = u16_at(name_end + 8) as usize;
        let rdata_start = name_end + 10;
        if rdata_start + rdlength > data.len() {
            return Err(DnsClientError::MalformedResponse("rdata overrun".into()));
        }
        let rdata = &data[rdata_start..rdata_start + rdlength];
        match (rtype, rdlength) {
            (TYPE_A, 4) => answers.push(
                rdata
                    .iter()
                    .map(|b| b.to_string())
                    .collect::<Vec<_>>()
                    .join("."),
            ),
            (TYPE_AAAA, 16) => {
                let mut octets = [0u8; 16];
                octets.copy_from_slice(rdata);
                answers.push(Ipv6Addr::from(octets).to_string());
            }
            _ => {} // record types we don't display
        }
        offset = rdata_start + rdlength;
    }
    Ok(DnsLookupResult { rcode, answers })
}

/// Skips over a (possibly compressed) name, returning the offset after it.
fn skip_name(bytes: &[u8], offset: usize) -> Result<usize, DnsClientError> {
    message::decode_name(bytes, offset)
        .map(|(_, next_offset)| next_offset)
        .map_err(|_| DnsClientError::MalformedResponse("bad name".into()))
}

/// Sends one UDP query to `server` and awaits the parsed response.
pub async fn lookup(
    name: &str,
    qtype: u16,
    server: SocketAddr,
    timeout: Duration,
) -> Result<DnsLookupResult, DnsClientError> {
    let id_bytes = uuid::Uuid::new_v4();
    let id = u16::from(id_bytes.as_bytes()[0]) << 8 | u16::from(id_bytes.as_bytes()[1]);
    let packet = encode_query(id, name, qtype).ok_or(DnsClientError::InvalidName)?;

    let local: SocketAddr = if server.is_ipv4() {
        "127.0.0.1:0".parse().unwrap()
    } else {
        "[::1]:0".parse().unwrap()
    };
    let socket = UdpSocket::bind(local)
        .await
        .map_err(|e| DnsClientError::Network(e.to_string()))?;
    socket
        .connect(server)
        .await
        .map_err(|e| DnsClientError::Network(e.to_string()))?;
    socket
        .send(&packet)
        .await
        .map_err(|e| DnsClientError::Network(format!("send failed: {e}")))?;

    let mut buf = [0u8; 4096];
    let len = tokio::time::timeout(timeout, socket.recv(&mut buf))
        .await
        .map_err(|_| DnsClientError::Timeout)?
        .map_err(|e| DnsClientError::Network(e.to_string()))?;
    parse_response(&buf[..len], id)
}

// Codec tests ported from the pure-function cases of DNSClientTests.swift.
#[cfg(test)]
mod tests {
    use super::*;
    use localdns_core::message::response;
    use localdns_core::{DnsAnswer, DnsQuery};

    #[test]
    fn encode_query_shape() {
        let data = encode_query(0x1234, "API.MyApp.Test.", TYPE_A).unwrap();
        // Header
        assert_eq!(data[0..2], [0x12, 0x34]);
        assert_eq!(data[2..4], [0x01, 0x00]); // RD
        assert_eq!(data[4..6], [0x00, 0x01]); // QDCOUNT
        // Name is normalized then encoded
        let parsed = message::parse_query(&data).unwrap();
        assert_eq!(parsed.name, "api.myapp.test");
        assert_eq!(parsed.qtype, TYPE_A);
    }

    #[test]
    fn encode_query_rejects_bad_names() {
        assert!(encode_query(1, "", TYPE_A).is_none());
        assert!(encode_query(1, ".", TYPE_A).is_none());
        let long_label = "a".repeat(64) + ".test";
        assert!(encode_query(1, &long_label, TYPE_A).is_none());
        let long_name = vec!["abcdefghij"; 30].join(".");
        assert!(encode_query(1, &long_name, TYPE_A).is_none());
    }

    #[test]
    fn parse_response_round_trip() {
        let query_wire = encode_query(7, "api.myapp.test", TYPE_A).unwrap();
        let query = message::parse_query(&query_wire).unwrap();
        let reply = response::answers(
            &query,
            &[DnsAnswer {
                qtype: TYPE_A,
                ttl: 60,
                rdata: vec![172, 30, 0, 3],
            }],
        );
        let result = parse_response(&reply, 7).unwrap();
        assert_eq!(result.rcode, 0);
        assert_eq!(result.answers, vec!["172.30.0.3"]);
    }

    #[test]
    fn parse_response_rejects_id_mismatch() {
        let query_wire = encode_query(7, "api.myapp.test", TYPE_A).unwrap();
        let query = message::parse_query(&query_wire).unwrap();
        let reply = response::nxdomain(&query);
        assert_eq!(
            parse_response(&reply, 8),
            Err(DnsClientError::MalformedResponse("id mismatch".into()))
        );
    }

    #[test]
    fn parse_response_reads_rcode_and_v6() {
        let query_wire = encode_query(9, "v6.test", TYPE_AAAA).unwrap();
        let query = message::parse_query(&query_wire).unwrap();
        let addr: Ipv6Addr = "fd00::3".parse().unwrap();
        let reply = response::answers(
            &query,
            &[DnsAnswer {
                qtype: TYPE_AAAA,
                ttl: 60,
                rdata: addr.octets().to_vec(),
            }],
        );
        let result = parse_response(&reply, 9).unwrap();
        assert_eq!(result.rcode, 0);
        assert_eq!(result.answers, vec!["fd00::3"]);

        let nx = response::nxdomain(&query);
        assert_eq!(parse_response(&nx, 9).unwrap().rcode, 3);
    }

    #[test]
    fn parse_response_rejects_truncated() {
        assert!(parse_response(&[0, 9], 9).is_err());
        let query = DnsQuery::new(9, "x.test", TYPE_A);
        let mut reply = response::empty(&query);
        reply[5] = 1; // claims a question that isn't there (question bytes empty)
        assert!(parse_response(&reply, 9).is_err());
    }
}
