# LocalDNS Roadmap

What would make LocalDNS meaningfully better, ordered by leverage. Near-term
items are concrete and scoped; later items are direction, not commitment.

## Near term (next releases)

**Trust & distribution** — the biggest gap between "works" and "feels safe":
- macOS: App Store listing (signed, notarized, sandboxed — the build already
  is); keep the unsigned dev zip until it ships.
- Windows: Authenticode signing to kill the SmartScreen warning, then
  `winget install localdns`.
- Linux: apt/dnf repositories (or at least a stable download URL per distro),
  AUR package, Fedora COPR.
- Auto-update: Tauri updater for the NSIS build and AppImage; deb/rpm update
  through their repos; App Store handles macOS.

**Rules that travel**:
- Import/export from the UI (`rules.json` is already portable across all
  three OSes — surface it: export file, import with merge/replace choice).
- `localdns export | localdns import` for scripted setups and dotfiles.

**Setup ergonomics**:
- Template gallery on first run: `*.test → 127.0.0.1` one-click, plus a
  container-networking preset (`*.docker.test → <bridge IP>`).
- Port-conflict detection with a named culprit ("Docker Desktop is on :53")
  instead of a bare bind error.

## Mid term

**Rule engine depth** (all shared across GUI + CLI on every OS):
- Multiple addresses per rule with round-robin answers (simple load-balance
  parity for local clusters).
- Exception rules: `*.app.test` wildcard with `api.app.test` carved out to a
  different address — longest-match already gets close; make the intent
  first-class.
- Named profiles: snapshot/switch whole rule sets (work / client-A / demo);
  groups become sections within a profile.

**Observability**:
- Query log: filter box, outcome filter, per-rule attribution ("answered by
  `*.app.test`"), export as JSON lines.
- Optional periodic zone health check (opt-in, energy-budgeted) surfacing
  "zone registered but not answering" in the tray before the user hits it.

**Linux breadth**:
- Implement the NetworkManager+dnsmasq tier-2 backend (currently
  instruct-only) for distros without systemd-resolved.
- Flatpak feasibility: the agentd split may allow it (portal-less D-Bus
  system service + sandboxed GUI); document the verdict either way.

## Engineering (continuous)

- **Coverage**: CI gates ≥80% lines on Ubuntu and Windows (see
  [ARCHITECTURE.md](ARCHITECTURE.md#testing)); raise `linux/mod.rs` by
  extracting the D-Bus reply parsing behind pure seams.
- **Fuzzing**: `cargo-fuzz` target on the DNS codec (it parses untrusted
  network input; the pointer-attack tests are a start, not a proof).
- **Property tests**: proptest the matcher against the Swift oracle semantics
  (longest-wins, tie-keeps-earlier, normalization idempotence).
- **Supply chain**: `cargo audit`/`cargo deny` in CI, Dependabot, checksums +
  SBOM attached to releases.
- **Benchmarks**: criterion on the resolve hot path with a budget, so a
  regression fails loudly instead of warming laptops quietly.

## Explicitly out of scope

- **Upstream forwarding / recursive resolution** — LocalDNS is authoritative
  for your dev zones and nothing else; forwarding would make it a resolver
  replacement (dnsmasq/unbound territory) and drag in cache coherence,
  DNSSEC, and privacy questions. The per-OS split-DNS mechanisms exist
  precisely so everything else keeps flowing through the system resolver.
- **Telemetry** — none. Diagnostics stay local; a future "export diagnostics
  bundle" button is the ceiling.
