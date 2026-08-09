//! Embedded DNS server bound to explicit loopback endpoints only, plus the
//! minimal client used by the in-app self-test.

pub mod client;
pub mod server;

pub use client::{lookup, DnsClientError, DnsLookupResult};
pub use server::{start, Handler, ServerConfig, ServerError, ServerHandle};
