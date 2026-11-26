import AppKit
import QuartzCore

struct TimerCompletionTrack {
    static let lapDuration: TimeInterval = 10
    static let lapCount = 2
    static let travelDuration = lapDuration * Double(lapCount)

    struct Span {
        let start: CGPoint
        let end: CGPoint
        let colorRange: ClosedRange<CGFloat>
    }

    let bounds: CGRect

    var perimeter: CGFloat { 2 * (bounds.width + bounds.height) }

    func distance(at elapsed: TimeInterval) -> CGFloat {
        let time = min(max(elapsed, 0), Self.travelDuration)
        return perimeter * (time / Self.lapDuration)
    }

    func point(at distance: CGFloat) -> CGPoint {
        guard perimeter > 0 else { return CGPoint(x: bounds.maxX, y: bounds.maxY) }
        let remainder = distance.truncatingRemainder(dividingBy: perimeter)
        let offset = remainder < 0 ? remainder + perimeter : remainder
        let height = bounds.height
        let width = bounds.width

        switch offset {
        case ..<height:
            return CGPoint(x: bounds.maxX, y: bounds.maxY - offset)
        case ..<(height + width):
            return CGPoint(x: bounds.maxX - (offset - height), y: bounds.minY)
        case ..<(2 * height + width):
            return CGPoint(x: bounds.minX, y: bounds.minY + (offset - height - width))
        default:
            return CGPoint(x: bounds.minX + (offset - 2 * height - width), y: bounds.maxY)
        }
    }

    func spans(tail: CGFloat, head: CGFloat) -> [Span] {
        guard perimeter > 0, head > tail else { return [] }
        let corners = [CGFloat.zero, bounds.height, bounds.height + bounds.width, 2 * bounds.height + bounds.width]
        let firstLap = Int(floor(tail / perimeter))
        let lastLap = Int(floor(head / perimeter))
        var stops: [CGFloat] = [tail]
        for lap in firstLap...lastLap {
            let start = CGFloat(lap) * perimeter
            stops.append(contentsOf: corners.map { start + $0 }.filter { $0 > tail && $0 < head })
        }
        stops.append(head)

        return zip(stops, stops.dropFirst()).map { start, end in
            Span(start: point(at: start), end: point(at: end),
                 colorRange: ((start - tail) / (head - tail))...((end - tail) / (head - tail)))
        }
    }
}

private final class TimerCompletionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TimerCompletionView: NSView {
    static let lineWidth: CGFloat = 6.6
    private var spans: [TimerCompletionTrack.Span] = []
    private var strength: CGFloat = 1
    private var steady = false

    func drawSpans(_ spans: [TimerCompletionTrack.Span], strength: CGFloat, steady: Bool) {
        for span in self.spans + spans {
            setNeedsDisplay(rect(for: span))
        }
        self.spans = spans
        self.strength = strength
        self.steady = steady
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        for span in spans {
            let frame = rect(for: span)
            guard frame.intersects(dirtyRect) else { continue }
            let low = span.colorRange.lowerBound
            let colors = (0...8).map { index in
                let fraction = low + (span.colorRange.upperBound - low) * CGFloat(index) / 8
                let opacity = steady ? 1 : fraction.squareRoot()
                return NSColor(hue: 0.78 * (1 - fraction), saturation: 0.83, brightness: 1,
                               alpha: opacity * strength).cgColor
            }
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: colors as CFArray, locations: nil) else { continue }
            context.saveGState()
            context.clip(to: frame)
            context.drawLinearGradient(gradient, start: span.start, end: span.end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
    }

    private func rect(for span: TimerCompletionTrack.Span) -> CGRect {
        let dx = abs(span.end.x - span.start.x)
        let dy = abs(span.end.y - span.start.y)
        let width = Self.lineWidth
        return dy > dx
            ? CGRect(x: span.start.x - width / 2, y: min(span.start.y, span.end.y) - 0.5,
                     width: width, height: dy + 1)
            : CGRect(x: min(span.start.x, span.end.x) - 0.5, y: span.start.y - width / 2,
                     width: dx + 1, height: width)
    }
}

@MainActor
final class TimerCompletionBorder: NSObject {
    private static let fadeDuration: TimeInterval = 0.45
    private static let stillDuration: TimeInterval = 1.4

    private var window: TimerCompletionWindow?
    private var displayLink: CADisplayLink?
    private var track: TimerCompletionTrack?
    private var startedAt: CFTimeInterval?
    private var reduceMotion = false

    func play(on screen: NSScreen) {
        stop()
        let size = screen.frame.size
        let lineWidth = TimerCompletionView.lineWidth
        guard size.width > lineWidth, size.height > lineWidth else { return }
        let localBounds = CGRect(origin: .zero, size: size)
        let halfWidth = lineWidth / 2
        track = TimerCompletionTrack(bounds: localBounds.insetBy(dx: halfWidth, dy: halfWidth))
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let window = TimerCompletionWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.level = .screenSaver
        window.animationBehavior = .none

        let border = TimerCompletionView(frame: localBounds)
        border.setAccessibilityElement(false)
        border.wantsLayer = true
        window.contentView = border
        self.window = window
        render(elapsed: reduceMotion ? 0 : 0.01)
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        displayLink?.invalidate()
        displayLink = nil
        window?.orderOut(nil)
        window = nil
        track = nil
        startedAt = nil
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        stop()
    }

    @objc private func step(_ link: CADisplayLink) {
        if startedAt == nil { startedAt = link.timestamp }
        guard let startedAt else { return }
        render(elapsed: max(0, link.timestamp - startedAt))
    }

    private func render(elapsed: TimeInterval) {
        guard let track, let view = window?.contentView as? TimerCompletionView else { return }
        let finish = reduceMotion ? Self.stillDuration : TimerCompletionTrack.travelDuration
        guard elapsed < finish + Self.fadeDuration else { stop(); return }
        let strength = CGFloat(1 - max(0, elapsed - finish) / Self.fadeDuration) * (reduceMotion ? 0.65 : 1)
        let head = track.distance(at: elapsed)
        let tail = max(0, head - track.perimeter * 0.18)
        let spans = reduceMotion ? track.spans(tail: 0, head: track.perimeter) : track.spans(tail: tail, head: head)

        view.drawSpans(spans, strength: strength, steady: reduceMotion)
    }
}
