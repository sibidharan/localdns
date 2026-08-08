import SwiftUI

/// The floating functional layer above every section: orb, wordmark + one-line
/// status, master switch, and the current section's actions.
///
/// The bar is owned by ContentView and persists across section switches — only
/// the `actions` slot swaps (the primary pill morphs via the shared
/// `glassEffectID` "section-primary"). This is what keeps the orb's breathing
/// animation and the glass shell from re-animating on every tab change.
///
/// macOS 26: presented as a `.safeAreaBar`, so section content scrolls *beneath*
/// it and the glass actually refracts something; a soft top scroll-edge effect
/// keeps text legible. macOS 14–25: the same bar pinned above a Divider.
struct PersistentActionBar<Actions: View>: View {
    @EnvironmentObject var appState: AppState
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Button {
                appState.runSelfTest()
            } label: {
                DNSOrb(state: appState.orbState, size: 22)
                    .padding(3)
            }
            .buttonStyle(.plain)
            .interactiveGlassCircle()
            .help("Run self-test")

            VStack(alignment: .leading, spacing: 1) {
                Text("LocalDNS")
                    .font(Theme.heading(.headline))
                Text(appState.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Toggle("Server", isOn: Binding(
                    get: { appState.serverEnabled },
                    set: { appState.serverEnabled = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                actions()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .glassBarShell()
        .padding(.horizontal, 10)
    }
}

// MARK: - Shared orb/status derivation

extension AppState {
    /// teal = serving & settled · amber = running but work pending · gray = stopped
    var orbState: DNSOrb.State {
        guard server.isRunning else { return .stopped }
        let settled = resolverPlan.installs.isEmpty
            && resolverPlan.conflicts.isEmpty
            && desiredZones.isSubset(of: registeredZones)
        return settled ? .live : .attention
    }

    /// One line, e.g. "2 of 3 zones · port 15353".
    var statusLine: String {
        guard server.isRunning else { return "Server stopped" }
        let total = desiredZones.count
        if total == 0 {
            return "No rules yet · port \(port)"
        }
        let ok = desiredZones.intersection(registeredZones).count
        return "\(ok) of \(total) zones · port \(port)"
    }
}
