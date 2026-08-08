import SwiftUI

/// Restrained palette + typography.
/// Rules of the house (per Apple's Liquid Glass guidance):
/// - window/content surfaces use the standard system background — no custom fills
/// - color appears only on the primary action and tiny status dots
/// - SF Mono only for domains, IPs, and shell commands; rounded for headings
enum Theme {
    /// Tiny IPv4 dot.
    static let v4Dot = Color(red: 0.25, green: 0.65, blue: 0.95)
    /// Tiny IPv6 dot.
    static let v6Dot = Color(red: 0.62, green: 0.45, blue: 0.95)
    /// Amber for "needs attention" (unregistered zones, conflicts).
    static let attention = Color.orange
    /// Teal for "serving".
    static let serving = Color(red: 0.16, green: 0.72, blue: 0.78)

    /// SF Mono for domains/IPs/commands.
    static func domain(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// Rounded SF for headings.
    static func heading(_ style: Font.TextStyle = .headline, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}
