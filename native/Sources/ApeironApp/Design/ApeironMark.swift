import SwiftUI

/// Apeiron's mark: two open orbits around a point, "the boundless".
/// An arc of a circle, in degrees measured clockwise from 3 o'clock.
struct OrbitArc: Shape {
    var radius: CGFloat
    var start: Double
    var end: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2 * radius
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: r,
            startAngle: .degrees(start),
            endAngle: .degrees(end),
            clockwise: false
        )
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
            let line = max(1.2, size / 11)
            ZStack {
                OrbitArc(radius: 1, start: -60, end: 230)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .padding(line / 2)
                    .rotationEffect(spin)
                OrbitArc(radius: 0.66, start: 120, end: 410)
                    .stroke(theme.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: line * 0.85, lineCap: .round))
                    .padding(line / 2)
                    .rotationEffect(.degrees(-spin.degrees * 1.5))
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .scaleEffect(pulse)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Apeiron")
    }
}
