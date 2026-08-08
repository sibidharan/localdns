import Foundation

/// The difference between the desired and the installed /etc/resolver state.
public struct ResolverSyncPlan: Equatable, Sendable {
    /// Zones whose resolver file must be (re)written (new, or owned-but-stale).
    public var installs: [String]
    /// Owned zones whose file must be deleted. Never contains foreign files.
    public var removals: [String]
    /// Desired zones blocked by a foreign resolver file (left untouched).
    public var conflicts: [String]

    public init(installs: [String] = [], removals: [String] = [], conflicts: [String] = []) {
        self.installs = installs
        self.removals = removals
        self.conflicts = conflicts
    }

    public var isNoop: Bool { installs.isEmpty && removals.isEmpty }
}

/// The result of a direct-write sync/uninstall.
public enum ResolverSyncOutcome: Equatable, Sendable {
    /// Nothing to change. Carries any foreign-file conflicts detected.
    case upToDate(conflicts: Set<String>)
    /// Files were written/removed. Carries any conflicts left unresolved.
    case applied(conflicts: Set<String>)
    /// A filesystem error that was not permission-related.
    case failed(String)
    /// /etc/resolver is missing (run the one-time Terminal command) or writes
    /// were denied (re-grant the folder / fix the ACL).
    case accessDenied
}

/// Manages /etc/resolver registration for the zones LocalDNS serves.
///
/// macOS routes DNS for a zone (and all its subdomains) to the nameserver listed
/// in /etc/resolver/<zone>; a `port` line selects a non-standard port.
///
/// Access model (App-Store-safe, no escalation): the user runs ONE Terminal
/// command (`ResolverAccess.terminalCommand`) creating /etc/resolver with an ACL
/// for their account, then grants LocalDNS the directory once via NSOpenPanel
/// (security-scoped bookmark, see `ResolverAccess`). From then on, everything
/// below is plain FileManager work — no prompts, no helpers, no root.
///
/// Safety contract: we NEVER touch a resolver file we did not create. Ownership
/// is proven by the marker line (`# LocalDNS`) as the first line of the file.
/// A foreign file for a desired zone is reported as a conflict and left alone.
public enum ResolverSetup {
    /// First line of every resolver file we write; proves ownership.
    public static let marker = "# LocalDNS"

    public static let resolverDirectory = URL(fileURLWithPath: "/etc/resolver")

    // MARK: Zone model

    /// Zones to register for the given rules: every enabled rule contributes its
    /// normalized pattern minus a leading "*.". An exact rule "host.test" therefore
    /// registers zone "host.test" — which also routes subdomains of host.test to
    /// us (acceptable: unmatched names simply get NXDOMAIN/NODATA like any other).
    public static func desiredZones(for rules: [DNSRule]) -> Set<String> {
        Set(rules.compactMap { rule in
            guard rule.enabled else { return nil }
            let pattern = rule.normalizedPattern
            let zone = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
            return zone.isEmpty ? nil : zone
        })
    }

    /// Content of /etc/resolver/<zone>: ownership marker, loopback nameserver, port.
    public static func fileContent(zone: String, port: UInt16) -> String {
        "\(marker)\nnameserver 127.0.0.1\nport \(port)\n"
    }

    // MARK: Scanning (no privileges needed; /etc/resolver is world-readable)

    /// Zones whose resolver file we own (first line is the marker).
    /// A missing (or inaccessible) directory simply means "nothing installed".
    public static func installedOwnedZones(resolverDir: URL = resolverDirectory) -> Set<String> {
        scan(resolverDir).owned
    }

    /// Zones with a resolver file we do NOT own (or cannot read) — never touched.
    public static func installedForeignZones(resolverDir: URL = resolverDirectory) -> Set<String> {
        scan(resolverDir).foreign
    }

