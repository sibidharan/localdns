//! Tokio port of `DNSServer.swift`.
//!
//! UDP: every received datagram is parsed and answered through the handler;
//! malformed packets are dropped silently (no id to answer with).
//! TCP: DNS-over-TCP framing (RFC 1035 §4.2.2) — each message is preceded by a
//! two-byte big-endian length; the connection stays open for further queries
//! (pipelining preserved, exactly like the macOS server).
//!
//! Unlike the macOS Network.framework version (where "port in use" surfaces
//! asynchronously via `lastError`), sockets are bound synchronously inside
//! `start()`, so bind failures are immediate and typed.

use std::fmt;
use std::net::SocketAddr;
use std::time::Duration;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use localdns_core::message::{self, DnsQuery};

/// Parses a query and returns the complete wire response packet.
/// Called for every well-formed query; runs on the server's tasks, so it must
/// be cheap and non-blocking (rule matching against an in-memory snapshot).
pub type Handler = Arc<dyn Fn(DnsQuery) -> Vec<u8> + Send + Sync>;

/// Explicit loopback bind addresses. Never bind 0.0.0.0 — the parity contract
/// with the macOS server's `requiredLocalEndpoint` pin is that nothing external
/// can ever reach this server. Windows adds e.g. 127.65.43.53:53 alongside
/// 127.0.0.1:15353; other platforms use a single loopback endpoint.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub addrs: Vec<SocketAddr>,
}

#[derive(Debug)]
pub enum ServerError {
    Bind {
        addr: SocketAddr,
        source: std::io::Error,
    },
}

impl fmt::Display for ServerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ServerError::Bind { addr, source } => write!(
                f,
                "listener on {addr} failed to start — the port may already be in use by another app. ({source})"
            ),
        }
    }
}

impl std::error::Error for ServerError {}

/// A running server. Dropping the handle does NOT stop the server; call
/// `shutdown()` for a graceful stop (used on port changes and quit).
pub struct ServerHandle {
    cancel: CancellationToken,
    tracker: TaskTracker,
    /// The actually-bound endpoints (resolves port 0 to the real port; UDP and
    /// TCP share the same port per endpoint, as in production).
    pub bound: Vec<SocketAddr>,
}

impl ServerHandle {
    pub async fn shutdown(self) {
        self.cancel.cancel();
        self.tracker.close();
        self.tracker.wait().await;
    }
}

/// Binds every endpoint (UDP+TCP) synchronously, then spawns the serving tasks.
pub async fn start(config: ServerConfig, handler: Handler) -> Result<ServerHandle, ServerError> {
    let cancel = CancellationToken::new();
    let tracker = TaskTracker::new();
    let mut bound = Vec::new();
    let mut pairs = Vec::new();

    for addr in &config.addrs {
        let (udp, tcp, actual) = bind_pair(*addr).await.map_err(|source| ServerError::Bind {
            addr: *addr,
            source,
        })?;
        bound.push(actual);
        pairs.push((udp, tcp));
    }

    for ((udp, tcp), (requested, actual)) in pairs
        .into_iter()
        .zip(config.addrs.iter().copied().zip(bound.iter().copied()))
    {
        tracker.spawn(endpoint_supervisor(
            requested,
            Some((udp, tcp, actual)),
            handler.clone(),
            cancel.clone(),
            tracker.clone(),
        ));
    }

    Ok(ServerHandle {
        cancel,
        tracker,
        bound,
    })
}

/// How often the watchdog verifies the endpoint with a real query.
const WATCHDOG_PERIOD: Duration = Duration::from_secs(60);

/// Owns one endpoint for the server's lifetime: runs the serving loops, and
/// every WATCHDOG_PERIOD fires an actual DNS query at the socket — ANY reply
/// (NXDOMAIN included) proves the pipeline; silence means the transport went
/// bad in a way no error surfaced (the macOS Network.framework lesson: trust
/// answers, not state), so the loops are killed, the sockets dropped, and the
/// endpoint rebound with backoff. Exclusive rebinding stays safe because the
/// old sockets are awaited-closed before the rebind.
async fn endpoint_supervisor(
    requested: SocketAddr,
    initial: Option<(UdpSocket, TcpListener, SocketAddr)>,
    handler: Handler,
    cancel: CancellationToken,
    tracker: TaskTracker,
) {
    let mut current = initial;
    loop {
        let (udp, tcp, addr) = match current.take() {
            Some(sockets) => sockets,
            None => {
                let mut delay = Duration::from_secs(2);
                loop {
                    tokio::select! {
                        _ = cancel.cancelled() => return,
                        result = bind_pair(requested) => match result {
                            Ok(sockets) => break sockets,
                            Err(_) => {
                                tokio::select! {
                                    _ = cancel.cancelled() => return,
                                    _ = tokio::time::sleep(delay) => {}
                                }
                                delay = (delay * 2).min(Duration::from_secs(30));
                            }
                        }
                    }
                }
            }
        };

        let sub = cancel.child_token();
        let udp_task = tokio::spawn(udp_loop(udp, handler.clone(), sub.clone()));
        let tcp_task = tokio::spawn(tcp_accept_loop(
            tcp,
            handler.clone(),
            sub.clone(),
            tracker.clone(),
        ));

        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    sub.cancel();
                    let _ = udp_task.await;
                    let _ = tcp_task.await;
                    return;
                }
                _ = tokio::time::sleep(WATCHDOG_PERIOD) => {
                    if !probe_alive(addr).await {
                        eprintln!("localdns-server: endpoint {addr} went silent — rebinding");
                        sub.cancel();
                        let _ = udp_task.await;
                        let _ = tcp_task.await;
                        break;
                    }
                }
            }
        }
        // Fall through with no sockets: the outer loop rebinds.
    }
}

