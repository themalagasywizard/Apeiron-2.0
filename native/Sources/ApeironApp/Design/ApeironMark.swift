import SwiftUI

/// Apeiron's mark: three interlaced orbits around a point – "the boundless".
struct OrbitShape: Shape {
    var orbits: Int = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radiusX = min(rect.width, rect.height) / 2
        let radiusY = radiusX * 0.38
        for index in 0..<orbits {
            let angle = Double(index) * .pi / Double(orbits)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: CGFloat(angle))
            path.addEllipse(
                in: CGRect(x: -radiusX, y: -radiusY, width: radiusX * 2, height: radiusY * 2),
                transform: transform
            )
        }
        return path
    }
}

struct ApeironMark: View {
    var size: CGFloat = 28
    /// Spins and breathes while the agent is working.
    var isActive: Bool = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isActive || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let spin = isActive && !reduceMotion ? Angle.degrees(time.truncatingRemainder(dividingBy: 6) * 60) : .zero
            let pulse = isActive && !reduceMotion ? 1 + 0.06 * sin(time * 3) : 1
            ZStack {
                OrbitShape()
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: max(1.2, size / 16), lineCap: .round))
                    .rotationEffect(spin)
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .scaleEffect(pulse)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Apeiron")
    }
}
