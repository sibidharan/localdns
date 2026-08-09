# LocalDNS Architecture

One product, three platforms, one philosophy: an **unprivileged DNS server on
loopback**, plus the smallest possible per-OS mechanism that only *registers
zones* with the system resolver. No root process ever runs routinely; every
privileged step is a one-time, user-visible consent; LocalDNS never touches
resolver state it did not create.

```
                        ┌───────────────────────────────┐
                        │        rules.json             │  identical schema on
                        │  (wildcard/exact rules, TTLs, │  every OS — copy it
                        │   groups, enable flags)       │  between machines
                        └──────────────┬────────────────┘
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        │                              │                              │
┌───────▼────────┐            ┌────────▼────────┐            ┌────────▼────────┐
│  macOS app     │            │ Windows/Linux   │            │  localdns CLI   │
│  (SwiftUI)     │            │ app (Tauri 2 +  │            │  (headless:     │
│                │            │  Svelte 5)      │            │   add/serve/…)  │
└───────┬────────┘            └────────┬────────┘            └────────┬────────┘
        │      each embeds the same engine: DNS wire codec, matcher,  │
        │      UDP+TCP loopback server, hosts importer, query log     │
        └──────────────────────────────┼──────────────────────────────┘
                                       │ zone registration only
        ┌──────────────────────────────┼──────────────────────────────┐
        │                              │                              │
┌───────▼────────┐            ┌────────▼────────┐            ┌────────▼────────┐
│ /etc/resolver/ │            │ NRPT rules via  │            │ systemd-resolved│
│ <zone> files   │            │ localdns-helper │            │ routing domains │
│ (macOS native  │            │ (demand-start   │            │ via localdns-   │
│  mechanism)    │            │  Win service)   │            │ agentd (D-Bus)  │
└────────────────┘            └─────────────────┘            └─────────────────┘
```

## The engine (implemented twice, tested once)

The core logic exists in two implementations with identical semantics:

- **Swift**: [`LocalDNS/Core/`](LocalDNS/Core/) — pure Foundation + Network,
  no SwiftUI/AppKit; compiles standalone with `swiftc`.
- **Rust**: [`desktop/crates/localdns-core`](desktop/crates/localdns-core) —
  a 1:1 port. The Swift XCTest suites were translated byte-for-byte and act
  as the port's oracle; any behavioral divergence is by definition a bug.

What the engine does:

- **Wire codec** — parses the query header + first question (compression
  pointers with a 16-jump cap, bounds-checked, reserved label types
  rejected); answers echo the question bytes and use the `0xC00C` owner
  pointer. Only A/AAAA are answered; rule-matched-but-wrong-family → NODATA;
  no match → NXDOMAIN; malformed → dropped.
- **Matcher** — `*.suffix` matches the suffix itself and any subdomain depth
  (dnsmasq-style); exact rules match equality; longest pattern wins, ties
  keep the earlier rule.
- **Validation guards** — hostname grammar, `*` only as leading `*.`, a
  blocked public-suffix wildcard list (`*.co.uk` would NXDOMAIN half the UK),
  and a `.local` warning (mDNS territory).
- **Server** — UDP + TCP (RFC 1035 §4.2.2 length framing, pipelining) bound
  to explicit loopback addresses only; rules are read through a lock-free
  snapshot per query.
- **Hosts importer** — read-only analysis of the hosts file; groups of 2+
  names sharing an address and parent domain become wildcard suggestions.

## Per-OS registration

| | macOS | Windows | Linux |
|---|---|---|---|
| Mechanism | `/etc/resolver/<zone>` files | NRPT rules (namespace `.zone` + `zone`) | resolved routing domains on a dummy link |
| Server endpoint | `127.0.0.1:15353` | `127.65.43.53:53` + `127.0.0.1:15353` — NRPT has no port field, and a specific 127/8 bind coexists with Docker/WSL squatting `0.0.0.0:53` | `127.0.0.1:15353` — resolved supports `address:port` via `SetLinkDNSEx` |
| Privileged piece | none (user-granted ACL + security-scoped bookmark) | `localdns-helper` — LocalSystem, **demand-start**, self-stops after 120 s idle | `localdns-agentd` — root but `CapabilityBoundingSet=CAP_NET_ADMIN`, `ProtectSystem=strict`, `NoNewPrivileges` |
| IPC to it | — (direct file writes) | named pipe `\\.\pipe\LocalDNSHelper`, SDDL grants interactive users | D-Bus `org.localdns.Agent1`, polkit `allow_active=yes` (console user syncs silently) |
| One-time consent | one visible `sudo` command + folder grant | elevated installer registers the service | package install enables the agent |
| Ownership marker | `# LocalDNS` first line | NRPT rule `Comment=LocalDNS` | the dedicated `localdns0` link |
| Survives restarts | files persist | rules persist in registry | agent re-applies on boot and watches resolved's bus name for restarts |

