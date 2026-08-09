import SwiftUI

/// Settings: standard grouped form. No custom surfaces.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var portDraft = ""

    var body: some View {
        Form {
                Section("Server") {
                    LabeledContent("Port") {
                        HStack {
                            TextField("15353", text: $portDraft)
                                .font(Theme.domain(.callout))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(applyPort)
                            Button("Apply", action: applyPort)
                                .controlSize(.small)
                                .disabled(!portDraftValid || Int(portDraft) == appState.port)
                        }
                    }
                    if !portDraft.isEmpty && !portDraftValid {
                        Text("Enter a port between 1024 and 65535.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("Changing the port restarts the server. If folder access is granted, zones re-sync automatically (the /etc/resolver files reference the port).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("System") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { appState.launchAtLogin },
                        set: { appState.launchAtLogin = $0 }))
                    if let error = appState.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Toggle("Show LocalDNS in the menu bar", isOn: $showMenuBarIcon)
                    if !showMenuBarIcon {
                        Label("Hidden from the menu bar, LocalDNS keeps running in the background. Reopen it from Spotlight or Finder to get back to this window.",
                              systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(Theme.attention)
                    }
                    Toggle("Remove /etc/resolver entries when quitting", isOn: Binding(
                        get: { appState.unregisterOnQuit },
                        set: { appState.unregisterOnQuit = $0 }))
                    Text("When enabled, quitting LocalDNS removes the zone files it created (uses the granted folder access).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        .onAppear { portDraft = String(appState.port) }
    }

    private var portDraftValid: Bool {
        guard let value = Int(portDraft) else { return false }
        return (1024 ... 65535).contains(value)
    }

    private func applyPort() {
        guard portDraftValid, let value = Int(portDraft), value != appState.port else { return }
        appState.port = value
    }
}
