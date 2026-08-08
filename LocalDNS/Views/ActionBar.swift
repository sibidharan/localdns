import SwiftUI

/// The floating functional layer above every section: orb, wordmark + one-line
/// status, master switch, and the section's actions.
///
/// macOS 26: the bar is a `.safeAreaBar`, so section content scrolls *beneath*
/// it and the glass controls actually refract something; a soft top scroll-edge
/// effect keeps the text legible. The controls live in one GlassEffectContainer
/// (hosted by ContentView) and each section's primary action carries the shared
/// `glassEffectID` "section-primary" — switching sections (or grant states)
/// morphs the glass pill, the signature Liquid Glass transition.
///
/// macOS 14–25: the same bar pinned above a Divider with plain system buttons.
struct SectionScaffold<Actions: View, Content: View>: View {
    /// Shared namespace owned by ContentView (must outlive section switches for
    /// the morph to work).
    let namespace: Namespace.ID

    @EnvironmentObject var appState: AppState
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            content()
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) {
                    bar
                }
        } else {
            VStack(spacing: 0) {
                bar
                Divider()
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Orb + wordmark + status + master switch + section actions, presented on
    /// macOS 26 as ONE frosted glass shell floating over the content (controls
    /// inside demote themselves to non-glass styles — no nested glass).
    private var bar: some View {
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
