import SwiftUI

/// Live query log: monospaced rows with thin dividers on the standard
/// background; new rows slide in at the top. No panel fill, no clutter.
struct DiagnosticsView: View {
    let barNamespace: Namespace.ID

    @EnvironmentObject var appState: AppState

    var body: some View {
        SectionScaffold(namespace: barNamespace) {
            Button("Clear Log", systemImage: "trash") { appState.clearLog() }
                .glassButton()
                .disabled(appState.queryEntries.isEmpty)
        } content: {
            VStack(spacing: 0) {
                if let error = appState.server.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    Divider()
                }

                if appState.queryEntries.isEmpty {
                    VStack(spacing: 10) {
                        Text("No queries yet")
                            .font(Theme.heading(.title3))
                        Text("Try: dscacheutil -q host -a name myapp.test")
                            .font(Theme.domain(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(appState.queryEntries) { entry in
                                logRow(entry)
                                Divider()
                                    .padding(.leading, 20)
                            }
                        }
                        .animation(.spring(duration: 0.3, bounce: 0.15), value: appState.queryEntries)
                    }
                }
            }
        }
    }

    private func logRow(_ entry: QueryLogEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: glyph(for: entry.outcome))
                .font(.caption)
                .foregroundStyle(glyphColor(for: entry.outcome))
                .frame(width: 14)
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(Theme.domain(.caption))
                .foregroundStyle(.secondary)
            Text(entry.name)
                .font(Theme.domain(.callout))
                .lineLimit(1)
            Spacer()
            Text(entry.qtype)
                .font(Theme.domain(.caption))
                .foregroundStyle(.secondary)
            Text(outcomeText(entry.outcome))
                .font(Theme.domain(.caption, weight: .medium))
                .foregroundStyle(glyphColor(for: entry.outcome))
            Text(String(format: "%.1f ms", entry.latencyMs))
                .font(Theme.domain(.caption))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .transition(.move(edge: .top).combined(with: .opacity))
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
        case .answered(let address): return "→ \(address)"
        case .noData: return "no data"
        case .nxdomain: return "NXDOMAIN"
        }
    }
}
