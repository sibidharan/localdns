import SwiftUI

/// The Helm bridge: suggested wildcard rules from /etc/hosts, on standard
/// grouped rows. Glass appears only in the action bar buttons.
struct ImportHostsView: View {
    let barNamespace: Namespace.ID

    @EnvironmentObject var appState: AppState
    @State private var suggestions: [SuggestedRule]?
    @State private var uncoveredNames: [String] = []
    /// Keys ("pattern|ip") of suggestions added since the last scan.
    @State private var addedKeys: Set<String> = []

    var body: some View {
        SectionScaffold(namespace: barNamespace) {
            if suggestions != nil, !addableSuggestions.isEmpty {
                Button("Add All") { addAll() }
                    .glassButton()
            }
            Button("Scan /etc/hosts", systemImage: "doc.text.magnifyingglass") { scan() }
                .glassProminentButton()
                .primaryGlassID(barNamespace)
        } content: {
            Form {
                Section {
                    Text("LocalDNS never modifies /etc/hosts — Helm can keep managing it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let suggestions {
                    if suggestions.isEmpty && uncoveredNames.isEmpty {
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
                        if !uncoveredNames.isEmpty {
                            Section {
                                DisclosureGroup("Not covered by any rule (\(uncoveredNames.count))") {
                                    ForEach(uncoveredNames, id: \.self) { name in
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
        switch status(for: suggestion) {
        case .addable:
            Button("Add") { add(suggestion) }
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

    private var addableSuggestions: [SuggestedRule] {
        (suggestions ?? []).filter { status(for: $0) == .addable }
    }

    private enum SuggestionStatus {
        case addable, added, alreadyExists
    }

    private func key(for suggestion: SuggestedRule) -> String {
        "\(suggestion.pattern)|\(suggestion.ip)"
    }

    private func status(for suggestion: SuggestedRule) -> SuggestionStatus {
        if addedKeys.contains(key(for: suggestion)) { return .added }
        let pattern = DNSRule.normalize(suggestion.pattern)
        if appState.rules.contains(where: { $0.normalizedPattern == pattern }) {
            return .alreadyExists
        }
        return .addable
    }

    // MARK: Actions

    private func scan() {
        let entries = HostsImporter.loadSystemHosts()
        suggestions = HostsImporter.suggestions(entries: entries)
        uncoveredNames = HostsImporter.uncovered(entries: entries, rules: appState.rules)
        addedKeys = []
    }

    private func add(_ suggestion: SuggestedRule) {
        appState.addRule(suggestion.rule)
        addedKeys.insert(key(for: suggestion))
        rescanUncovered()
    }

    private func addAll() {
        let batch = addableSuggestions
        appState.addRules(batch.map(\.rule))
        addedKeys.formUnion(batch.map(key(for:)))
        rescanUncovered()
    }

    private func rescanUncovered() {
        let entries = HostsImporter.loadSystemHosts()
        uncoveredNames = HostsImporter.uncovered(entries: entries, rules: appState.rules)
    }
}
