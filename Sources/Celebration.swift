import SwiftUI

/// 完成事项时的粒子小庆祝，约 0.8 秒。
struct CelebrationBurst: View {
    private struct Particle: Identifiable {
        let id = UUID()
        let angle: Double
        let distance: CGFloat
        let size: CGFloat
        let hueShift: Double
    }

    private let color: Color
    @State private var particles: [Particle] = []
    @State private var progress: Double = 0

    init(color: Color = .orange) {
        self.color = color
    }

    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                Circle()
                    .fill(color)
                    .hueRotation(.degrees(particle.hueShift))
                    .frame(width: particle.size, height: particle.size)
                    .offset(
                        x: cos(particle.angle) * particle.distance * progress,
                        y: sin(particle.angle) * particle.distance * progress
                    )
                    .opacity(progress < 0.8 ? 1 : max(0, 1 - (progress - 0.8) / 0.2))
            }
        }
        .onAppear {
            if particles.isEmpty {
                particles = (0..<14).map { index in
                    Particle(
                        angle: Double(index) / 14 * 2 * .pi + .random(in: -0.18...0.18),
                        distance: .random(in: 30...58),
                        size: .random(in: 4...8),
                        hueShift: .random(in: -14...14)
                    )
                }
            }
            withAnimation(.easeOut(duration: 0.8)) { progress = 1 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
