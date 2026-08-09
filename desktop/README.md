# LocalDNS for Windows & Linux

Native desktop port of [LocalDNS](../README.md) — wildcard DNS for local
development — built with Rust + Tauri 2. Full feature parity with the macOS
app: rules with groups, live match preview, hosts-file import, per-zone
registration status, query diagnostics, tray icon, launch at login.

## Architecture

```
crates/localdns-core        Pure logic, 1:1 port of LocalDNS/Core (Swift).
                            DNS wire codec, rule matching, validation,
                            hosts import, query log, zone derivation.
                            The Swift XCTest suites were ported byte-for-byte
                            as the porting oracle.
crates/localdns-server      tokio UDP+TCP DNS server (RFC 1035 §4.2.2 TCP
                            framing, pipelining) bound to explicit loopback
                            endpoints only, plus the self-test client.
crates/localdns-platform    ResolverBackend trait — the per-OS registration
                            seam — with three implementations:
                              windows/  NRPT rules (Comment-tagged ownership)
                              linux/    systemd-resolved via localdns-agentd
                              mock      in-memory (macOS dev host)
helper/localdns-helper      Windows: demand-start LocalSystem service.
                            Receives declarative zone sets over a named pipe
                            (SDDL: interactive users), re-derives NRPT writes
                            itself, touches only Comment="LocalDNS" rules.
helper/localdns-agentd      Linux: hard-sandboxed root daemon. Owns the
                            localdns0 dummy link (resolved ignores per-link
                            DNS on loopback), applies SetLinkDomains +
                            SetLinkDNSEx(127.0.0.1:port), re-applies after
                            resolved restarts/reboots, exposes
                            org.localdns.Agent1 (polkit: allow_active=yes).
app/                        Tauri 2 shell + Svelte 5 frontend (6 views
                            mirroring the macOS app).
```

### Where queries go

| OS      | OS hook                                   | Server binds                        |
|---------|-------------------------------------------|-------------------------------------|
| macOS   | `/etc/resolver/<zone>` files (native app) | `127.0.0.1:15353`                   |
| Windows | NRPT rule per zone (no port field!)       | `127.65.43.53:53` + `127.0.0.1:15353` |
| Linux   | resolved routing domains on `localdns0`   | `127.0.0.1:15353` (port supported)  |

The DNS server is **unprivileged on every OS**; only zone *registration* is
delegated (macOS: user-granted ACL; Windows: one-time-installed service;
Linux: packaged agent). Ownership markers (`# LocalDNS` file line / NRPT
Comment / the dedicated link) guarantee foreign registrations are never
touched — they surface as "Managed elsewhere".

### rules.json compatibility

Byte-level schema compatibility with the macOS app (sorted keys, omitted
nulls, uppercase UUIDs): copy `rules.json` between machines/OSes freely.

- Windows: `%APPDATA%\LocalDNS\rules.json`
- Linux: `~/.config/localdns/rules.json`
- macOS app: `~/Library/Containers/com.localdns.app/Data/Library/Application Support/LocalDNS/rules.json`

## Headless / CLI

`localdns` (shipped in the deb/rpm, or `cargo build -p localdns-cli`) manages
the SAME rules.json as the GUI and runs the same engine — for lab boxes,
servers, and provisioning scripts:

```sh
localdns add '*.myapp.test' 172.30.0.3   # validated like the GUI
localdns serve                            # foreground daemon; hot-reloads rules.json,
                                          # auto-registers zones via the agent
systemctl --user enable --now localdns    # or run it as a user service
localdns status / sync / unregister / import-hosts --apply / self-test
```

If you're a dnsmasq person, dnsmasq remains a fine answer — this exists for
machines that keep systemd-resolved, and for fleets sharing the desktop app's
rules format.

## Building

```sh
# Tests (57 core/platform + 12 server incl. live loopback round-trips)
cargo test --workspace

# Dev app (macOS/any: mock backend; Linux/Windows: real backend)
cd app && npm install && npm run tauri dev

# Release bundles (NSIS on Windows; deb/rpm/AppImage on Linux)
cd app && npm run tauri build
```

`beforeBuildCommand` stages the per-OS helper automatically
(`scripts/prepare-sidecars.mjs`): the Windows helper becomes a bundled
sidecar installed as a service by the NSIS hooks
(`src-tauri/windows/hooks.nsi`); the Linux agent + unit + D-Bus + polkit
files ride in the deb/rpm `files` map with `postinst` enabling the service.

## Cross-checking platform code from macOS

```sh
rustup target add x86_64-pc-windows-msvc x86_64-unknown-linux-gnu
cargo check -p localdns-platform -p localdns-helper --target x86_64-pc-windows-msvc
cargo check -p localdns-platform -p localdns-agentd --target x86_64-unknown-linux-gnu
```
