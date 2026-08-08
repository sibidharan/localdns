import SwiftUI

/// The one signature moment: a small status orb — concentric soft rings plus a
/// radial-glow core, in a single hue per state.
/// teal = serving & zones registered · amber = running but attention needed ·
/// gray = stopped. Slow 4-second breathing pulse, Reduce-Motion aware.
///
/// Energy discipline: the pulse is a perpetual SwiftUI animation, which drives
/// display-list updates every frame (~25% CPU on a ProMotion display — measured).
/// So it runs ONLY while the hosting window is key, and stops on disappear or
/// focus loss; a static orb renders everywhere else.
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
    @Environment(\.controlActiveState) private var controlActiveState

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

    /// Breathe only when animated, motion-safe, and the window is key.
    private var animates: Bool {
        state != .stopped && !reduceMotion && controlActiveState == .key
    }

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
        .onAppear { updateAnimation() }
        .onDisappear { stopAnimation() }
        .onChange(of: controlActiveState) { _, _ in updateAnimation() }
        .onChange(of: state) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private var glowOpacity: Double {
        switch state {
        case .stopped: return 0.08
        default: return pulsing && animates ? 0.55 : 0.30
        }
    }

    private func updateAnimation() {
        if animates {
            guard !pulsing else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        } else {
            stopAnimation()
        }
    }

    /// Stopping the perpetual animation lets SwiftUI drop the display link.
    private func stopAnimation() {
        guard pulsing else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pulsing = false }
    }
}
