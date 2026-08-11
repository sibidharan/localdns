import AppKit
import Combine
import Foundation
import Network
import ServiceManagement
import SwiftUI

/// Single source of truth for the UI: rules (persisted), the DNS server,
/// the query log, settings, and /etc/resolver registration state.
///
/// Main-actor isolated. The one exception is the DNS answer path: the server's
/// handler runs on the server's private queue and reads rules through
/// `rulesBox`, a lock-protected snapshot updated on every mutation.
@MainActor
final class AppState: ObservableObject {

    // MARK: Published state

    @Published private(set) var rules: [DNSRule]
    /// Newest-first snapshot of the query log, refreshed per query.
    @Published private(set) var queryEntries: [QueryLogEntry] = []

    @Published private(set) var desiredZones: Set<String> = []
    @Published private(set) var registeredZones: Set<String> = []
    @Published private(set) var resolverPlan = ResolverSyncPlan()
    /// Last sync/uninstall outcome.
    @Published private(set) var lastSyncOutcome: ResolverSyncOutcome?
    /// Whether the /etc/resolver security-scoped bookmark is active this session.
    @Published private(set) var resolverAccessGranted = false
    /// Whether probeAccess succeeded (bookmark AND POSIX ACL both in effect).
    @Published private(set) var resolverAccessWritable = false

    @Published private(set) var selfTestResult: (ok: Bool, message: String)?
    @Published private(set) var isSelfTesting = false

    @Published var launchAtLoginError: String?

    /// Set by the `-newRuleSheet*` launch arguments; RulesView presents the
    /// New Rule sheet for it (debug/E2E driver).
    @Published var debugNewRuleSheet: DebugNewRuleSeed?

    /// Set by the action bar's "Add Rule" button and the empty state;
    /// RulesView presents the New Rule sheet for it.
    @Published var showingNewRuleSheet = false
    /// Set by the action bar's "Grant Access…" button; SetupView presents the
    /// NSOpenPanel for it (the panel needs view context).
    @Published var grantPanelRequestID: UUID?

    // MARK: Import-from-hosts state (Helm bridge)

    /// Suggestions from the last scan; nil = never scanned.
    @Published private(set) var importSuggestions: [SuggestedRule]?
    @Published private(set) var importUncovered: [String] = []
    /// Keys ("pattern|ip") of suggestions added since the last scan.
    @Published private(set) var importAddedKeys: Set<String> = []

    func scanHosts() {
        let entries = HostsImporter.loadSystemHosts()
        importSuggestions = HostsImporter.suggestions(entries: entries)
        importUncovered = HostsImporter.uncovered(entries: entries, rules: rules)
        importAddedKeys = []
    }

    enum ImportSuggestionStatus: Equatable {
        case addable, added, alreadyExists
    }

    func importSuggestionStatus(_ suggestion: SuggestedRule) -> ImportSuggestionStatus {
        if importAddedKeys.contains(Self.importKey(suggestion)) { return .added }
        let pattern = DNSRule.normalize(suggestion.pattern)
        if rules.contains(where: { $0.normalizedPattern == pattern }) { return .alreadyExists }
        return .addable
    }

    var addableImportSuggestions: [SuggestedRule] {
        (importSuggestions ?? []).filter { importSuggestionStatus($0) == .addable }
    }

    func addSuggestedRule(_ suggestion: SuggestedRule) {
        addRule(suggestion.rule)
        importAddedKeys.insert(Self.importKey(suggestion))
        rescanImportUncovered()
    }

    func addAllSuggestedRules() {
        let batch = addableImportSuggestions
        addRules(batch.map(\.rule))
        importAddedKeys.formUnion(batch.map(Self.importKey))
        rescanImportUncovered()
    }

    private func rescanImportUncovered() {
        let entries = HostsImporter.loadSystemHosts()
        importUncovered = HostsImporter.uncovered(entries: entries, rules: rules)
    }

    static func importKey(_ suggestion: SuggestedRule) -> String {
        "\(suggestion.pattern)|\(suggestion.ip)"
    }

    // MARK: Settings (UserDefaults-backed via @AppStorage)

    static let defaultPort = 15353

