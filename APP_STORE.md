# LocalDNS — App Store submission playbook

Complete checklist + copy-paste metadata for submitting LocalDNS to the Mac App Store.

---

## 1. App Store Connect metadata

**Name:** LocalDNS

**Subtitle** (≤30 chars):
```
Wildcard DNS for local dev
```

**Promotional text** (≤170 chars, editable any time):
```
One rule, infinite hostnames. Point *.myapp.test at your dev box and every
subdomain resolves — no hosts-file edits, no sudo loops, no daemons. Built for
the way you already work.
```

**Description:**
```
LocalDNS gives you wildcard DNS for local development — the missing piece
between /etc/hosts and a full dnsmasq setup.

One rule like *.myapp.test → 172.30.0.3 and every hostname under it resolves:
api.myapp.test, db.myapp.test, tenant-42.myapp.test. Add a second rule for
*.staging.test and you're done. No more appending one line per hostname to
/etc/hosts every time a container or worktree spins up.

HOW IT WORKS
• A tiny DNS server embedded in the app answers on 127.0.0.1:15353 — loopback
  only, nothing ever leaves or enters your machine.
• Zones are registered with the macOS system resolver, so every app — browsers,
  curl, your IDE — resolves your names. Not just dig.

DESIGNED FOR YOUR WORKFLOW
• Wildcard and exact rules with IPv4/IPv6 targets, per-rule TTL, groups with
  one-switch enable.
• Import from /etc/hosts: LocalDNS finds groups of hostnames that collapse into
  a single wildcard rule. It never modifies /etc/hosts — Helm or any other
  manager keeps owning it, and they work side by side.
• Lives in the menu bar with a live status orb, recent-queries glance, and a
  master switch.
• Diagnostics: a live query log with answers, NXDOMAIN/NODATA outcomes, and
  latency, plus a one-click self-test.

PRIVATE BY CONSTRUCTION
LocalDNS collects nothing, transmits nothing, and talks to no server. The DNS
server binds the loopback interface only. No analytics, no ads, no accounts.

ONE-TIME SETUP, NO BACKGROUND ROOT
Registering zones requires one Terminal command that you run yourself (the app
shows it with a copy button) and one folder pick. After that, everything is
automatic — and your password is never seen by the app.
```

**Keywords** (≤100 chars, comma-separated):
```
dns,wildcard,hosts,local,dev,test,domain,network,developer,resolver
```
(67 characters — under the 100 limit.)

**Category:** Developer Tools (primary) · Utilities (secondary)
**Age rating:** 4 (no objectionable content; answer "No" to everything)
**Pricing:** your call; the copy supports paid-upfront or free.

---

## 2. Privacy nutrition label

**Declare: "Data Not Collected".**

Reasoning, verified against the code:

- No analytics, crash reporting, ads, or tracking SDKs — the project has zero
  third-party dependencies (Foundation + Network only).
- The embedded DNS server binds **loopback only** — `DNSServer.start()` pins
  `NWParameters.requiredLocalEndpoint` to `127.0.0.1`, so it cannot receive
  packets from (or send answers to) any other machine. Verified with `lsof`:
  `UDP 127.0.0.1:15353` / `TCP 127.0.0.1:15353 (LISTEN)`.
