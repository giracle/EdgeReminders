import SwiftUI

/// 完成事项时的烟花庆祝：烟花升空、绽放成多彩光点，带闪光、拖尾与闪烁，约 3 秒。
/// 「减少动态效果」开启时只播一次柔和的光晕。
struct FireworkCelebration: View {
    private let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = FireworkEngine()

    init(accent: Color) {
        self.accent = accent
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                engine.update(
                    now: timeline.date.timeIntervalSinceReferenceDate,
                    size: size,
                    accent: accent,
                    reducedMotion: reduceMotion
                )
                render(into: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func render(into context: inout GraphicsContext) {
        for flash in engine.flashes {
            let progress = min(1, (engine.elapsed - flash.birth) / flash.duration)
            guard progress < 1 else { continue }
            let ease = 1 - pow(1 - progress, 3)
            let radius = 10 + 46 * ease
            let alpha = 0.9 * (1 - progress) * (1 - progress)
            context.fill(
                Path(ellipseIn: CGRect(x: flash.center.x - radius, y: flash.center.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        .white.opacity(alpha),
                        flash.color.opacity(alpha * 0.6),
                        flash.color.opacity(0)
                    ]),
                    center: flash.center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        for rocket in engine.rockets where !rocket.burstDone {
            let progress = (engine.elapsed - rocket.launchAt) / rocket.duration
            guard progress > 0, progress < 1 else { continue }
            let t = progress * (2 - progress)
            let pos = CGPoint(
                x: rocket.from.x + (rocket.to.x - rocket.from.x) * t,
                y: rocket.from.y + (rocket.to.y - rocket.from.y) * t
            )
            let tail = CGPoint(
                x: pos.x - (pos.x - rocket.from.x) * 0.14,
                y: pos.y - (pos.y - rocket.from.y) * 0.14
            )
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: pos)
            context.stroke(
                streak,
                with: .linearGradient(
                    Gradient(colors: [rocket.color.opacity(0), rocket.color.opacity(0.85)]),
                    startPoint: tail,
                    endPoint: pos
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            let head: CGFloat = 2.4
            context.fill(
                Path(ellipseIn: CGRect(x: pos.x - head * 2, y: pos.y - head * 2,
                                       width: head * 4, height: head * 4)),
                with: .color(.white.opacity(0.9))
            )
        }

        for p in engine.particles {
            let age = engine.elapsed - p.birth
            let lifeFraction = age / p.life
            guard lifeFraction < 1 else { continue }
            let fadeIn = min(1, age / 0.04)
            let fadeOut = pow(1 - lifeFraction, 1.15)
            let twinkle = 0.55 + 0.45 * sin(age * p.twinkleSpeed + p.twinklePhase)
            let alpha = fadeIn * fadeOut * twinkle
            let radius = p.size * (1 - 0.45 * lifeFraction)

            if p.hasTrail {
                let tail = CGPoint(
                    x: p.position.x - p.velocity.dx * 0.022,
                    y: p.position.y - p.velocity.dy * 0.022
                )
                var streak = Path()
                streak.move(to: tail)
                streak.addLine(to: p.position)
                context.stroke(
                    streak,
                    with: .color(p.color.opacity(alpha * 0.45)),
                    style: StrokeStyle(lineWidth: radius * 1.5, lineCap: .round)
                )
            }

            let glow = radius * 2.3
            context.fill(
                Path(ellipseIn: CGRect(x: p.position.x - glow, y: p.position.y - glow,
                                       width: glow * 2, height: glow * 2)),
                with: .color(p.color.opacity(alpha * 0.2))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: p.position.x - radius, y: p.position.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(p.color.opacity(min(1, alpha + 0.12)))
            )
            let hot = radius * 0.5
            context.fill(
                Path(ellipseIn: CGRect(x: p.position.x - hot, y: p.position.y - hot,
                                       width: hot * 2, height: hot * 2)),
                with: .color(.white.opacity(alpha * 0.75))
            )
        }
    }
}

/// 烟花粒子引擎：按帧推进火箭与光点，由 `FireworkCelebration` 在 Canvas 里渲染。
private final class FireworkEngine {
    struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var color: Color
        var size: CGFloat
        var birth: TimeInterval
        var life: TimeInterval
        var gravity: Double
        var drag: Double
        var twinkleSpeed: Double
        var twinklePhase: Double
        var hasTrail: Bool
    }

    struct Flash {
        var center: CGPoint
        var color: Color
        var birth: TimeInterval
        var duration: TimeInterval
    }

    struct Rocket {
        var from: CGPoint
        var to: CGPoint
        var launchAt: TimeInterval
        var duration: TimeInterval
        var color: Color
        var burstDone = false
    }

    private static let palette: [Color] = [
        Color(red: 1.00, green: 0.84, blue: 0.36),   // 金
        Color(red: 1.00, green: 0.44, blue: 0.38),   // 朱红
        Color(red: 1.00, green: 0.56, blue: 0.78),   // 玫粉
        Color(red: 0.66, green: 0.56, blue: 1.00),   // 雾紫
        Color(red: 0.34, green: 0.86, blue: 1.00),   // 青
        Color(red: 0.52, green: 1.00, blue: 0.62),   // 翠
        Color(red: 1.00, green: 0.64, blue: 0.30)    // 橙
    ]

    private(set) var particles: [Particle] = []
    private(set) var flashes: [Flash] = []
    private(set) var rockets: [Rocket] = []
    private(set) var elapsed: TimeInterval = 0

    private var accent: Color = .orange
    private var startedAt: TimeInterval?
    private var lastTime: TimeInterval?
    private var planned = false
    private static let particleCap = 340

    func update(now: TimeInterval, size: CGSize, accent: Color, reducedMotion: Bool) {
        guard size.width > 60, size.height > 60 else { return }
        if !planned {
            startedAt = now
            lastTime = now
            plan(size: size, accent: accent, reducedMotion: reducedMotion)
            planned = true
        }
        guard let start = startedAt else { return }
        let dt = min(max(now - (lastTime ?? now), 0), 1.0 / 30.0)
        lastTime = now
        elapsed = now - start
        guard dt > 0 else { return }

        stepRockets(size: size)
        stepParticles(dt: dt)
        flashes.removeAll { elapsed - $0.birth > $0.duration }
        particles.removeAll { elapsed - $0.birth > $0.life }
    }

    private func plan(size: CGSize, accent: Color, reducedMotion: Bool) {
        self.accent = accent
        if reducedMotion {
            flashes.append(Flash(center: CGPoint(x: size.width * 0.5, y: size.height * 0.22),
                                 color: accent, birth: 0, duration: 1.0))
            return
        }
        for i in 0..<4 {
            let launchAt = Double(i) * 0.36 + .random(in: 0...0.08)
            let to = CGPoint(
                x: size.width * .random(in: 0.20...0.80),
                y: size.height * .random(in: 0.10...0.38)
            )
            let from = CGPoint(x: to.x + .random(in: -46...46), y: size.height * 0.97)
            let color = i == 0 ? accent : Self.palette.randomElement()!
            rockets.append(Rocket(from: from, to: to, launchAt: launchAt, duration: 0.26, color: color))
        }
    }

    private func stepRockets(size: CGSize) {
        for i in rockets.indices where !rockets[i].burstDone {
            let rocket = rockets[i]
            let progress = (elapsed - rocket.launchAt) / rocket.duration
            guard progress >= 0 else { continue }
            if progress >= 1 {
                rockets[i].burstDone = true
                explode(at: rocket.to, baseColor: rocket.color)
            } else if particles.count < Self.particleCap {
                let t = progress * (2 - progress)
                let pos = CGPoint(
                    x: rocket.from.x + (rocket.to.x - rocket.from.x) * t,
                    y: rocket.from.y + (rocket.to.y - rocket.from.y) * t
                )
                particles.append(Particle(
                    position: pos,
                    velocity: CGVector(dx: .random(in: -14...14), dy: .random(in: -8...26)),
                    color: rocket.color,
                    size: .random(in: 1.0...1.7),
                    birth: elapsed,
                    life: .random(in: 0.16...0.30),
                    gravity: 30,
                    drag: 2.2,
                    twinkleSpeed: .random(in: 10...20),
                    twinklePhase: .random(in: 0..<2 * .pi),
                    hasTrail: false
                ))
            }
        }
    }

    private func explode(at center: CGPoint, baseColor: Color) {
        flashes.append(Flash(center: center, color: baseColor, birth: elapsed, duration: 0.34))
        let count = Int.random(in: 30...38)
        for _ in 0..<count where particles.count < Self.particleCap {
            let angle = Double.random(in: 0..<2 * .pi)
            let fast = Double.random(in: 0...1) < 0.2
            let speed = Double.random(in: 45...210) * (fast ? 1.35 : 0.85)
            let pick = Double.random(in: 0...1)
            let color = pick < 0.62 ? baseColor : (pick < 0.82 ? Self.palette.randomElement()! : accent)
            particles.append(Particle(
                position: center,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                color: color,
                size: .random(in: 1.3...2.6),
                birth: elapsed,
                life: .random(in: 0.75...1.45) * (fast ? 0.8 : 1),
                gravity: .random(in: 55...110),
                drag: .random(in: 1.1...1.9),
                twinkleSpeed: .random(in: 7...19),
                twinklePhase: .random(in: 0..<2 * .pi),
                hasTrail: true
            ))
        }
    }

    private func stepParticles(dt: TimeInterval) {
        for i in particles.indices {
            var p = particles[i]
            p.velocity.dy += p.gravity * dt
            let keep = max(0, 1 - p.drag * dt)
            p.velocity.dx *= keep
            p.velocity.dy *= keep
            p.position.x += p.velocity.dx * dt
            p.position.y += p.velocity.dy * dt
            particles[i] = p
        }
    }
}

/// 面板头部下方的彩虹细线，缓慢流转。
struct RainbowHairline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    private static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]

    var body: some View {
        LinearGradient(colors: Self.colors, startPoint: .leading, endPoint: .trailing)
            .hueRotation(.degrees(spinning ? 360 : 0))
            .frame(height: 2)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityHidden(true)
    }
}
