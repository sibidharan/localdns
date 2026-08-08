import Network
import SwiftUI

/// Debug/E2E launch-flag seeds for presenting the sheet non-interactively
/// (`-newRuleSheet`, `-newRuleSheetInvalid`, `-newRuleSheetValid`).
enum DebugNewRuleSeed: String, Identifiable {
    case empty, invalid, valid
    var id: String { rawValue }
}

/// Add/edit sheet for a single rule.
///
/// Discipline:
/// - Placeholders are short enough to never wrap; explanations live in captions.
/// - No validation text on first presentation: a field's error appears only
///   after the field was committed (Return / focus loss) with invalid content.
///   The save button derives from `isValid` and stays disabled until then.
/// - A live match preview, driven by the real `DNSRule.matches` logic, shows
///   exactly what the rule will do while the user types.
struct RuleEditSheet: View {
    let existing: DNSRule?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case pattern, ipv4, ipv6, ttl, group }

    @State private var pattern: String
    @State private var ipv4: String
    @State private var ipv6: String
    @State private var ttl: String
    @State private var group: String
    /// Fields committed (Return / focus loss); only these may show errors.
    @State private var committed: Set<Field>
    @FocusState private var focusedField: Field?

    init(existing: DNSRule? = nil, debugSeed: DebugNewRuleSeed? = nil) {
        self.existing = existing
        var pattern = existing?.pattern ?? ""
        var ipv4 = existing?.ipv4 ?? ""
        let ipv6 = existing?.ipv6 ?? ""
        var committed: Set<Field> = []
        switch debugSeed {
        case .invalid:
            pattern = "bad pattern" // space → invalid syntax
            committed = [.pattern]
        case .valid:
            pattern = "*.demo.test"
            ipv4 = "172.30.0.9"
        default:
            break
        }
        _pattern = State(initialValue: pattern)
        _ipv4 = State(initialValue: ipv4)
        _ipv6 = State(initialValue: ipv6)
        _ttl = State(initialValue: existing.map { String($0.ttl) } ?? "60")
        _group = State(initialValue: existing?.group ?? "Default")
        _committed = State(initialValue: committed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            patternSection
            addressesSection
            detailsRow
            previewCard
            buttons
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: focusedField) { previous, _ in
            if let previous { committed.insert(previous) }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            if existing == nil {
                WildcardBadge()
            }
            Text(existing == nil ? "New Rule" : "Edit Rule")
                .font(Theme.heading(.title2))
            Spacer()
        }
    }

    private var patternSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pattern")
                .font(.callout.weight(.medium))
            TextField("*.myapp.test", text: $pattern)
                .font(Theme.domain(.body))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .pattern)
                .onSubmit { committed.insert(.pattern) }
            Text("“*.example.test” matches the apex and every subdomain; “host.test” is exact.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if showsError(for: .pattern), let patternError {
                errorText(patternError)
            } else if patternError == nil, RuleValidation.usesLocalTLD(pattern) {
                Label("“.local” is used by Bonjour/mDNS — wildcarding it can interfere with printers, AirPlay, and other network services.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
    }

    private var addressesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("IPv4") {
                TextField("172.30.0.3", text: $ipv4)
                    .font(Theme.domain(.callout))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .ipv4)
                    .onSubmit { committed.insert(.ipv4) }
            }
            if showsError(for: .ipv4) {
                errorText("Not a valid IPv4 address.")
            }
            LabeledContent("IPv6") {
                TextField("fd00::3", text: $ipv6)
                    .font(Theme.domain(.callout))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .ipv6)
                    .onSubmit { committed.insert(.ipv6) }
            }
            if showsError(for: .ipv6) {
                errorText("Not a valid IPv6 address.")
            }
            if showsAddressRequired {
                errorText("At least one of IPv4 / IPv6 is required.")
            }
            Text("IPv6 is optional; either or both work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detailsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                LabeledContent("TTL") {
                    HStack(spacing: 4) {
                        TextField("60", text: $ttl)
                            .font(Theme.domain(.callout))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .focused($focusedField, equals: .ttl)
                            .onSubmit { committed.insert(.ttl) }
                        Text("sec")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Group") {
                    TextField("Default", text: $group)
                        .font(Theme.domain(.callout))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .group)
                }
            }
            if showsError(for: .ttl), let ttlError {
                errorText(ttlError)
            }
        }
    }

    /// The signature touch: what this rule will answer, computed with the real
    /// matcher. Wildcards preview the apex and a sample subdomain.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rule = draftRule {
                ForEach(previewNames(for: rule), id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.serving)
                        Text(name)
                            .font(Theme.domain(.callout))
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let ipv4 = rule.ipv4 {
                            AddressText(address: ipv4)
                        }
                        if let ipv6 = rule.ipv6 {
                            AddressText(address: ipv6)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Type a valid pattern and at least one address to preview the match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .glassButton()
            Button(existing == nil ? "Add Rule" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .glassProminentButton()
                .disabled(!isValid)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }

    // MARK: Validation (errors surface only for committed fields)

    private func showsError(for field: Field) -> Bool {
        guard committed.contains(field) else { return false }
        switch field {
        case .pattern: return !pattern.isEmpty && patternError != nil
        case .ipv4: return !ipv4.isEmpty && !ipv4Valid
        case .ipv6: return !ipv6.isEmpty && !ipv6Valid
        case .ttl: return ttlError != nil
        case .group: return false
        }
    }

    /// The "at least one address" error appears only once the user has
    /// committed either address field — never on first presentation.
    private var showsAddressRequired: Bool {
        ipv4.isEmpty && ipv6.isEmpty && !committed.isDisjoint(with: [.ipv4, .ipv6])
    }

    private var patternError: String? { Self.patternError(for: pattern) }
    private var ipv4Valid: Bool { IPv4Address(ipv4.trimmed) != nil }
    private var ipv6Valid: Bool { IPv6Address(ipv6.trimmed) != nil }
    private var ttlValue: UInt32? { UInt32(ttl.trimmed) }
    private var ttlError: String? {
        ttlValue == nil ? "TTL must be a number." : (ttlValue! == 0 ? "TTL must be greater than 0." : nil)
    }

    private var isValid: Bool {
        patternError == nil
            && (ipv4.isEmpty || ipv4Valid)
            && (ipv6.isEmpty || ipv6Valid)
            && !(ipv4.isEmpty && ipv6.isEmpty)
            && ttlError == nil
    }

    /// Validates `*.something.tld` / `host.tld` patterns. Returns nil when valid.
    static func patternError(for pattern: String) -> String? {
        RuleValidation.patternError(for: pattern)
    }

    // MARK: Live preview

    /// The rule as currently typed, or nil while anything is invalid.
    private var draftRule: DNSRule? {
        let normalized = DNSRule.normalize(pattern.trimmed)
        guard !normalized.isEmpty, Self.patternError(for: normalized) == nil else { return nil }
        let v4 = ipv4.trimmed.nilIfEmpty
        let v6 = ipv6.trimmed.nilIfEmpty
        if let v4, IPv4Address(v4) == nil { return nil }
        if let v6, IPv6Address(v6) == nil { return nil }
        guard v4 != nil || v6 != nil else { return nil }
        return DNSRule(pattern: normalized, ipv4: v4, ipv6: v6)
    }

    /// Preview names verified through the REAL matching logic — preview == behavior.
    private func previewNames(for rule: DNSRule) -> [String] {
        let candidates: [String]
        if rule.isWildcard {
            let zone = String(rule.normalizedPattern.dropFirst(2))
            candidates = [zone, "foo.\(zone)"]
        } else {
            candidates = [rule.normalizedPattern]
        }
        return candidates.filter { rule.matches(name: $0) }
    }

    // MARK: Save

    private func save() {
        let rule = DNSRule(
            id: existing?.id ?? UUID(),
            pattern: DNSRule.normalize(pattern.trimmed),
            ipv4: ipv4.trimmed.nilIfEmpty,
            ipv6: ipv6.trimmed.nilIfEmpty,
            ttl: ttlValue ?? 60,
            enabled: existing?.enabled ?? true,
            group: group.trimmed.nilIfEmpty ?? "Default")
        if existing == nil {
            appState.addRule(rule)
        } else {
            appState.updateRule(rule)
        }
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
