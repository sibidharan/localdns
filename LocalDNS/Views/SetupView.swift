import AppKit
import SwiftUI

/// Setup as numbered step rows with animated checkmarks, on the standard
/// grouped background. Grant mechanics (Terminal command, NSOpenPanel,
/// security-scoped bookmark) are unchanged; the primary action also lives in
/// the action bar.
struct SetupView: View {
    let barNamespace: Namespace.ID

    @EnvironmentObject var appState: AppState
    @State private var didCopyCommand = false

    var body: some View {
        SectionScaffold(namespace: barNamespace) {
            setupActions
        } content: {
            Form {
                statusSection

                if !appState.resolverAccessGranted {
                    stepSections
                } else if !appState.resolverAccessWritable {
                    notWritableSection
                } else {
                    zonesSection
                    manageSection
                }

                selfTestSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { appState.refreshResolverStatus() }
    }

    // MARK: Action bar

    @ViewBuilder
    private var setupActions: some View {
        // One shared ID: the primary action morphs through the grant flow's
        // states (Grant → Re-check → Re-sync) without leaving the glass.
        if !appState.resolverAccessGranted {
            Button("Grant Access…", systemImage: "folder.badge.plus") { presentGrantPanel() }
                .glassProminentButton()
                .primaryGlassID(barNamespace)
        } else if !appState.resolverAccessWritable {
            Button("Re-check Access", systemImage: "arrow.clockwise") { appState.recheckResolverAccess() }
                .glassProminentButton()
                .primaryGlassID(barNamespace)
        } else {
            Button("Re-sync Now", systemImage: "arrow.triangle.2.circlepath") { appState.syncResolver() }
                .glassProminentButton()
                .primaryGlassID(barNamespace)
                .disabled(appState.resolverPlan.isNoop)
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("DNS server") {
                statusText(appState.server.isRunning ? "Running on port \(appState.port)" : "Stopped",
                           color: appState.server.isRunning ? Theme.serving : .secondary)
            }
            LabeledContent("/etc/resolver access") {
                if appState.resolverAccessGranted {
                    statusText(appState.resolverAccessWritable ? "Granted" : "Granted — folder not writable yet",
                               color: appState.resolverAccessWritable ? Theme.serving : Theme.attention)
                } else {
                    statusText("Not granted", color: .secondary)
                }
            }
            if appState.resolverAccessGranted, appState.resolverAccessWritable {
                LabeledContent("Zones") {
                    statusText(zoneSummary,
                               color: pendingZones.isEmpty ? Theme.serving : Theme.attention)
                }
            }
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
    }

    // MARK: Steps (not granted)

    private var stepSections: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Creates /etc/resolver and grants your account permission to manage it. Your password is never seen by LocalDNS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ResolverAccess.terminalCommand)
                        .font(Theme.domain(.caption))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack {
                        Button(didCopyCommand ? "Copied" : "Copy Command",
                               systemImage: "doc.on.doc") { copyCommand() }
                        Button("Open Terminal", systemImage: "apple.terminal") { openTerminal() }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 6)
            } header: {
                stepHeader(number: 1, title: "One-time Terminal command",
                           done: appState.resolverAccessWritable)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick the /etc/resolver folder once. macOS then lets LocalDNS manage its own zone files there — no prompts afterwards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Select /etc/resolver Folder…") { presentGrantPanel() }
                        .controlSize(.small)
                }
                .padding(.vertical, 6)
            } header: {
                stepHeader(number: 2, title: "Grant LocalDNS access",
                           done: appState.resolverAccessGranted)
            }
        }
    }

    private func stepHeader(number: Int, title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Image(systemName: "\(number).circle")
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.3), value: done)
            Text(title)
        }
    }

    // MARK: Granted, ACL missing

    private var notWritableSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Access granted, but the folder isn't writable yet — run the Step 1 command, then re-check.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
                Text(ResolverAccess.terminalCommand)
                    .font(Theme.domain(.caption))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Button(didCopyCommand ? "Copied" : "Copy Command",
                           systemImage: "doc.on.doc") { copyCommand() }
                    Button("Re-check", systemImage: "arrow.clockwise") { appState.recheckResolverAccess() }
                    Spacer()
                    Button("Revoke Access") { appState.revokeResolverAccess() }
                        .foregroundStyle(.red)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Granted — zones

    private var zonesSection: some View {
        Section("Zones") {
            if appState.desiredZones.isEmpty {
                Text("No zones yet — add a rule first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.desiredZones.sorted(), id: \.self) { zone in
                    zoneRow(zone)
                }
            }
        }
    }

    private func zoneRow(_ zone: String) -> some View {
        HStack(spacing: 8) {
            if appState.resolverPlan.conflicts.contains(zone) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.attention)
            }
            Text(zone)
                .font(Theme.domain(.callout))
            Spacer()
            zoneStatus(zone)
        }
    }

    private func zoneStatus(_ zone: String) -> some View {
        if appState.resolverPlan.conflicts.contains(zone) {
            return statusText("Managed elsewhere — left untouched", color: Theme.attention)
        }
        if appState.registeredZones.contains(zone) {
            if appState.resolverPlan.installs.contains(zone) {
                return statusText("Needs re-sync", color: Theme.attention)
            }
            return statusText("Registered", color: Theme.serving)
        }
        return statusText("Not registered", color: Theme.attention)
    }

    private var manageSection: some View {
        Section {
            HStack {
                Button("Unregister All Zones") { appState.unregisterResolver() }
                    .disabled(appState.registeredZones.isEmpty)
                Spacer()
                Button("Revoke Access") { appState.revokeResolverAccess() }
                    .foregroundStyle(.red)
            }
            .controlSize(.small)
            if let outcome = appState.lastSyncOutcome {
                outcomeText(outcome)
            }
            Text("Zones stay in sync automatically when rules change. Only files created by LocalDNS are ever touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Self-test

    private var selfTestSection: some View {
        Section {
            HStack {
                Button("Run Self-Test") { appState.runSelfTest() }
                    .controlSize(.small)
                    .disabled(appState.isSelfTesting)
                if appState.isSelfTesting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
                Spacer()
            }
            if let result = appState.selfTestResult {
                Text(result.message)
                    .font(.callout)
                    .foregroundStyle(result.ok ? .green : .red)
            }
        } header: {
            Text("Self-test")
        } footer: {
            Text("Sends a real DNS query to 127.0.0.1:\(appState.port) for one of your rules and checks the answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private var pendingZones: [String] {
        appState.resolverPlan.installs + appState.resolverPlan.conflicts
    }

    private var zoneSummary: String {
        let total = appState.desiredZones.count
        let ok = appState.desiredZones.filter {
            appState.registeredZones.contains($0) && !appState.resolverPlan.installs.contains($0)
        }.count
        return "\(ok) of \(total) registered"
    }

    @ViewBuilder
    private func outcomeText(_ outcome: ResolverSyncOutcome) -> some View {
        switch outcome {
        case .applied(let conflicts):
            Text(conflicts.isEmpty
                 ? "Zones updated."
                 : "Zones updated; \(conflicts.count) conflict(s) left untouched.")
                .font(.callout)
                .foregroundStyle(.green)
        case .upToDate(let conflicts):
            Text(conflicts.isEmpty
                 ? "Already up to date."
                 : "Up to date; \(conflicts.count) conflict(s) left untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        case .accessDenied:
            Text("LocalDNS has no write access to /etc/resolver — complete the grant steps.")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ResolverAccess.terminalCommand, forType: .string)
        didCopyCommand = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyCommand = false
        }
    }

    private func openTerminal() {
        // Opens Terminal.app via LaunchServices — no Apple events involved.
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private func presentGrantPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ResolverSetup.resolverDirectory
        panel.message = "Select the /etc/resolver folder"
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.grantResolverAccess(to: url)
    }
}
