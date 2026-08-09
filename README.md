<p align="center">
  <img src="docs/icon.png" alt="LocalDNS" width="128" height="128">
</p>

<h1 align="center">LocalDNS</h1>

<p align="center"><b>Wildcard DNS for local development — macOS · Windows · Linux</b></p>

Point `*.myapp.test` at `172.30.0.3` and every hostname under it —
`api.myapp.test`, `db.myapp.test`, anything — resolves, with zero per-host
bookkeeping. LocalDNS runs a tiny DNS server on loopback only and registers
your zones with the operating system's resolver, so every app (browsers
included) just works. Everything else on your machine resolves exactly as
before: LocalDNS answers **only** the zones you configure.

## Get LocalDNS

| Platform | How | Price |
|---|---|---|
| **macOS** | Native SwiftUI app — *coming to the Mac App Store*; until then an [unsigned developer build](https://github.com/sibidharan/localdns/releases) is on Releases (right-click → Open) | Paid on the App Store — buying it funds development of all platforms |
| **Windows** | [Installer from Releases](https://github.com/sibidharan/localdns/releases) (NSIS, includes the helper service) | Free |
| **Linux** | [.deb / .rpm / .AppImage from Releases](https://github.com/sibidharan/localdns/releases) (includes the `localdns` CLI for headless boxes) | Free |

The entire codebase — macOS app, Windows/Linux apps, CLI — is open source in
this repository. The Mac App Store build is the same code with Apple's
signing, notarization, sandboxing, and automatic updates; if LocalDNS saves
you time, buying it there is how you say thanks. On Windows and Linux it is
simply free.

## Why LocalDNS instead of…

**…`/etc/hosts`?** Hosts files can't do wildcards. Ten services under
`*.myapp.test` means ten lines to maintain — and another edit every time a
service appears. LocalDNS collapses them to one rule (and can import your
existing hosts entries and suggest the wildcards that replace them — it never
modifies the hosts file itself).

**…dnsmasq?** dnsmasq is excellent, and if you already run it happily, keep
it — `address=/myapp.test/172.30.0.3` does this job. The gap LocalDNS fills
is *integration with the resolver your OS already runs*:

- On modern Linux, systemd-resolved owns the stub resolver. Wiring dnsmasq in
  means winning a fight over port 53, changing NetworkManager's `dns=` mode,
  or replacing resolved entirely. LocalDNS instead **cooperates** with
  resolved: per-zone routing domains on a dedicated link, server on an
  unprivileged port, nothing else touched — your VPN's DNS, mDNS, and
  corporate split-horizon setups keep working.
- On macOS there is no dnsmasq at all unless you install and babysit it;
  LocalDNS uses the native `/etc/resolver` mechanism Apple built for exactly
  this.
- On Windows the equivalent hand-rolled setup (NRPT rules + something
  answering on port 53) is genuinely fiddly; LocalDNS automates it with a
  demand-start service and cleans up after itself.
- Same rules, same UI, same behavior on all three OSes — plus guards dnsmasq
  won't give you (public-suffix wildcard protection, `.local`/mDNS warnings,
  live per-query diagnostics, a self-test button).

**…systemd-resolved alone?** resolved routes zones to DNS servers but cannot
answer `*.zone → address` itself. LocalDNS is the missing answering half,
attached the way resolved wants.

## How it works on every OS

The same design everywhere: an **unprivileged** DNS server on loopback, and a
small, auditable, per-OS mechanism that only *registers zones* — the one-time
consent is visible, and no root process runs routinely.

| OS | Zone registration | Server binds | Privilege model |
|---|---|---|---|
| macOS | `/etc/resolver/<zone>` files (native Apple mechanism) | `127.0.0.1:15353` | One visible `sudo` command once, then a sandboxed security-scoped grant |
| Windows | NRPT rules tagged `Comment=LocalDNS` | `127.65.43.53:53` + `127.0.0.1:15353` (NRPT has no port field) | Demand-start `localdns-helper` service installed once by the installer; stops itself when idle |
| Linux | systemd-resolved routing domains on a dedicated `localdns0` link | `127.0.0.1:15353` (resolved supports ports) | Hardened `localdns-agentd` (CAP_NET_ADMIN only, polkit-gated D-Bus API); survives resolved restarts and reboots |

Ownership is always explicit (`# LocalDNS` marker line, NRPT comment, the
dedicated link): LocalDNS never touches resolver state it didn't create.
Anything foreign covering one of your zones is reported as **Managed
elsewhere** and left alone. "Unregister All" — or uninstalling — removes
every trace.

The Windows/Linux desktop apps live in [`desktop/`](desktop/) (Rust +
Tauri, full feature parity, ~2 MB installers). Headless Linux boxes get the
[`localdns` CLI](desktop/README.md#headless--cli): same `rules.json` as the
GUI, `localdns add '*.myapp.test' 172.30.0.3 && localdns serve`, done.

---

# The native macOS app

Sandboxed, App-Store-safe, no helpers, no daemons, no root process ever running.

## Features

- **Wildcard & exact rules** — `*.myapp.test` (matches the apex and any depth of
  subdomain, dnsmasq-style) or `host.test`, with IPv4 and/or IPv6 targets, per-rule
  TTL, enable toggles, and groups with group-level switches.
- **System integration** — zones are registered in `/etc/resolver` (with the custom
  port), so the macOS resolver routes your zones to LocalDNS. One-time setup, no
  background privilege: see below.
- **Import from /etc/hosts** — scans your hosts file and suggests the wildcard rules
  that collapse groups of entries (2+ names sharing an address and parent domain).
  LocalDNS never modifies `/etc/hosts` — Helm or any other manager can keep owning it.
- **Menu-bar agent** — live status orb, master switch, recent queries, no Dock icon.
- **Diagnostics** — live query log with answers, NXDOMAIN/NODATA outcomes, and latency.
- **Self-test** — sends a real query to the local server and checks the answer.
- **Automatic zone sync** — rule or port changes re-sync `/etc/resolver` automatically.
- **Liquid Glass UI** on macOS 26 (graceful system-standard fallbacks on macOS 14+).

## Screenshots

_(placeholder — capture at 1280×800 or 1440×900 before submission; see APP_STORE.md
for the shot list and captions)_

- Rules — wildcard rules with one-click toggles
- Setup — the two-step, one-time grant flow
- Diagnostics — live query log

## Build & run

Requirements: Xcode 26 (Swift 6), macOS 14+ deployment target.

1. Open `LocalDNS.xcodeproj` in Xcode.
2. Select the **LocalDNS** target → **Signing & Capabilities** → pick your team.
   The bundle identifier is a placeholder (`com.localdns.app`) — change it to yours.
   Debug builds also work unsigned ("Sign to Run Locally") out of the box.
3. Run the **LocalDNS** scheme.

Command line (prefix required when xcode-select points at the CLT):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project LocalDNS.xcodeproj -scheme LocalDNS -destination 'platform=macOS' build
```

## One-time /etc/resolver setup

Sandboxed apps cannot escalate privileges (verified: `osascript … with administrator
privileges` fails inside the sandbox). So LocalDNS uses the App-Store-safe pattern:

1. **You run one Terminal command yourself** (the app shows it with a copy button;
   your password is never seen by the app):

   ```sh
   sudo mkdir -p /etc/resolver && sudo /bin/chmod +a "$USER allow read,write,execute,add_file,delete_child" /etc/resolver
   ```

2. **You pick `/etc/resolver` once in an open panel.** The app stores a
   security-scoped bookmark; from then on it writes its zone files directly —
   no prompts, ever again.

The app only ever touches files it created (each starts with the `# LocalDNS`
marker). Files managed by anything else are reported as conflicts and left alone.
"Unregister All Zones" removes them; an optional setting removes them on quit.

Without the setup, the DNS server still runs and answers on `127.0.0.1:15353`
(verify with `dig @127.0.0.1 -p 15353 foo.myapp.test`) — macOS just won't route
system lookups to it until the zone files exist.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full system — the shared
engine (implemented in Swift and Rust with the Swift test suites as the
port's oracle), the per-OS registration mechanisms and privilege models, the
desktop app internals, and the CLI. Quick orientation:

- [`LocalDNS/`](LocalDNS/) — native macOS app (SwiftUI + pure-Foundation `Core/`)
- [`desktop/`](desktop/) — Windows/Linux app (Rust + Tauri), helpers, and the `localdns` CLI

## Testing

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project LocalDNS.xcodeproj -scheme LocalDNS -destination 'platform=macOS' test
```

The suite covers the wire codec (including compression-pointer attacks), rule
matching semantics, store round-trips, resolver planning and direct writes against
temp directories, bookmark save/resolve, the hosts importer, the query log, and a
live loopback server↔client round-trip. The Core compiles standalone:

```sh
swiftc -parse-as-library -emit-module -emit-library LocalDNS/Core/*.swift \
  -o /tmp/ldcore.so -module-name LocalDNSCore
```

## Launch flags

- `-syncZones` — ~1 s after launch, run the same zone sync as the Setup action and
  print `[LocalDNS] syncZones outcome: …` to stdout (unbuffered).
- `-unregisterZones` — same for "Unregister All".

Useful for scripts and end-to-end tests.

## Roadmap (v1.1 ideas)

- DoH upstream forwarding for non-matching zones
- iOS companion (NEAppProxy/NEPacketTunnel exploration)
- Menu-bar-only mode (no main window)
- Per-zone TTL presets, import/export of rule sets
