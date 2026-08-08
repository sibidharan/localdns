import Foundation

/// Security-scoped bookmark management for the /etc/resolver directory grant.
///
/// The flow (the proven App Store pattern for writing to system locations from
/// the sandbox): the user runs one Terminal command (see `terminalCommand`),
/// then picks /etc/resolver in an NSOpenPanel once. We persist the resulting
/// security-scoped bookmark and resolve + start-accessing it on every launch.
/// Thereafter ResolverSetup's plain FileManager writes just work.
public enum ResolverAccess {

    /// The one-time Terminal command: creates /etc/resolver and grants the
    /// user's account an ACL to add/remove files in it. `$USER` expands in the
    /// user's shell. LocalDNS never runs this itself — the user does, once.
    public static let terminalCommand =
        #"sudo mkdir -p /etc/resolver && sudo /bin/chmod +a "$USER allow read,write,execute,add_file,delete_child" /etc/resolver"#

    /// Where the bookmark Data is persisted (next to rules.json).
    public static let defaultBookmarkURL: URL =
        RuleStore.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("resolver.bookmark")

    /// The URL currently being accessed under a security scope, if any.
    public static var activeAccessURL: URL? { lease.current }

    /// True only when `url` is the real /etc/resolver directory. The open panel
    /// starts there, but the user can navigate away — accepting any other
    /// folder would bookmark the wrong location and ResolverSetup would write
    /// zone files into it. Symlinks are resolved first (/etc → /private/etc).
    public static func isResolverDirectory(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == ResolverSetup.resolverDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Saving (called right after the NSOpenPanel grant)

    /// Creates a security-scoped bookmark for `url` and persists it atomically.
    public static func saveBookmark(for url: URL, to bookmarkURL: URL = defaultBookmarkURL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: bookmarkURL, options: .atomic)
    }

    // MARK: Resolving (called on launch)

    /// Resolves the persisted bookmark and starts accessing the security-scoped
    /// resource. The lease is deliberately kept for the whole process lifetime:
    /// `stopAccessingSecurityScopedResource` is never called — exiting the
    /// process releases it, and releasing early would only break FileManager
    /// access later. Returns nil when no usable bookmark exists (missing or
    /// stale); the caller must then run the grant flow again.
    @discardableResult
    public static func resolveBookmark(from bookmarkURL: URL = defaultBookmarkURL) -> URL? {
        guard let data = try? Data(contentsOf: bookmarkURL) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 bookmarkDataIsStale: &stale),
              !stale,
              url.startAccessingSecurityScopedResource()
        else { return nil }
        lease.set(url)
        return url
    }

    /// Deletes the persisted bookmark. The current process keeps its lease
    /// until exit (harmless), but the next launch starts ungranted.
    public static func clearBookmark(at bookmarkURL: URL = defaultBookmarkURL) {
        try? FileManager.default.removeItem(at: bookmarkURL)
        lease.set(nil)
    }

    // MARK: Lease

    private static let lease = AccessLease()

    /// Lock-protected holder for the security-scope lease (Swift 6: static
    /// mutable state must be concurrency-safe).
    private final class AccessLease: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?

        var current: URL? {
            lock.lock()
            defer { lock.unlock() }
            return url
        }

        func set(_ url: URL?) {
            lock.lock()
            self.url = url
            lock.unlock()
        }
    }
}