    private static func scan(_ resolverDir: URL) -> (owned: Set<String>, foreign: Set<String>, ownedContent: [String: String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: resolverDir.path) else {
            return ([], [], [:])
        }
        var owned = Set<String>()
        var foreign = Set<String>()
        var ownedContent: [String: String] = [:]
        for name in names {
            let url = resolverDir.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else {
                foreign.insert(name) // unreadable entry or subdirectory: not ours
                continue
            }
            if text.hasPrefix(marker) {
                owned.insert(name)
                ownedContent[name] = text
            } else {
                foreign.insert(name)
            }
        }
        return (owned, foreign, ownedContent)
    }

    // MARK: Planning (pure — safe to call anywhere)

    /// Computes the difference between the desired and the installed state.
    public static func plan(rules: [DNSRule], port: UInt16, resolverDir: URL = resolverDirectory) -> ResolverSyncPlan {
        let desired = desiredZones(for: rules)
        let state = scan(resolverDir)
        var installs: [String] = []
        var conflicts: [String] = []
        for zone in desired {
            if state.foreign.contains(zone) {
                conflicts.append(zone) // someone else's file: leave it alone
            } else if !state.owned.contains(zone) || state.ownedContent[zone] != fileContent(zone: zone, port: port) {
                installs.append(zone) // missing, or ours but stale (e.g. port changed)
            }
        }
        return ResolverSyncPlan(installs: installs.sorted(),
                                removals: state.owned.subtracting(desired).sorted(),
                                conflicts: conflicts.sorted())
    }

    // MARK: Direct writes (plain FileManager — access comes from the bookmark + ACL)

    /// Brings /etc/resolver in line with the rules: writes new/stale owned files,
    /// deletes owned files no longer desired, never touches foreign files.
    /// The directory must already exist (created by the one-time Terminal
    /// command); a missing directory or a permission error maps to .accessDenied.
    @discardableResult
    public static func sync(rules: [DNSRule], port: UInt16, resolverDir: URL = resolverDirectory) -> ResolverSyncOutcome {
        guard FileManager.default.fileExists(atPath: resolverDir.path) else {
            return .accessDenied
        }
        let syncPlan = plan(rules: rules, port: port, resolverDir: resolverDir)
        guard !syncPlan.isNoop else { return .upToDate(conflicts: Set(syncPlan.conflicts)) }
        do {
            for zone in syncPlan.installs {
                try fileContent(zone: zone, port: port)
                    .write(to: resolverDir.appendingPathComponent(zone), atomically: true, encoding: .utf8)
            }
            for zone in syncPlan.removals {
                try FileManager.default.removeItem(at: resolverDir.appendingPathComponent(zone))
            }
            return .applied(conflicts: Set(syncPlan.conflicts))
        } catch {
            return mapError(error)
        }
    }

    /// Removes every resolver file we own; foreign files are left untouched.
    @discardableResult
    public static func uninstallAll(resolverDir: URL = resolverDirectory) -> ResolverSyncOutcome {
        guard FileManager.default.fileExists(atPath: resolverDir.path) else {
            return .accessDenied
        }
        let owned = installedOwnedZones(resolverDir: resolverDir)
        guard !owned.isEmpty else { return .upToDate(conflicts: []) }
        do {
            for zone in owned {
                try FileManager.default.removeItem(at: resolverDir.appendingPathComponent(zone))
            }
            return .applied(conflicts: [])
        } catch {
            return mapError(error)
        }
    }

    /// Proves that BOTH the sandbox bookmark and the POSIX ACL are in effect by
    /// creating and deleting a temp dotfile inside the resolver directory.
    public static func probeAccess(resolverDir: URL = resolverDirectory) -> Bool {
        let probe = resolverDir.appendingPathComponent(".localdns-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe) // direct create — exercises add_file
            try FileManager.default.removeItem(at: probe) // and delete_child
            return true
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return false
        }
    }

    private static func mapError(_ error: Error) -> ResolverSyncOutcome {
        let nsError = error as NSError
        let isPermission = (nsError.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code))
            || (nsError.domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(EPERM)].contains(nsError.code))
        return isPermission ? .accessDenied : .failed(nsError.localizedDescription)
    }
}
