import AppKit
import QuartzCore
import SwiftUI

struct PanelRipple {
    let origin: CGPoint
    let startedAt: CFTimeInterval
    let strength: Double

    static let duration: CFTimeInterval = 1.05

    func uniform(now: CFTimeInterval, size: CGSize) -> Shader.Argument {
        .float4(
            origin.x * size.width,
            origin.y * size.height,
            max(0, now - startedAt),
            strength
        )
    }
}

@MainActor
final class PanelEffects: ObservableObject {
    @Published private(set) var ripples: [PanelRipple] = []
    @Published private(set) var dockHint: PanelEdge?
    @Published private(set) var dragOffset: CGSize = .zero

    private var isVisible = false
    private var rippleCleanup: Task<Void, Never>?

    func ripple(at point: CGPoint, strength: Double) {
        guard isVisible, strength > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime()
        let origin = CGPoint(
            x: min(1, max(0, point.x)),
            y: min(1, max(0, point.y))
        )
        let active = ripples.filter { now - $0.startedAt < PanelRipple.duration }
        let ripple = PanelRipple(origin: origin, startedAt: now, strength: min(1.25, strength))
        ripples = [ripple] + active.prefix(2)

        rippleCleanup?.cancel()
        rippleCleanup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PanelRipple.duration))
            guard !Task.isCancelled else { return }
            self?.ripples.removeAll()
        }
    }

    func setDockHint(_ edge: PanelEdge?) {
        guard dockHint != edge else { return }
        dockHint = edge
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        guard !visible else { return }
        rippleCleanup?.cancel()
        rippleCleanup = nil
        ripples.removeAll()
        setDockHint(nil)
        setDragVelocity(.zero)
    }

    func setDragVelocity(_ velocity: CGVector) {
        let offset = CGSize(
            width: min(18, max(-18, velocity.dx / 62)),
            height: min(18, max(-18, velocity.dy / 62))
        )
        guard abs(dragOffset.width - offset.width) >= 0.5
                || abs(dragOffset.height - offset.height) >= 0.5
                || (offset == .zero && dragOffset != .zero) else { return }
        dragOffset = offset
    }
}

struct GlassSurface: View {
    static let cornerRadius: CGFloat = 26

    @ObservedObject var effects: PanelEffects
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
    }

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                NativePanelGlass(cornerRadius: Self.cornerRadius)
                opticalSurface
            }

            shape.strokeBorder(edgeReflection, lineWidth: 1)
            if let edge = effects.dockHint {
                shape.strokeBorder(dockReflection(edge), lineWidth: 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.10 : 0.19), value: effects.dockHint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var opticalSurface: some View {
        GeometryReader { geometry in
            let animate = !reduceMotion && !effects.ripples.isEmpty
            TimelineView(.animation(minimumInterval: 1 / 120, paused: !animate)) { _ in
                opticalTint
                    .layerEffect(
                        waterShader(size: geometry.size),
                        maxSampleOffset: CGSize(width: 24, height: 24),
                        isEnabled: animate
                    )
            }
        }
        .clipShape(shape)
    }

    private var opticalTint: some View {
        let dark = colorScheme == .dark
        let offset = reduceMotion ? .zero : effects.dragOffset
        return ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(dark ? 0.32 : 0.34)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(dark ? 0.12 : 0.31), location: 0),
                    .init(color: .clear, location: 0.44),
                    .init(color: Color(red: 0.17, green: 0.41, blue: 0.45).opacity(dark ? 0.15 : 0.09), location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .padding(-20)
            .offset(offset)
            .animation(.spring(duration: 0.25, bounce: 0.12), value: offset)
        }
    }

    private var edgeReflection: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(colorScheme == .dark ? 0.38 : 0.66), .white.opacity(0.05), .white.opacity(0.17)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func dockReflection(_ edge: PanelEdge) -> LinearGradient {
        let direction: (UnitPoint, UnitPoint)
        switch edge {
        case .left: direction = (.leading, .trailing)
        case .right: direction = (.trailing, .leading)
        case .top: direction = (.top, .bottom)
        case .bottom: direction = (.bottom, .top)
        }
        let reflection = Color(red: 0.48, green: 0.85, blue: 0.91).opacity(0.88)
        return LinearGradient(
            stops: [.init(color: reflection, location: 0), .init(color: .clear, location: 0.55)],
            startPoint: direction.0,
            endPoint: direction.1
        )
    }

    private func waterShader(size: CGSize) -> Shader {
        let now = CACurrentMediaTime()
        let inactive: Shader.Argument = .float4(0.0, 0.0, 0.0, 0.0)
        let waves = effects.ripples.map { $0.uniform(now: now, size: size) }
        return ShaderLibrary.panelWaterRipple(
            .float2(size),
            waves.indices.contains(0) ? waves[0] : inactive,
            waves.indices.contains(1) ? waves[1] : inactive,
            waves.indices.contains(2) ? waves[2] : inactive
        )
    }
}

private struct NativePanelGlass: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = NSView()
            return glass
        }

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active

        let side = 2 * cornerRadius + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        blur.maskImage = mask
        return blur
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
