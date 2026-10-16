import SwiftUI

struct IntroductionParticlesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let elapsed = reduceMotion ? 0 : max(0, timeline.date.timeIntervalSince(startDate))
                let colors: [Color] = [.blue, .indigo, .cyan]

                for index in 0..<24 {
                    let seed = Double((index * 37 + 11) % 101) / 101
                    let lifetime = 18 + Double(index % 7) * 3
                    let progress = (elapsed / lifetime + seed).truncatingRemainder(dividingBy: 1)
                    let horizontalPosition = Double((index * 59 + 7) % 103) / 103
                    let drift = sin(elapsed * 0.22 + seed * .pi * 2) * 0.05
                    let point = CGPoint(x: (horizontalPosition + drift) * size.width, y: (1 - progress) * size.height)
                    let isGlow = index.isMultiple(of: 6)
                    let radius: CGFloat = isGlow ? 16 : (index.isMultiple(of: 3) ? 3 : 1.5)
                    let opacity = sin(progress * .pi) * (colorScheme == .dark ? 0.35 : 0.22)
                    let color = colors[index % colors.count]
                    let bounds = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

                    if isGlow {
                        context.fill(
                            Path(ellipseIn: bounds),
                            with: .radialGradient(
                                Gradient(colors: [color.opacity(opacity * 0.6), color.opacity(0)]),
                                center: point,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    } else {
                        context.fill(Path(ellipseIn: bounds), with: .color(color.opacity(opacity)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
