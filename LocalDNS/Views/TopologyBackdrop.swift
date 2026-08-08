import SwiftUI

/// Whisper-quiet static texture for the content layer: a faint dot grid plus a
/// few slightly brighter "nodes" with hairline connectors near the top.
///
/// It exists so the floating glass bar and pills have something to refract —
/// Liquid Glass reads as glass only with content behind it. This is not a
/// glass surface itself; it sits behind the content, below 8% opacity, and
/// adapts to light/dark via Color.primary. If you can see it at a glance,
/// it's too strong — dial the opacities down.
struct TopologyBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 30
            let dot: CGFloat = 1.5
            let dotColor = Color.primary.opacity(0.05)

            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                        with: .color(dotColor))
                    x += spacing
                }
                y += spacing
            }

            // A few "network nodes" with hairline links, top region only.
            let nodes: [CGPoint] = [
                CGPoint(x: size.width * 0.60, y: 64),
                CGPoint(x: size.width * 0.78, y: 34),
                CGPoint(x: size.width * 0.90, y: 108),
                CGPoint(x: size.width * 0.68, y: 148),
            ]
            let links: [(Int, Int)] = [(0, 1), (1, 2), (0, 3)]
            for (from, to) in links {
                var path = Path()
                path.move(to: nodes[from])
                path.addLine(to: nodes[to])
                context.stroke(path, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)
            }
            for node in nodes {
                context.fill(
                    Path(ellipseIn: CGRect(x: node.x - 2.5, y: node.y - 2.5, width: 5, height: 5)),
                    with: .color(Color.primary.opacity(0.08)))
            }
        }
        .allowsHitTesting(false)
    }
}