- `network.client` is used only by the self-test, which queries `127.0.0.1`
  (the app's own server). Nothing is sent to the internet.
- Rules and settings persist locally: `Application Support/LocalDNS/rules.json`
  inside the sandbox container, plus `UserDefaults`.
- The query log lives in memory only (200-entry ring buffer), never written
  to disk, cleared on quit.

---

## 3. App Review notes (paste into the review-information field)

```
WHAT THE APP DOES
LocalDNS is a developer tool: an embedded DNS server on 127.0.0.1:15353 plus
zone registration in /etc/resolver, so names like *.myapp.test resolve to local
addresses system-wide.

NETWORK SERVER ENTITLEMENT
com.apple.security.network.server is the core function of the app: it listens
for DNS queries. The listener binds 127.0.0.1 exclusively (Network framework
requiredLocalEndpoint) — it is unreachable from the network. network.client is
used only by the in-app self-test, which queries 127.0.0.1 (itself).

THE ONE-TIME TERMINAL COMMAND (why review will see it)
Writing /etc/resolver requires privileges a sandboxed app cannot obtain —
programmatic escalation (osascript "with administrator privileges") is blocked
by the sandbox by design. So, like shipping hosts-file managers on the App
Store, the app asks the USER to run one command themselves, once:

  sudo mkdir -p /etc/resolver && sudo /bin/chmod +a "$USER allow
  read,write,execute,add_file,delete_child" /etc/resolver

The command is displayed in the app with a copy button; the app never sees the
password and never runs the command. The user then grants /etc/resolver once in
an open panel; the app keeps a security-scoped bookmark
(com.apple.security.files.bookmarks.app-scope + user-selected.read-write) and
writes only files it created (each marked "# LocalDNS" on the first line).
Foreign resolver files are never touched and are reported as conflicts.

HOW TO REVIEW WITHOUT ANY SETUP
The full app works without the Terminal command:
1. Launch LocalDNS (menu-bar icon appears; the window opens).
2. Rules → Add Rule: pattern "*.myapp.test", IPv4 "172.30.0.3" → Add.
3. In Terminal: dig @127.0.0.1 -p 15353 anything.myapp.test
   → returns 172.30.0.3. Try "dig @127.0.0.1 -p 15353 nope.test" → NXDOMAIN.
4. Diagnostics shows the live query log. Setup → Run Self-Test passes.
The /etc/resolver grant flow is reachable from Setup but is not required to
evaluate the app. No demo account is needed.
```

---

## 4. Screenshot checklist

Capture at **1280×800** or **1440×900** (16:10), light and/or dark — dark matches
the app's character. 3–5 shots:

1. **Rules** — 2–3 rules across two groups, one rule disabled.
   Caption: *"One rule, infinite hostnames."*
2. **Setup (granted state)** — zones list all "Registered", orb teal.
   Caption: *"One-time setup. No daemons, no background root."*
3. **Diagnostics** — log with answered + NXDOMAIN rows visible.
   Caption: *"Watch every lookup land — live."*
4. **Import** — a scanned /etc/hosts with suggestions expanded.
   Caption: *"Collapse dozens of hosts-file lines into one wildcard."*
5. (optional) **Menu-bar extra** open, showing orb + recent queries.
   Caption: *"Always one click away in the menu bar."*

Staging tips: seed rules via the UI before shooting; drive queries with
`dig @127.0.0.1 -p 15353 <name>` so Diagnostics has content; complete the
/etc/resolver grant first so Setup shows the granted state.

---

## 5. Pre-submission checklist

**Identity & signing**
- [ ] Change `PRODUCT_BUNDLE_IDENTIFIER` from the `com.localdns.app` placeholder
      to your own (both it and the team are set on the LocalDNS target →
      Signing & Capabilities). Release currently uses the SDK-default ad-hoc
      placeholder so local builds work unsigned — Xcode fills in your team.
- [ ] Version 1.0 / build 1 are already set (`MARKETING_VERSION`,
      `CURRENT_PROJECT_VERSION`) for app + test targets.
- [ ] App category is set in the target: Developer Tools
      (`INFOPLIST_KEY_LSApplicationCategoryType`).
- [ ] `UIDesignRequiresCompatibility` is intentionally **not** set — Liquid
      Glass stays on.
- [ ] Export compliance is pre-declared in the target:
      `ITSAppUsesNonExemptEncryption = NO` (standard system TLS only; nothing
      custom). App Store Connect will not ask further.
- [ ] `PrivacyInfo.xcprivacy` ships in the bundle (UserDefaults CA92.1 only —
      settings stored locally). Verify it survives the archive:
      `plutil -p "…/LocalDNS.app/Contents/Resources/PrivacyInfo.xcprivacy"`.
- [ ] **Verify the archived binary has no debugger entitlement** — ad-hoc
      "Sign to Run Locally" builds inject `get-task-allow`; a properly team-signed
      Release archive must NOT contain it. After archiving:
      `codesign -d --entitlements :- …/LocalDNS.app | grep get-task-allow` must
      print nothing. App Store rejects binaries that carry it.

**App Store Connect setup**
- [ ] A public **Support URL** is mandatory — a GitHub repo page or a simple
      landing page is enough.
- [ ] Marketing URL is optional but recommended.
- [ ] Price: paid-up-front tier of your choice (no IAP, no subscriptions — the
      binary contains no store code; select the tier in Pricing and Availability).

**Build & upload**
- [ ] `Product → Archive` with the LocalDNS scheme → validate → upload to
      App Store Connect.
- [ ] Optional direct distribution: export the archive with a Developer ID
      profile and notarize (`xcrun notarytool submit … --wait`, then
      `xcrun stapler staple`).
- [ ] TestFlight (macOS): add internal testers, smoke-test the sandboxed build
      from TestFlight once before submitting (entitlements behave identically,
      but verify the grant flow on a machine that never ran the Debug build).

**App Review**
- [ ] Paste the App Review notes above; attach nothing else.
- [ ] Privacy: declare "Data Not Collected".
- [ ] Age rating questionnaire: all "No" → 4.

**After approval**
- [ ] Bump `CURRENT_PROJECT_VERSION` for every subsequent upload;
      `MARKETING_VERSION` for user-facing releases.
