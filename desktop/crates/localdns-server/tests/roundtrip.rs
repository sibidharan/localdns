//! End-to-end round-trips against a real bound server (loopback, port 0).
//! Mirrors the live-loopback cases of DNSClientTests.swift plus TCP pipelining.

use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use localdns_core::message::{TYPE_A, TYPE_AAAA};
use localdns_core::rules::{response_data, DnsRule};
use localdns_server::server::{start, Handler, ServerConfig};
use localdns_server::{client, DnsClientError};

fn test_rules() -> Arc<Vec<DnsRule>> {
    Arc::new(vec![DnsRule {
        ipv4: Some("172.30.0.3".into()),
        ..DnsRule::new("*.myapp.test")
    }])
}

fn handler_for(rules: Arc<Vec<DnsRule>>) -> Handler {
    Arc::new(move |query| response_data(&query, &rules))
}

async fn start_test_server() -> localdns_server::ServerHandle {
    start(
        ServerConfig {
            addrs: vec!["127.0.0.1:0".parse().unwrap()],
        },
        handler_for(test_rules()),
    )
    .await
    .expect("server should bind on an ephemeral port")
}

#[tokio::test]
async fn udp_answers_matching_a_query() {
    let handle = start_test_server().await;
    let addr = handle.bound[0];

    let result = client::lookup("api.myapp.test", TYPE_A, addr, Duration::from_secs(3))
        .await
        .unwrap();
    assert_eq!(result.rcode, 0);
    assert_eq!(result.answers, vec!["172.30.0.3"]);

    handle.shutdown().await;
}

#[tokio::test]
async fn udp_nodata_for_wrong_family_and_nxdomain_for_unknown() {
    let handle = start_test_server().await;
    let addr = handle.bound[0];

    // AAAA on an ipv4-only rule → NOERROR, zero answers (NODATA)
    let nodata = client::lookup("api.myapp.test", TYPE_AAAA, addr, Duration::from_secs(3))
        .await
        .unwrap();
    assert_eq!(nodata.rcode, 0);
    assert!(nodata.answers.is_empty());

    // Unmatched name → NXDOMAIN
    let nx = client::lookup("nothing.example", TYPE_A, addr, Duration::from_secs(3))
        .await
        .unwrap();
    assert_eq!(nx.rcode, 3);
    assert!(nx.answers.is_empty());

    handle.shutdown().await;
}

#[tokio::test]
async fn tcp_pipelines_two_framed_queries_in_order() {
    let handle = start_test_server().await;
    let addr = handle.bound[0];

    let q1 = client::encode_query(1, "api.myapp.test", TYPE_A).unwrap();
    let q2 = client::encode_query(2, "web.myapp.test", TYPE_A).unwrap();

    let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
    // Write both length-framed queries back to back before reading anything.
    let mut pipelined = Vec::new();
    for q in [&q1, &q2] {
        pipelined.push((q.len() >> 8) as u8);
        pipelined.push((q.len() & 0xFF) as u8);
        pipelined.extend_from_slice(q);
    }
    stream.write_all(&pipelined).await.unwrap();

    for expected_id in [1u16, 2u16] {
        let mut len_buf = [0u8; 2];
        stream.read_exact(&mut len_buf).await.unwrap();
        let length = (usize::from(len_buf[0]) << 8) | usize::from(len_buf[1]);
        let mut reply = vec![0u8; length];
        stream.read_exact(&mut reply).await.unwrap();
        let result = client::parse_response(&reply, expected_id).unwrap();
        assert_eq!(result.rcode, 0, "response {expected_id} should be NOERROR");
        assert_eq!(result.answers, vec!["172.30.0.3"]);
    }

    handle.shutdown().await;
}

#[tokio::test]
async fn garbage_udp_datagram_gets_no_reply() {
    let handle = start_test_server().await;
    let addr = handle.bound[0];

    let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    socket.connect(addr).await.unwrap();
    socket.send(&[0xFF, 0x00, 0xBA, 0xAD]).await.unwrap();

    let mut buf = [0u8; 512];
    let outcome = tokio::time::timeout(Duration::from_millis(400), socket.recv(&mut buf)).await;
    assert!(outcome.is_err(), "malformed packet must be dropped silently");

    handle.shutdown().await;
}

#[tokio::test]
async fn port_in_use_surfaces_as_immediate_bind_error() {
    let handle = start_test_server().await;
    let taken = handle.bound[0];

    let result = start(
        ServerConfig { addrs: vec![taken] },
        handler_for(test_rules()),
    )
    .await;
    assert!(matches!(
        result,
        Err(localdns_server::ServerError::Bind { .. })
    ));

    handle.shutdown().await;
}

#[tokio::test]
async fn lookup_times_out_when_nothing_listens() {
    // Bind a UDP socket that never answers, so lookup must hit its timeout.
    let silent = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let addr = silent.local_addr().unwrap();
    let outcome = client::lookup("api.myapp.test", TYPE_A, addr, Duration::from_millis(300)).await;
    assert_eq!(outcome, Err(DnsClientError::Timeout));
}
