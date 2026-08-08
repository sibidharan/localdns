import SwiftUI

/// All Liquid Glass availability gating lives here. Liquid Glass is the
/// *functional* layer only: the floating action bar's controls and the orb.
/// On macOS 14–25 these fall back to plain system styles — no fake glass.
extension View {

    /// Primary action: `.glassProminent` on 26+, `.borderedProminent` before.
    /// Inside a glass shell (bar), demotes to `.borderedProminent` — nested
    /// glass is an HIG violation.
    @ViewBuilder
    func glassProminentButton() -> some View {
        modifier(GlassButtonModifier(prominent: true))
    }

    /// Secondary action: `.glass` on 26+, `.bordered` before; borderless inside
    /// a glass shell.
    @ViewBuilder
    func glassButton() -> some View {
        modifier(GlassButtonModifier(prominent: false))
    }

    /// A real glass disc with press/hover physics (for the orb button).
    /// Identity on older systems — and inside a glass shell (no nesting).
    @ViewBuilder
    func interactiveGlassCircle() -> some View {
        modifier(InteractiveGlassCircleModifier())
    }

    /// Tags the section's primary glass action for morphing inside the shared
    /// GlassEffectContainer (26+; no-op before). All primary actions share one
    /// ID, so switching sections or states morphs the pill.
    @ViewBuilder
    func primaryGlassID(_ namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectID("section-primary", in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Glass shell context

/// Set on the action bar's glass shell; controls inside read it to demote
/// themselves to non-glass styles (nested glass effects violate the HIG).
private struct InGlassShellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var inGlassShell: Bool {
        get { self[InGlassShellKey.self] }
        set { self[InGlassShellKey.self] = newValue }
    }
}

extension View {
    /// Marks the whole floating bar as one glass element on macOS 26:
    /// a frosted rounded shell behind orb + title + controls. Identity pre-26.
    @ViewBuilder
    func glassBarShell(cornerRadius: CGFloat = 22) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .environment(\.inGlassShell, true)
        } else {
            self
        }
    }
}

private struct GlassButtonModifier: ViewModifier {
    @Environment(\.inGlassShell) private var inShell
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if inShell {
                if prominent {
                    content.buttonStyle(.borderedProminent)
                } else {
                    content.buttonStyle(.borderless)
                }
            } else if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

private struct InteractiveGlassCircleModifier: ViewModifier {
    @Environment(\.inGlassShell) private var inShell

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !inShell {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
        }
    }
}

/// Outline-only wildcard badge (neutral, no fill).
struct WildcardBadge: View {
    var body: some View {
        Text("*.")
            .font(Theme.domain(.caption, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.secondary.opacity(0.45), lineWidth: 1))
    }
}

/// An IP address as plain mono text with a tiny colored dot (cyan = v4, violet = v6).
struct AddressText: View {
    let address: String

    private var dotColor: Color { address.contains(":") ? Theme.v6Dot : Theme.v4Dot }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(address)
                .font(Theme.domain(.caption))
                .foregroundStyle(.secondary)
        }
    }
}
