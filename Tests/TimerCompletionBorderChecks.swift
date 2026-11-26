import AppKit

@main
@MainActor
enum TimerCompletionBorderChecks {
    static func main() {
        let track = TimerCompletionTrack(bounds: CGRect(x: 1.5, y: 1.5, width: 100, height: 50))
        precondition(track.point(at: 0) == CGPoint(x: 101.5, y: 51.5))
        precondition(track.point(at: 50) == CGPoint(x: 101.5, y: 1.5))
        precondition(track.point(at: 150) == CGPoint(x: 1.5, y: 1.5))
        precondition(track.point(at: 200) == CGPoint(x: 1.5, y: 51.5))
        precondition(track.distance(at: 10) == track.perimeter)
        precondition(track.distance(at: 20) == 2 * track.perimeter)
        precondition(track.distance(at: 20.3) == track.distance(at: 20))
        let wrapped = track.spans(tail: track.perimeter - 10, head: track.perimeter + 10)
        precondition(wrapped.count == 2 && wrapped[0].end == wrapped[1].start)
        precondition(wrapped[0].colorRange.upperBound == wrapped[1].colorRange.lowerBound)
        print("Completion border path and lap timing passed")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { return }
        let currentWindows = Set(app.windows.map(ObjectIdentifier.init))
        let effect = TimerCompletionBorder()
        let started = ProcessInfo.processInfo.systemUptime
        effect.play(on: screen)
        guard let overlay = app.windows.first(where: { !currentWindows.contains(ObjectIdentifier($0)) }) else {
            preconditionFailure("Expected an overlay on the selected monitor")
        }
        precondition(overlay.frame == screen.frame && overlay.isVisible && overlay.ignoresMouseEvents)
        precondition(!overlay.isKeyWindow && !overlay.canBecomeKey && !overlay.canBecomeMain)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
        guard let view = overlay.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("Expected a raster of the rendered border")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let xScale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let yScale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        func hasColor(at x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            return color.alphaComponent > 0.35 && channels.max()! - channels.min()! > 0.2
        }
        let insideBand = bitmap.pixelsWide - Int(5 * xScale)
        let outsideBand = bitmap.pixelsWide - Int(8 * xScale)
        let edgeRows = Int(16 * yScale)..<(bitmap.pixelsHigh - Int(16 * yScale))
        precondition(edgeRows.contains { hasColor(at: insideBand, $0) }, "The edge must contain visible rainbow pixels")
        precondition(!edgeRows.contains { hasColor(at: outsideBand, $0) }, "The rainbow must stay at the edge")
        precondition(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent == 0,
                     "The center of the overlay must be transparent")
        print("Native rainbow pixel checks passed")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 10.1))
            precondition(overlay.isVisible, "The effect must still be playing after one lap")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0, started + 21.3 - ProcessInfo.processInfo.systemUptime)))
        } else {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.5))
        }
        precondition(!overlay.isVisible, "The overlay must hide itself after the effect")
        effect.stop()
        print("Native click-through overlay appeared and cleaned itself up")
    }
}
