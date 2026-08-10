import SwiftUI

/// The Helm bridge: suggested wildcard rules from /etc/hosts, on standard
/// grouped rows. Scan/add logic lives in AppState; the primary actions float
/// in the persistent action bar above.
struct ImportHostsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Text("LocalDNS never modifies /etc/hosts — it is only read for suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let suggestions = appState.importSuggestions {
                if suggestions.isEmpty && appState.importUncovered.isEmpty {
                    Section {
                        Text("No groups of 2+ hostnames sharing an address and parent domain were found.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !suggestions.isEmpty {
                        Section("Suggested wildcards") {
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                suggestionRow(suggestion)
                            }
                        }
                    }
                    if !appState.importUncovered.isEmpty {
                        Section {
                            DisclosureGroup("Not covered by any rule (\(appState.importUncovered.count))") {
                                ForEach(appState.importUncovered, id: \.self) { name in
                                    Text(name)
                                        .font(Theme.domain(.caption))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section {
                    Text("Scan /etc/hosts to see suggested wildcard rules.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func suggestionRow(_ suggestion: SuggestedRule) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(suggestion.coveredHostnames, id: \.self) { name in
                    Text(name)
                        .font(Theme.domain(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                WildcardBadge()
                Text(String(suggestion.pattern.dropFirst(2)))
                    .font(Theme.domain(.body))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                AddressText(address: suggestion.ip)
                Spacer()
                Text("\(suggestion.coveredHostnames.count) hosts → 1 rule")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                actionView(for: suggestion)
            }
        }
    }

    @ViewBuilder
    private func actionView(for suggestion: SuggestedRule) -> some View {
        switch appState.importSuggestionStatus(suggestion) {
        case .addable:
            Button("Add") { appState.addSuggestedRule(suggestion) }
                .controlSize(.small)
        case .added:
            Label("Added", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.green)
        case .alreadyExists:
            Text("Already in rules")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