/// One real query; any parsed reply proves the endpoint is alive.
async fn probe_alive(addr: SocketAddr) -> bool {
    crate::client::lookup(
        localdns_core::WATCHDOG_PROBE_NAME,
        localdns_core::message::TYPE_A,
        addr,
        Duration::from_secs(2),
    )
    .await
    .is_ok()
}

/// Binds UDP and TCP on the same (addr, port). For port 0 (tests), the UDP
/// socket picks the port and TCP must land on the same one; retry until a
/// matching pair is found so `bound` stays truthful for both protocols.
async fn bind_pair(
    addr: SocketAddr,
) -> Result<(UdpSocket, TcpListener, SocketAddr), std::io::Error> {
    if addr.port() != 0 {
        let udp = UdpSocket::bind(addr).await?;
        let tcp = TcpListener::bind(addr).await?;
        return Ok((udp, tcp, addr));
    }
    let mut last_error = None;
    for _ in 0..16 {
        let udp = UdpSocket::bind(addr).await?;
        let actual = udp.local_addr()?;
        match TcpListener::bind(actual).await {
            Ok(tcp) => return Ok((udp, tcp, actual)),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error
        .unwrap_or_else(|| std::io::Error::other("could not bind a matching UDP/TCP port pair")))
}

async fn udp_loop(socket: UdpSocket, handler: Handler, cancel: CancellationToken) {
    let mut buf = [0u8; 4096];
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return,
            result = socket.recv_from(&mut buf) => {
                let Ok((len, peer)) = result else {
                    // Transient recv errors (e.g. ICMP-induced) — keep serving.
                    continue;
                };
                if len == 0 {
                    continue;
                }
                if let Ok(query) = message::parse_query(&buf[..len]) {
                    let reply = handler(query);
                    let _ = socket.send_to(&reply, peer).await;
                }
            }
        }
    }
}

async fn tcp_accept_loop(
    listener: TcpListener,
    handler: Handler,
    cancel: CancellationToken,
    tracker: TaskTracker,
) {
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return,
            result = listener.accept() => {
                let Ok((stream, _)) = result else { continue };
                tracker.spawn(tcp_connection(stream, handler.clone(), cancel.clone()));
            }
        }
    }
}

/// One DNS-over-TCP connection: length-prefixed messages, kept open for
/// pipelined queries. Mirrors receiveTCPLength/receiveTCPQuery: a zero length
/// closes; a malformed query skips the reply but keeps the connection.
async fn tcp_connection(mut stream: TcpStream, handler: Handler, cancel: CancellationToken) {
    loop {
        let mut len_buf = [0u8; 2];
        tokio::select! {
            _ = cancel.cancelled() => return,
            result = stream.read_exact(&mut len_buf) => {
                if result.is_err() {
                    return; // EOF or error: connection done
                }
            }
        }
        let length = (usize::from(len_buf[0]) << 8) | usize::from(len_buf[1]);
        if length == 0 {
            return;
        }
        let mut query_buf = vec![0u8; length];
        tokio::select! {
            _ = cancel.cancelled() => return,
            result = stream.read_exact(&mut query_buf) => {
                if result.is_err() {
                    return;
                }
            }
        }
        if let Ok(query) = message::parse_query(&query_buf) {
            let reply = handler(query);
            if reply.len() <= usize::from(u16::MAX) {
                let mut framed = Vec::with_capacity(2 + reply.len());
                framed.push((reply.len() >> 8) as u8);
                framed.push((reply.len() & 0xFF) as u8);
                framed.extend_from_slice(&reply);
                if stream.write_all(&framed).await.is_err() {
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod watchdog_tests {
    use super::*;
    use std::sync::Arc;

    #[tokio::test]
    async fn probe_distinguishes_live_from_dead() {
        let handler: Handler =
            Arc::new(|query| localdns_core::message::response::nxdomain(&query));
        let config = ServerConfig {
            addrs: vec!["127.0.0.1:0".parse().unwrap()],
        };
        let handle = start(config, handler).await.unwrap();
        let addr = handle.bound[0];
        assert!(probe_alive(addr).await, "live endpoint must answer the probe");
        handle.shutdown().await;
        assert!(!probe_alive(addr).await, "dead endpoint must fail the probe");
    }
}
