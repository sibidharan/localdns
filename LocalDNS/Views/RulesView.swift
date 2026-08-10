import SwiftUI

/// Rules as clean grouped rows on the standard background (System Settings
/// idiom): small toggle, outline wildcard badge + monospaced pattern, IPs as
/// plain mono text with tiny colored dots, quiet Edit, context-menu delete.
struct RulesView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingRule: DNSRule?
    @State private var rulePendingDeletion: DNSRule?
    @State private var hoveredRule: DNSRule.ID?

    private var groupedRules: [(group: String, rules: [DNSRule])] {
        Dictionary(grouping: appState.rules, by: \.group)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value.sorted { $0.normalizedPattern < $1.normalizedPattern }) }
    }

    var body: some View {
        Group {
            if appState.rules.isEmpty {
                emptyState
            } else {
                Form {
                    ForEach(groupedRules, id: \.group) { section in
                        Section {
                            ForEach(Array(section.rules.enumerated()), id: \.element.id) { index, rule in
                                // The separator is an overlay, not a sibling:
                                // in a grouped Form a bare Divider becomes its
                                // own full-height row — a big empty gap with a
                                // hairline lost in it.
                                ruleRow(rule)
                                    .overlay(alignment: .top) {
                                        if index > 0 {
                                            Divider().padding(.leading, 38)
                                        }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(section.group)
                                Spacer()
                                Text("All")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle("Enable all in \(section.group)", isOn: groupBinding(section.group))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.showingNewRuleSheet },
            set: { appState.showingNewRuleSheet = $0 })) {
            RuleEditSheet()
        }
        .sheet(item: Binding(
            get: { appState.debugNewRuleSheet },
            set: { appState.debugNewRuleSheet = $0 })) { seed in
            RuleEditSheet(debugSeed: seed)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditSheet(existing: rule)
        }
        .alert("Delete Rule", isPresented: deletionAlertPresented, presenting: rulePendingDeletion) { rule in
            Button("Delete", role: .destructive) {
                appState.deleteRule(id: rule.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("Delete \(rule.pattern)? This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            DNSOrb(state: .stopped, size: 44)
            Text("No rules yet")
                .font(Theme.heading(.title3))
            Text("Add your first wildcard rule, e.g. *.myapp.test → 127.0.0.1")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Rule") { appState.showingNewRuleSheet = true }
                .glassProminentButton()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ruleRow(_ rule: DNSRule) -> some View {
        HStack(spacing: 12) {
            Toggle("Enabled", isOn: enabledBinding(for: rule))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack(spacing: 6) {
                if rule.isWildcard {
                    WildcardBadge()
                }
                Text(displayPattern(rule))
                    .font(Theme.domain(.body))
            }

            Spacer()

            HStack(spacing: 14) {
                if let ipv4 = rule.ipv4 {
                    AddressText(address: ipv4)
                }
                if let ipv6 = rule.ipv6 {
                    AddressText(address: ipv6)
                }
                Text("TTL \(rule.ttl)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Edit") { editingRule = rule }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(rule.enabled ? 1 : 0.5)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hoveredRule == rule.id ? 0.06 : 0)))
        .onHover { hovering in
            hoveredRule = hovering ? rule.id : nil
        }
        .contextMenu {
            Button("Edit") { editingRule = rule }
            Divider()
            Button("Delete", role: .destructive) { rulePendingDeletion = rule }
        }
    }

    /// Pattern with the wildcard prefix removed (the badge carries it).
    private func displayPattern(_ rule: DNSRule) -> String {
        rule.isWildcard ? String(rule.normalizedPattern.dropFirst(2)) : rule.pattern
    }

    private func enabledBinding(for rule: DNSRule) -> Binding<Bool> {
        Binding(
            get: { appState.rules.first { $0.id == rule.id }?.enabled ?? rule.enabled },
            set: { appState.setEnabled($0, for: rule.id) })
    }

    private func groupBinding(_ group: String) -> Binding<Bool> {
        Binding(
            get: { appState.rules.filter { $0.group == group }.allSatisfy(\.enabled) },
            set: { appState.setGroup(group, enabled: $0) })
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(get: { rulePendingDeletion != nil },
                set: { if !$0 { rulePendingDeletion = nil } })
    }
}
