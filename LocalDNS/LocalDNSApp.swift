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

    /// Posted (distributed) by a duplicate instance right before it exits, so
    /// the surviving primary brings its window forward.
    static let showWindowNote = Notification.Name("com.localdns.app.show-main-window")

    /// True when loginwindow auto-launched this process as a login item. The
    /// launch open-event carries the flag and is "current" only while
    /// applicationDidFinishLaunching runs — it cannot be read later.
    /// nonisolated(unsafe): written once in applicationDidFinishLaunching and
    /// read from the main thread only (onAppear), both on the main actor.
    nonisolated(unsafe) private(set) static var launchedAsLoginItem = false

    /// A tray-resident app auto-launched at login must not open its main
    /// window: it lands in the user's face mid-login and invites the
    /// reflexive Cmd+Q that takes the DNS server down with it. Close, not
    /// prevent: the NSWindow survives close (ordered out), so every existing
    /// reopen path — popover "Open LocalDNS", Dock reopen, duplicate-instance
    /// notification — keeps working.
    static func closeMainWindowIfPresent() {
        NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("main") == true || $0.title == "LocalDNS"
        })?.close()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
                .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if Self.launchedAsLoginItem {
            // The SwiftUI scene may not have presented yet; ContentView's
            // onAppear (below, in LocalDNSApp) closes the late-created one.
            Self.closeMainWindowIfPresent()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Self.showWindowNote, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { LocalDNSAppDelegate.showMainWindow() }
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

    /// Tray-resident app: closing the window must never quit. Without this,
    /// SwiftUI treats the sole Window scene closing as "app is done" (the old
    /// MenuBarExtra scene used to keep it alive as a side effect) — and the
    /// DNS server silently died with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LocalDNSAppDelegate.showMainWindow()
        return false
    }

    /// Brings the main window back reliably. The SwiftUI Window scene's
    /// NSWindow survives close (ordered out, not destroyed), and the pure
    /// SwiftUI path (notification → openWindow) proved a no-op from that
    /// state — so raise the window directly; the notification is the
    /// fallback for the window-never-created case.
    static func showMainWindow() {
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("main") == true || $0.title == "LocalDNS"
        }) {
            // The window may live on another Space; an accessory app can't
            // switch Spaces, so bring the window to the user instead. And
            // order it front regardless — macOS's cooperative activation can
            // deny focus to a background app, which must not leave the window
            // buried.
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            NotificationCenter.default.post(name: .localDNSOpenMainWindow, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
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

    init() {
        // Single-instance guard, in App.init so it runs before scene building
        // and window restoration. Detection is a kernel flock, not
        // NSRunningApplication: the LS-based query proved unreliable this
        // early in launch, while a lock held by a live process and released
        // by the kernel on ANY death (including SIGKILL) has no stale states
        // by construction. The fd is held for the app's lifetime.
        // exit(), never terminate(): a duplicate must not run the
        // unregister-on-quit cleanup against the primary.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalDNS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.appendingPathComponent(".app.lock").path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // A live primary holds the lock: ask it to show its window, vanish.
            DistributedNotificationCenter.default()
                .post(name: LocalDNSAppDelegate.showWindowNote, object: nil)
            exit(0)
        }
    }

    /// One-shot: the login-launch window suppression must not re-close the
    /// window when the user later reopens it themselves.
    private static var loginWindowSuppressed = false

    var body: some Scene {
        Window("LocalDNS", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 840, minHeight: 560)
                .onAppear {
                    // SwiftUI presents this scene after the delegate has read
                    // the launch event; at login the window must not stay up.
                    if LocalDNSAppDelegate.launchedAsLoginItem, !Self.loginWindowSuppressed {
                        Self.loginWindowSuppressed = true
                        LocalDNSAppDelegate.closeMainWindowIfPresent()
                    }
                }
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
    private var screenObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var lastIconWanted: Bool?
    private var verifyGeneration = 0
    private static let positionKey = "NSStatusItem Preferred Position LocalDNSOrb"

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
        // The Settings toggle writes straight to UserDefaults. React only to
        // actual changes of our key: isVisible writes and autosave-position
        // churn also fire this notification, and re-entering syncInsertion on
        // our own writes would loop.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.iconWanted != self.lastIconWanted else { return }
                self.syncInsertion()
            }
        }
        // Screen layout changes can free (or eat) menu bar space — re-evaluate.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.ensureOnScreen() }
        }
        // The button window's occlusion flips when a manager shows/hides the
        // item — keep the Dock-icon fallback truthful without polling.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil
        ) { [weak self] note in
            let noteWindow = (note.object as? NSWindow).map(ObjectIdentifier.init)
            DispatchQueue.main.async {
                guard let self, let noteWindow,
                      let current = self.statusItem?.button?.window,
                      ObjectIdentifier(current) == noteWindow else { return }
                self.ensureOnScreen()
            }
        }

        syncInsertion()
    }

    private var iconWanted: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    private func syncInsertion() {
        lastIconWanted = iconWanted
        if iconWanted {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.autosaveName = "LocalDNSOrb"
                item.button?.target = self
                item.button?.action = #selector(togglePopover)
                statusItem = item
                currentSymbol = nil
            }
            // isVisible, not remove/recreate: recreation restores the autosave
            // position, and on a crowded bar a stale slot can land where macOS
            // simply doesn't render the item — "enabled but no icon".
            statusItem?.isVisible = true
            updateIcon()
            DispatchQueue.main.async { [weak self] in self?.ensureOnScreen() }
        } else if let item = statusItem {
            popover.performClose(nil)
            item.isVisible = false
        }
    }

    /// Bundle ids of menu-bar managers. While one is running IT owns item
    /// placement: a parked item is normal there, and any "repair" from our
    /// side (position clearing, isVisible flips) makes the manager lose track
    /// of the item — the icon then never lands even when whitelisted.
    private static let managerBundleIDs = [
        "com.surteesstudios.Bartender-setapp",
        "com.surteesstudios.Bartender",
        "com.jordanbaird.Ice",
        "com.toggleable.Dozer",
    ]

    private var managerRunning: Bool {
        Self.managerBundleIDs.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    /// A visible item can still be unrendered: a stale autosave position, a
    /// manager parking it, or a menu bar that is simply out of space. Without
    /// a manager, try to re-enter at the default slot. With one, never touch
    /// the item — just keep the Dock icon up while it isn't on glass. Either
    /// way the app stays reachable.
    private func ensureOnScreen() {
        guard let item = statusItem, item.isVisible else { return }
        if itemRendered(item) {
            adoptPolicy(.accessory)
            return
        }
        if !managerRunning, UserDefaults.standard.object(forKey: Self.positionKey) != nil {
            UserDefaults.standard.removeObject(forKey: Self.positionKey)
            item.isVisible = false
            item.isVisible = true
        }
        verifyGeneration += 1
        verifyLater(generation: verifyGeneration)
    }

    /// Settle the Dock-icon fallback after the bar stops moving: adopt the
    /// policy matching reality, and while the item is still parked keep one
    /// re-check armed (managers can take seconds to place an item — a check
    /// that lands mid-takeover must not freeze a stale Dock icon in place).
    private func verifyLater(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, generation == self.verifyGeneration,
                  let item = self.statusItem, item.isVisible else { return }
            if self.itemRendered(item) {
                self.adoptPolicy(.accessory)
            } else {
                self.adoptPolicy(.regular)
                self.verifyLater(generation: generation)
            }
        }
    }

    /// "Rendered" = actually on glass. The button window's frame alone lies —
    /// it can report a stale on-screen rect while the bar parks the item
    /// offscreen — so require the occlusion signal too. EXCEPT under a
    /// menu-bar manager: overlay-style managers keep the real window occluded
    /// even while displaying the item, and their parking position (negative x
    /// when hidden, a real slot when shown) is the honest signal there.
    private func itemRendered(_ item: NSStatusItem) -> Bool {
        guard let window = item.button?.window else { return false }
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        if managerRunning { return onScreen }
        return onScreen && window.occlusionState.contains(.visible)
    }

    private func adoptPolicy(_ policy: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
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

            if let newer = appState.availableUpdate {
                Divider()
                Button {
                    NSWorkspace.shared.open(UpdateChecker.releasesPage)
                } label: {
                    Label("Update to LocalDNS \(newer)", systemImage: "arrow.down.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                Button("Open LocalDNS") {
                    LocalDNSAppDelegate.showMainWindow()
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
