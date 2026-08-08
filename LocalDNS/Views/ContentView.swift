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
/// orb and glass shell never re-animate on tab changes. The per-section primary
/// action still morphs inside the shared GlassEffectContainer.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var section: AppSection? = .rules
    @Namespace private var barNamespace

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
    }

    private var detailColumn: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    sectionContent
                        .scrollEdgeEffectStyle(.soft, for: .top)
                        .safeAreaBar(edge: .top, spacing: 0) {
                            PersistentActionBar { sectionActions }
                        }
                }
            } else {
                VStack(spacing: 0) {
                    PersistentActionBar { sectionActions }
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

    /// The bar's action slot for the current section. Primary actions share one
    /// glassEffectID so switching sections morphs the pill in place.
    @ViewBuilder
    private var sectionActions: some View {
        switch section ?? .rules {
        case .rules:
            Button("Add Rule", systemImage: "plus") { appState.showingNewRuleSheet = true }
                .glassProminentButton()
                .primaryGlassID(barNamespace)
        case .import:
            if appState.importSuggestions != nil, !appState.addableImportSuggestions.isEmpty {
                Button("Add All") { appState.addAllSuggestedRules() }
                    .glassButton()
            }
            Button("Scan /etc/hosts", systemImage: "doc.text.magnifyingglass") { appState.scanHosts() }
                .glassProminentButton()
                .primaryGlassID(barNamespace)
        case .setup:
            if !appState.resolverAccessGranted {
                Button("Grant Access…", systemImage: "folder.badge.plus") {
                    appState.grantPanelRequestID = UUID()
                }
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
        case .diagnostics:
            Button("Clear Log", systemImage: "trash") { appState.clearLog() }
                .glassButton()
                .disabled(appState.queryEntries.isEmpty)
        case .settings:
            EmptyView()
        }
    }
}
