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
/// background. On macOS 26 the whole detail sits in one GlassEffectContainer,
/// so the floating bars' primary glass actions morph into each other when the
/// section changes (they share a glassEffectID in `barNamespace`).
struct ContentView: View {
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
                    sectionViews
                }
            } else {
                sectionViews
            }
        }
    }

    @ViewBuilder
    private var sectionViews: some View {
        Group {
            switch section ?? .rules {
            case .rules: RulesView(barNamespace: barNamespace)
            case .import: ImportHostsView(barNamespace: barNamespace)
            case .setup: SetupView(barNamespace: barNamespace)
            case .diagnostics: DiagnosticsView(barNamespace: barNamespace)
            case .settings: SettingsView(barNamespace: barNamespace)
            }
        }
        .id(section)
        .transition(.opacity)
        .animation(.spring(duration: 0.3), value: section)
    }
}