Two hard-won platform facts encoded here:

- **Linux**: resolved never allocates a DNS scope for a loopback link, and
  only for links that are **up and carry an address** — so the agent owns a
  dummy `localdns0` link with `198.51.100.53/32` (TEST-NET-2, never routed).
- **Windows**: NRPT is registry-visible (world-readable) so the app reads
  status unprivileged; only *writes* go through the helper, which re-derives
  the plan itself and only ever touches Comment-tagged rules.

The safety contract on every OS: foreign registrations covering a desired
zone are reported as **Managed elsewhere** and never modified; "Unregister
All" (and uninstall) removes only LocalDNS-owned state.

## The desktop app (Windows/Linux)

[`desktop/`](desktop/) is a Cargo workspace:

```
crates/localdns-core       engine (see above) + shared config paths
crates/localdns-server     tokio UDP/TCP server + self-test client
crates/localdns-platform   ResolverBackend trait + nrpt/resolved/mock impls
helper/localdns-helper     Windows service (NRPT scribe)
helper/localdns-agentd     Linux agent (resolved scribe)
cli/localdns-cli           `localdns` — headless companion
app/                       Tauri 2 shell + Svelte 5 frontend
```

App-shell decisions that took real debugging to earn:

- Sync Tauri commands run **on the main thread inside the WebKit IPC
  handler** — a mutex held across a struct-literal field boundary deadlocked
  the webview before first paint. Guards are bound in `let`s; the runtime is
  created explicitly before the builder.
- The UI mirrors the native app: the status orb *is* the self-test button,
  per-section actions live in the titlebar, the window skips the taskbar and
  lives in the tray (only when a tray exists — otherwise close quits so the
  app can't strand itself).
- Energy: no polling anywhere; query-log pushes are debounced 300 ms and skip
  hidden windows; the orb halo animates opacity in steps (never box-shadow);
  animations pause on hide, driven from Rust because WebKitGTK doesn't flip
  `document.hidden`. Idle cost ≈ noise floor even under software rendering.

## The CLI

`localdns` shares `rules.json` and the engine with the GUI (config location
override: `LOCALDNS_CONFIG_DIR`). `serve` runs the same server, hot-reloads
rules on a 2 s mtime watch, and re-registers zones through the same backend —
so `localdns add` from any shell is live within seconds. Ships in the
deb/rpm with a systemd user unit.

## Data formats

`rules.json` is byte-schema-identical across all three apps (alphabetically
sorted keys, omitted nulls, uppercase UUIDs — the Rust side reproduces
Swift's `JSONEncoder` conventions and a checked-in macOS fixture keeps it
honest). Locations:

- macOS app: `~/Library/Containers/com.localdns.app/Data/Library/Application Support/LocalDNS/rules.json`
- Windows: `%APPDATA%\LocalDNS\rules.json`
- Linux: `~/.config/localdns/rules.json`

## Testing

- Swift: 67 XCTest cases over `Core/` (codec attacks, matcher semantics,
  resolver planning against temp dirs, live loopback round-trip).
- Rust: the ported oracle suites + platform-specific units (NRPT ownership
  mapping, agent-reply parsing, dnsmasq config generation), server
  integration tests against real bound sockets, CLI integration tests that
  drive the actual binary (round-trip, validation, every subcommand, serve +
  hot reload + SIGTERM unregister), and app-shell tests that call the real
  `#[tauri::command]` functions on tauri's mock runtime — including a live
  UDP self-test round-trip through a really-bound server.
- Frontend: vitest over the store derivations, the command-name mapping, and
  IPC wiring with a mocked Tauri bridge.
- **Coverage is gated in CI at ≥80% lines** (`cargo llvm-cov`, per OS) and
  ≥80% on the frontend logic modules (vitest v8 thresholds). Excluded from
  the Rust gate: app/daemon bootstrap glue (`lib.rs`/`main.rs`, the service
  loops) and the D-Bus/registry plumbing that only a live resolved/NRPT can
  execute — those are what the VM end-to-end passes validate.
- Determinism seams the suites run through: `LOCALDNS_CONFIG_DIR` (isolated
  config), `LOCALDNS_BACKEND=mock` (never touches the machine's resolver),
  `LOCALDNS_HOSTS_PATH` (importer input).
- CI runs everything on Ubuntu and Windows; releases build from tags (see
  `.github/workflows/`).