    @AppStorage("serverPort") var port: Int = AppState.defaultPort {
        didSet { if port != oldValue { applyPortChange() } }
    }
    @AppStorage("serverEnabled") var serverEnabled: Bool = true {
        didSet { if serverEnabled != oldValue { applyServerEnabledChange() } }
    }
    @AppStorage("unregisterOnQuit") var unregisterOnQuit: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { if launchAtLogin != oldValue { applyLaunchAtLoginChange() } }
    }

    // MARK: Services

    private(set) var server: DNSServer
    /// Thread-safe; appended to from the server queue. Nonisolated on purpose.
    nonisolated let queryLog = QueryLog()
    /// Lock-protected rules snapshot read by the server handler off-main.
    nonisolated let rulesBox = RulesBox()

    private var store: RuleStore
    private var serverStateCancellable: AnyCancellable?

    init() {
        store = RuleStore()
        let loaded = store.rules
        rules = loaded
        rulesBox.set(loaded)
        // `port` (an @AppStorage property) can't be read until every stored
        // property is initialized, so read the same key directly here.
        let initialPort = UserDefaults.standard.object(forKey: "serverPort") as? Int ?? Self.defaultPort
        server = DNSServer(port: UInt16(clamping: initialPort))
        installServerHandler()
        observeServer()
        // After wake, verify the server actually answers — transport layers
        // have lied before (bound sockets, zero delivery). The probe rebinds
        // on silence; a second pass catches slow wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.server.probeNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                self?.server.probeNow()
            }
        }
        AppState.shared = self
        // Pick up a previously granted /etc/resolver access bookmark, if any.
        if let url = ResolverAccess.resolveBookmark() {
            resolverAccessGranted = true
            resolverAccessWritable = ResolverSetup.probeAccess(resolverDir: url)
        }
        refreshResolverStatus()
        if serverEnabled {
            startServer()
        }
        handleLaunchArguments()
    }

    // MARK: Server wiring

    private func installServerHandler() {
        server.handler = { [weak self] query in
            guard let self else { return DNSResponseBuilder.refused(to: query) }
            let started = Date()
            let resolution = DNSResolver.resolve(query, rules: self.rulesBox.rules)
            let data: Data
            switch resolution {
            case .answers(let answers):
                data = DNSResponseBuilder.response(to: query, answers: answers)
            case .noData:
                data = DNSResponseBuilder.empty(to: query)
            case .nxdomain:
                data = DNSResponseBuilder.nxdomain(to: query)
            }
            let latencyMs = Date().timeIntervalSince(started) * 1000
            self.queryLog.append(QueryLogEntry(query: query, resolution: resolution, latencyMs: latencyMs))
            Task { @MainActor [weak self] in self?.schedulePublishQueryLog() }
            return data
        }
    }

    private func observeServer() {
        serverStateCancellable = server.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    private func startServer() {
        do {
            try server.start()
        } catch {
            // Only DNSServerError.invalidPort is thrown synchronously, and the
            // port is clamped/validated (1024–65535) before it gets here.
        }
    }

    private func applyServerEnabledChange() {
        serverEnabled ? startServer() : server.stop()
        objectWillChange.send()
    }

    private func applyPortChange() {
        // DNSServer's port is immutable, so swap in a fresh instance.
        server.stop()
        server = DNSServer(port: UInt16(clamping: port))
        installServerHandler()
        observeServer()
        if serverEnabled {
            startServer()
        }
        refreshResolverStatus() // resolver files embed the port → staleness changes
        scheduleAutoSync()
        objectWillChange.send()
    }

    // MARK: Rules

    func addRule(_ rule: DNSRule) { mutateRules { $0.append(rule) } }

    func addRules(_ newRules: [DNSRule]) { mutateRules { $0.append(contentsOf: newRules) } }

    func updateRule(_ rule: DNSRule) {
        mutateRules { rules in
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index] = rule
            }
        }
    }

    func deleteRule(id: DNSRule.ID) { mutateRules { $0.removeAll { $0.id == id } } }

    func setEnabled(_ enabled: Bool, for id: DNSRule.ID) {
        mutateRules { rules in
            if let index = rules.firstIndex(where: { $0.id == id }) {
                rules[index].enabled = enabled
            }
        }
    }

    func setGroup(_ group: String, enabled: Bool) {
        mutateRules { rules in
            for index in rules.indices where rules[index].group == group {
                rules[index].enabled = enabled
            }
        }
    }

    private func mutateRules(_ change: (inout [DNSRule]) -> Void) {
        change(&rules)
        rulesBox.set(rules)
        store.rules = rules
        try? store.save()
        refreshResolverStatus()
        scheduleAutoSync()
    }

    // MARK: Query log

    private var logPublishTask: Task<Void, Never>?

    /// Coalesced log publication: busy DNS traffic would otherwise fire one
    /// @Published update (and a full view-body re-evaluation) per query. A short
    /// trailing debounce keeps the UI near-live while idle apps stay idle.
    private func schedulePublishQueryLog() {
        guard logPublishTask == nil else { return }
        logPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.queryEntries = self.queryLog.entries
            self.logPublishTask = nil
        }
    }

    func clearLog() {
        queryLog.clear()
        queryEntries = []
    }

    // MARK: /etc/resolver registration

    func refreshResolverStatus() {
        desiredZones = ResolverSetup.desiredZones(for: rules)
        registeredZones = ResolverSetup.installedOwnedZones()
        resolverPlan = ResolverSetup.plan(rules: rules, port: UInt16(clamping: port))
    }

    /// Direct FileManager writes — cheap and synchronous (the ACL + bookmark do
    /// the heavy lifting; no escalation ever happens here).
    func syncResolver(completion: (@Sendable (ResolverSyncOutcome) -> Void)? = nil) {
        let outcome = ResolverSetup.sync(rules: rules, port: UInt16(clamping: port))
        lastSyncOutcome = outcome
        refreshResolverStatus()
        completion?(outcome)
    }

    func unregisterResolver(completion: (@Sendable (ResolverSyncOutcome) -> Void)? = nil) {
        let outcome = ResolverSetup.uninstallAll()
        lastSyncOutcome = outcome
        refreshResolverStatus()
        completion?(outcome)
    }

    // MARK: /etc/resolver access grant (security-scoped bookmark)

    /// Called after the user picks /etc/resolver in the open panel. Keeps the
    /// bookmark even when the probe fails (ACL missing) so "Re-check" suffices
    /// after the user runs the Step 1 command.
    func grantResolverAccess(to url: URL) {
        // The panel starts at /etc/resolver, but the user can navigate away —
        // refuse anything that isn't the real resolver directory.
        guard ResolverAccess.isResolverDirectory(url) else {
            lastSyncOutcome = .failed("That isn't /etc/resolver — please select the /etc/resolver folder.")
            return
        }
        do {
            try ResolverAccess.saveBookmark(for: url)
        } catch {
            lastSyncOutcome = .failed("Could not save the access bookmark: \(error.localizedDescription)")
            return
        }
        guard let resolved = ResolverAccess.resolveBookmark() else {
            lastSyncOutcome = .failed("The access bookmark could not be resolved — try granting access again.")
            return
        }
        resolverAccessGranted = true
        resolverAccessWritable = ResolverSetup.probeAccess(resolverDir: resolved)
        lastSyncOutcome = nil
        if resolverAccessWritable {
            syncResolver() // apply current rules immediately
        }
        refreshResolverStatus()
    }

    /// Re-probes access (after the user ran the Step 1 Terminal command).
    func recheckResolverAccess() {
        guard let url = ResolverAccess.activeAccessURL else {
            resolverAccessGranted = false
            resolverAccessWritable = false
            return
        }
        resolverAccessWritable = ResolverSetup.probeAccess(resolverDir: url)
        if resolverAccessWritable {
            syncResolver()
        } else {
            refreshResolverStatus()
        }
    }

    /// Forgets the bookmark; zones already written stay in place (use
    /// "Unregister All" first to remove them).
    func revokeResolverAccess() {
        ResolverAccess.clearBookmark()
        resolverAccessGranted = false
        resolverAccessWritable = false
        lastSyncOutcome = nil
        refreshResolverStatus()
    }

    // MARK: Auto-sync

    private var autoSyncTask: Task<Void, Never>?

    /// Debounced (~300 ms) sync after rule/port changes — only when folder
    /// access is active. Cheap FileManager work; a no-op sync is harmless.
    private func scheduleAutoSync() {
        guard resolverAccessGranted, resolverAccessWritable else { return }
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.syncResolver()
        }
    }

    // MARK: Launch arguments

    /// Supported launch arguments (also handy for scripts and E2E tests):
    ///   -syncZones            ~1s after launch, run the Setup tab's "Register Zones"
    ///                         action and print the outcome to stdout.
    ///   -unregisterZones      same, for "Unregister All".
    ///   -newRuleSheet         present the New Rule sheet on launch (empty).
    ///   -newRuleSheetInvalid  same, seeded with a committed invalid pattern
    ///                         (shows the after-commit error state).
    ///   -newRuleSheetValid    same, seeded with a valid wildcard (shows the
    ///                         live match preview).
    /// Anything else launches the app completely unchanged.
    private func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsSync = arguments.contains("-syncZones")
        let wantsUnregister = arguments.contains("-unregisterZones")
        let sheetSeed: DebugNewRuleSeed? =
            arguments.contains("-newRuleSheetInvalid") ? .invalid
            : arguments.contains("-newRuleSheetValid") ? .valid
            : arguments.contains("-newRuleSheet") ? .empty
            : nil
        guard wantsSync || wantsUnregister || sheetSeed != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1)) // let the server come up first
            guard let self else { return }
            if let sheetSeed {
                debugNewRuleSheet = sheetSeed
            }
            if wantsSync {
                syncResolver { Self.logOutcome("syncZones", $0) }
            } else if wantsUnregister {
                unregisterResolver { Self.logOutcome("unregisterZones", $0) }
            }
        }
    }

    /// Unbuffered stdout write (plain `print` can sit in the block buffer when
    /// stdout is redirected to a file/pipe, which is exactly how tests capture it).
    private nonisolated static func logOutcome(_ label: String, _ outcome: ResolverSyncOutcome) {
        FileHandle.standardOutput.write(Data("[LocalDNS] \(label) outcome: \(outcome)\n".utf8))
    }

    // MARK: Self-test

    func runSelfTest() {
        guard !isSelfTesting else { return }
        guard let rule = rules.first(where: { $0.enabled && ($0.ipv4 != nil || $0.ipv6 != nil) }) else {
            selfTestResult = (false, "Add an enabled rule first — there is nothing to query.")
            return
        }
        let name = rule.isWildcard
            ? "localdns-selftest.\(String(rule.normalizedPattern.dropFirst(2)))"
            : rule.normalizedPattern
        let qtype = rule.ipv4 != nil ? DNSMessage.typeA : DNSMessage.typeAAAA
        let expected = (rule.ipv4 ?? rule.ipv6)!

        isSelfTesting = true
        selfTestResult = nil
        let testPort = UInt16(clamping: port)
        Task {
            defer { isSelfTesting = false }
            do {
                let result = try await DNSClient.lookup(name: name, qtype: qtype, port: testPort)
                if result.answers.contains(where: { Self.addressesEqual($0, expected) }) {
                    selfTestResult = (true, "OK — \(name) → \(expected)")
                } else if result.rcode == DNSResponseBuilder.rcodeNXDomain {
                    selfTestResult = (false, "Server answered NXDOMAIN for \(name).")
                } else {
                    let got = result.answers.joined(separator: ", ")
                    selfTestResult = (false, "Unexpected answer for \(name) (rcode \(result.rcode))\(got.isEmpty ? "" : ": \(got)")")
                }
            } catch {
                selfTestResult = (false, "No response from 127.0.0.1:\(testPort) — \(error.localizedDescription)")
            }
        }
    }

    private static func addressesEqual(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.contains(":") || rhs.contains(":") {
            return IPv6Address(lhs)?.rawValue == IPv6Address(rhs)?.rawValue
        }
        return IPv4Address(lhs)?.rawValue == IPv4Address(rhs)?.rawValue
    }

    // MARK: Launch at login

    private func applyLaunchAtLoginChange() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }

    // MARK: Quit

    /// Set in init; used by the app delegate to route Cmd+Q / system quit
    /// through the same cleanup as the menu's Quit item.
    static weak var shared: AppState?

    /// The unregister-on-quit cleanup, shared by quit() and the app delegate's
    /// applicationShouldTerminate (a direct, instant write when folder access
    /// is granted).
    func performQuitCleanup() {
        if unregisterOnQuit, resolverAccessGranted {
            _ = ResolverSetup.uninstallAll()
        }
    }

    func quit() {
        performQuitCleanup()
        NSApplication.shared.terminate(nil)
    }
}

/// Lock-protected rules snapshot, readable from the server's handler queue.
final class RulesBox: @unchecked Sendable {
    private var value: [DNSRule] = []
    private let lock = NSLock()

    var rules: [DNSRule] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ rules: [DNSRule]) {
        lock.lock()
        value = rules
        lock.unlock()
    }
}
