import SwiftUI

/// The five sections of the app.
enum AppSection: String, CaseIterable, Identifiable {
    case rules, `import`, setup, diagnostics, settings

    var id: AppSection { self }

    var title: String {
        switch self {
        case .rules: return "Rules"
        case .import: return "Import"
        case .setup: return "Setup"
        case .diagnostics: return "Diagnostics"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .rules: return "list.bullet"
        case .import: return "square.and.arrow.down"
        case .setup: return "checkmark.shield"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gear"
        }
    }
}

/// Window root: sidebar navigation plus a detail column on the standard window
/// background. The action bar is hoisted here so it PERSISTS across section
/// switches — only the content below it transitions (`.id(section)`), so the
/// orb and glass shell never re-animate on tab changes. Per-section actions
/// live in the window titlebar (Helm-style uniform icon buttons).
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var section: AppSection? = .rules

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { section in
                Label(section.title, systemImage: section.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 230)
        } detail: {
            detailColumn
                .background { TopologyBackdrop() }
        }
        // Helm-style: per-section actions live in the WINDOW titlebar, trailing
        // edge. The toolbar must hang off the split view (window scope) — when
        // attached to the detail column it renders leading, next to the
        // sidebar toggle (verified by screenshot).
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                sectionActions
            }
        }
        // Relaunched while already running (Spotlight/Finder) — reopen the
        // window. This is the only way back in when the menu-bar icon is hidden.
        .onReceive(NotificationCenter.default.publisher(for: .localDNSOpenMainWindow)) { _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var detailColumn: some View {
        Group {
            if #available(macOS 26.0, *) {
                sectionContent
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .safeAreaBar(edge: .top, spacing: 0) {
                        PersistentActionBar()
                    }
            } else {
                VStack(spacing: 0) {
                    PersistentActionBar()
                    Divider()
                    sectionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The swapping part: only this view carries `.id(section)`, so only it
    /// re-renders with the opacity transition when the section changes.
    @ViewBuilder
    private var sectionContent: some View {
        Group {
            switch section ?? .rules {
            case .rules: RulesView()
            case .import: ImportHostsView()
            case .setup: SetupView()
            case .diagnostics: DiagnosticsView()
            case .settings: SettingsView()
            }
        }
        .id(section)
        .transition(.opacity)
        .animation(.spring(duration: 0.3), value: section)
    }

    /// Titlebar action cluster for the current section — uniform icon buttons,
    /// Helm-style, so the cluster never changes shape between sections. Each
    /// button keeps a full title (used for accessibility + tooltip) while only
    /// the icon shows, per Apple's Liquid Glass toolbar guidance.
    @ViewBuilder
    private var sectionActions: some View {
        switch section ?? .rules {
        case .rules:
            Button("Add Rule", systemImage: "plus") { appState.showingNewRuleSheet = true }
                .labelStyle(.iconOnly)
        case .import:
            if appState.importSuggestions != nil, !appState.addableImportSuggestions.isEmpty {
                Button("Add All Suggestions", systemImage: "plus.square.on.square") {
                    appState.addAllSuggestedRules()
                }
                .labelStyle(.iconOnly)
            }
            Button("Scan /etc/hosts", systemImage: "doc.text.magnifyingglass") { appState.scanHosts() }
                .labelStyle(.iconOnly)
        case .setup:
            if !appState.resolverAccessGranted {
                Button("Grant Access…", systemImage: "folder.badge.plus") {
                    appState.grantPanelRequestID = UUID()
                }
                .labelStyle(.iconOnly)
            } else if !appState.resolverAccessWritable {
                Button("Re-check Access", systemImage: "arrow.clockwise") { appState.recheckResolverAccess() }
                    .labelStyle(.iconOnly)
            } else {
                Button("Re-sync Now", systemImage: "arrow.triangle.2.circlepath") { appState.syncResolver() }
                    .labelStyle(.iconOnly)
                    .disabled(appState.resolverPlan.isNoop)
            }
        case .diagnostics:
            Button("Clear Log", systemImage: "trash") { appState.clearLog() }
                .labelStyle(.iconOnly)
                .disabled(appState.queryEntries.isEmpty)
        case .settings:
            EmptyView()
        }
    }
}
