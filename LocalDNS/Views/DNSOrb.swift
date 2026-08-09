import AppKit
import SwiftUI

/// The one signature moment: a small status orb — concentric soft rings plus a
/// radial-glow core, in a single hue per state.
/// teal = serving & zones registered · amber = running but attention needed ·
/// gray = stopped. Slow 4-second breathing pulse, Reduce-Motion aware.
///
/// Energy discipline: the breathing runs as a Core Animation on the render
/// server (via PulseContainer below) — NOT as a SwiftUI-state `repeatForever`
/// animation, which drove whole-tree display-list updates every frame (~25%
/// CPU on a ProMotion display, measured) and proved impossible to gate reliably
/// on window key state from inside safeAreaBar content. CA animations cost
/// ~0 main-thread CPU and the render server throttles them automatically for
/// occluded/hidden windows, so no manual gating is needed at all.
struct DNSOrb: View {
    enum State: Equatable {
        case live       // serving, everything registered
        case attention  // running, zones pending / conflict
        case stopped    // server off
    }

    let state: State
    var size: CGFloat = 28

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
        PulseContainer(animates: animates,
                       glowColor: NSColor(color),
                       glowRadius: size * 0.16) {
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
        }
        .frame(width: size, height: size)
        .opacity(state == .stopped ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.5), value: state)
    }
}

/// Hosting view that lets clicks pass through to the enclosing SwiftUI Button.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hosts SwiftUI content in an NSView whose *layer* carries the pulse:
/// a render-server scale + shadow-opacity animation (4 s, autoreversing,
/// repeating). Hit-testing is disabled so enclosing Buttons receive clicks.
private struct PulseContainer<Content: View>: NSViewRepresentable {
    let animates: Bool
    let glowColor: NSColor
    let glowRadius: CGFloat
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = PassthroughHostingView(rootView: content())
        view.wantsLayer = true
        view.layer?.shadowOffset = .zero
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content()
        guard let layer = view.layer else { return }
        layer.shadowColor = glowColor.cgColor
        layer.shadowRadius = glowRadius
        if animates {
            guard layer.animation(forKey: "localdns.pulse") == nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 1.05
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.30
            glow.toValue = 0.55
            let group = CAAnimationGroup()
            group.animations = [scale, glow]
            group.duration = 2 // 2 s each way = 4 s breath
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(group, forKey: "localdns.pulse")
        } else {
            layer.removeAnimation(forKey: "localdns.pulse")
            layer.shadowOpacity = 0.30
            layer.transform = CATransform3DIdentity
        }
    }
}
