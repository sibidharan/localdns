import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted by the app delegate when the app is re-opened (Spotlight/Finder/
    /// Launchpad relaunch) while already running — ContentView opens the window.
    static let localDNSOpenMainWindow = Notification.Name("LocalDNSOpenMainWindow")
}

/// Handles relaunch-to-open-window (essential when the menu-bar icon is
/// hidden) and routes Cmd+Q / system quit through the same unregister-on-quit
/// cleanup as the menu's Quit item.
final class LocalDNSAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: a second copy (e.g. a downloaded build opened
        // while another is running) would fight over the port, the rules file,
        // and the status item. Hand off to the running instance and vanish —
        // via exit(), NOT terminate(), so the duplicate can't run the
        // unregister-on-quit cleanup out from under the primary.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.localdns.app"
        ).filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
        if let primary = others.first {
            primary.activate()
            exit(0)
        }

        // The menu-bar icon is a plain NSStatusItem, not a MenuBarExtra scene:
        // SwiftUI's MenuBarExtra can silently fail to insert its item on menu
        // bars owned by third-party managers (Bartender and friends), leaving
        // the app unreachable. AppKit items insert reliably in the same setup.
        if let state = AppState.shared {
            menuBar = MenuBarController(appState: state)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.menuBar == nil, let state = AppState.shared else { return }
                self.menuBar = MenuBarController(appState: state)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .localDNSOpenMainWindow, object: nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared?.performQuitCleanup()
        return .terminateNow
    }
}

@MainActor
@main
struct LocalDNSApp: App {
    @NSApplicationDelegateAdaptor(LocalDNSAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("LocalDNS", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 840, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}

/// Owns the menu-bar status item: inserts/removes it per the Settings toggle
/// (`showMenuBarIcon`), keeps its symbol in sync with server state, and shows
/// the compact card in a transient popover on click.
@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var currentSymbol: String?
    private var stateCancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView().environmentObject(appState))

        // objectWillChange fires *before* values settle — refresh on the next
        // runloop turn. updateIcon no-ops unless the symbol actually changes,
        // so the per-query churn costs one string compare.
        stateCancellable = appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
        // The Settings toggle writes straight to UserDefaults.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.syncInsertion() }
        }

        syncInsertion()
    }

    private var iconWanted: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    private func syncInsertion() {
        if iconWanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "LocalDNSOrb"
            // Explicitly visible: overrides any stale hidden/parked flag a
            // previous session (or a menu-bar manager mishap) left behind.
            item.isVisible = true
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            statusItem = item
            currentSymbol = nil
            updateIcon()
        } else if !iconWanted, let item = statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if !appState.server.isRunning {
            symbol = "network.slash"
        } else {
            symbol = appState.orbState == .live
                ? "dot.radiowaves.left.and.right"
                : "exclamationmark.circle"
        }
        guard symbol != currentSymbol else { return }
        currentSymbol = symbol
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LocalDNS")
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Accessory app: activate so the popover takes key and transient
            // click-outside dismissal works.
            NSApplication.shared.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Compact menu-bar card on the standard popover material: orb + status,
/// master toggle, recent queries, Open / Quit. No custom fills.
private struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DNSOrb(state: appState.orbState, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LocalDNS")
                        .font(.system(.headline, design: .rounded))
                    Text(appState.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("DNS Server", isOn: Binding(
                    get: { appState.serverEnabled },
                    set: { appState.serverEnabled = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if !appState.queryEntries.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.queryEntries.prefix(5)) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: glyph(for: entry.outcome))
                                .font(.caption)
                                .foregroundStyle(glyphColor(for: entry.outcome))
                                .frame(width: 12)
                            Text(entry.name)
                                .font(Theme.domain(.caption))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(outcomeText(entry))
                                .font(Theme.domain(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Open LocalDNS") {
                    // Same path as Spotlight-relaunch: ContentView observes
                    // this and opens the window (works from AppKit hosting,
                    // where the openWindow environment action isn't available).
                    NotificationCenter.default.post(name: .localDNSOpenMainWindow, object: nil)
                }
                Spacer()
                Button("Quit") {
                    appState.quit()
                }
                .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func glyph(for outcome: QueryLogEntry.Outcome) -> String {
        switch outcome {
        case .answered: return "checkmark.circle.fill"
        case .nxdomain: return "xmark.circle.fill"
        case .noData: return "minus.circle.fill"
        }
    }

    private func glyphColor(for outcome: QueryLogEntry.Outcome) -> Color {
        switch outcome {
        case .answered: return .green
        case .nxdomain: return .red.opacity(0.9)
        case .noData: return .gray
        }
    }

    private func outcomeText(_ entry: QueryLogEntry) -> String {
        switch entry.outcome {
        case .answered(let address): return address
        case .noData: return "no \(entry.qtype) record"
        case .nxdomain: return "NXDOMAIN"
        }
    }
}
