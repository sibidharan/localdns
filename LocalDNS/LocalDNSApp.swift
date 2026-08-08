import AppKit
import SwiftUI

@MainActor
@main
struct LocalDNSApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("LocalDNS", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 840, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)

        MenuBarExtra("LocalDNS", systemImage: menuBarSymbol) {
            MenuBarContentView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if !appState.server.isRunning {
            return "network.slash"
        }
        return appState.orbState == .live
            ? "dot.radiowaves.left.and.right"
            : "exclamationmark.circle"
    }
}

/// Compact menu-bar card on the standard popover material: orb + status,
/// master toggle, recent queries, Open / Quit. No custom fills.
private struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

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
                            Spacer()
                            Text(outcomeText(entry.outcome))
                                .font(Theme.domain(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Open LocalDNS") {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
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

    private func outcomeText(_ outcome: QueryLogEntry.Outcome) -> String {
        switch outcome {
        case .answered(let address): return address
        case .noData: return "no data"
        case .nxdomain: return "NXDOMAIN"
        }
    }
}
