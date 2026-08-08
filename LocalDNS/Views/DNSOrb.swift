import SwiftUI

/// The one signature moment: a small status orb — concentric soft rings plus a
/// radial-glow core, in a single hue per state.
/// teal = serving & zones registered · amber = running but attention needed ·
/// gray = stopped. Slow 4-second breathing pulse, Reduce-Motion aware.
struct DNSOrb: View {
    enum State: Equatable {
        case live       // serving, everything registered
        case attention  // running, zones pending / conflict
        case stopped    // server off
    }

    let state: State
    var size: CGFloat = 28

    @SwiftUI.State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: State, size: CGFloat = 28) {
        self.state = state
        self.size = size
    }

    private var color: Color {
        switch state {
        case .live: return Theme.serving
        case .attention: return Theme.attention
        case .stopped: return .gray
        }
    }

    private var animates: Bool { state != .stopped && !reduceMotion }

    var body: some View {
        ZStack {
            Circle() // outer ring
                .stroke(color.opacity(0.20), lineWidth: size * 0.045)
            Circle() // middle ring
                .stroke(color.opacity(0.38), lineWidth: size * 0.045)
                .padding(size * 0.13)
            Circle() // glowing core
                .fill(RadialGradient(
                    colors: [Color.white.opacity(state == .stopped ? 0.4 : 0.95), color],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: size * 0.40))
                .padding(size * 0.25)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(glowOpacity), radius: size * 0.16)
        .scaleEffect(animates && pulsing ? 1.05 : 1.0)
        .opacity(state == .stopped ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.5), value: state)
        .onAppear {
            guard animates else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    private var glowOpacity: Double {
        switch state {
        case .stopped: return 0.08
        default: return pulsing ? 0.55 : 0.30
        }
    }
}
