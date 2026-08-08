# LocalDNS

Wildcard DNS for local development on macOS. Point `*.myapp.test` at `172.30.0.3`
and every hostname under it — `api.myapp.test`, `db.myapp.test`, anything — resolves,
with zero per-host bookkeeping. LocalDNS runs a tiny DNS server on `127.0.0.1:15353`
(loopback only) and registers your zones with the macOS system resolver, so every app
(browsers included) just works.

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

```
LocalDNS/
  LocalDNSApp.swift        @main: Window + MenuBarExtra, state-symbol label
  AppState.swift           @MainActor source of truth: rules, server, log,
                           resolver status, settings (@AppStorage), launch flags
  Views/
    ContentView.swift      NavigationSplitView shell + section switch
    ActionBar.swift        floating functional bar (orb, status, section actions)
    RulesView.swift        grouped rule rows, group switches, add/edit/delete
    RuleEditSheet.swift    add/edit sheet with validation
    ImportHostsView.swift  /etc/hosts suggestions
    SetupView.swift        grant flow, zones, self-test
    DiagnosticsView.swift  live query log
    SettingsView.swift     port, launch-at-login, unregister-on-quit
    Theme.swift            palette + typography discipline
    Glass.swift            all #available(macOS 26) gating + small components
    DNSOrb.swift           the status orb (teal/amber/gray, breathing)
  Core/                    pure Foundation + Network — no SwiftUI/AppKit;
                           compiles standalone with swiftc (CLI-spike-ready)
    DNSMessage.swift       DNS wire codec (parse queries, build responses)
    DNSServer.swift        UDP+TCP listener, loopback-only via requiredLocalEndpoint
    DNSClient.swift        tiny client used by the self-test
    Rules.swift            DNSRule, matcher (longest wins), JSON store, resolver
    ResolverSetup.swift    zone derivation, ownership scan, direct FileManager writes
    ResolverAccess.swift   security-scoped bookmark for /etc/resolver + the
                           one-time Terminal command text
    HostsImporter.swift    /etc/hosts parser + wildcard suggestions
    QueryLog.swift         thread-safe ring buffer of recent queries
LocalDNSTests/             67 XCTest cases covering the Core
```

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
