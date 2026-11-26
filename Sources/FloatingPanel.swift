import AppKit
import SwiftUI

private final class FloatingWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class DragHandle: NSView {
    var began: ((NSEvent) -> Void)?
    var moved: ((NSEvent) -> Void)?
    var ended: ((NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { began?(event) }
    override func mouseDragged(with event: NSEvent) { moved?(event) }
    override func mouseUp(with event: NSEvent) { ended?(event) }
}

@MainActor
final class FloatingPanelController: NSObject {
    private enum State { case floating, closing, hidden, revealing, docked }

    private let panel: FloatingWindow
    private let effects = PanelEffects()
    private let size = CGSize(width: 380, height: 390)
    private var state: State = .floating
    private var dock: PanelDock?
    private var hint: PanelDock?
    private var candidate: PanelDock?
    private var hoverSince: TimeInterval = 0
    private var departedAt: TimeInterval?
    private var blocked: PanelDock?
    private var editing = false
    private var tracking: Timer?
    private var animation: Timer?
    private var target: CGPoint = .zero
    private var velocity: CGVector = .zero
    private var lastFrame: TimeInterval = 0
    private var animationStarted: TimeInterval = 0
    private var dragStart: CGPoint?
    private var dragOrigin: CGPoint = .zero
    private var lastDrag: (point: CGPoint, time: TimeInterval)?
    private var hasDragged = false
    private var waitUntil: TimeInterval = 0
    private var waitsForPanelEntry = false

    init(store: TaskStore, onOpenManager: @escaping () -> Void) {
        panel = FloatingWindow(contentRect: CGRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        super.init()
        panel.title = "待完成"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none

        let content = TaskPanelView(store: store, onOpenManager: onOpenManager) { [weak self] editing in
            self?.setEditing(editing)
        }
        let host = NSHostingView(rootView: ZStack {
            GlassSurface(effects: effects).accessibilityHidden(true)
            content
        }.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(host)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        let handle = DragHandle(frame: CGRect(x: 0, y: size.height - 50, width: 210, height: 50))
        handle.setAccessibilityElement(false)
        handle.began = { [weak self] in self?.beginDrag($0) }
        handle.moved = { [weak self] in self?.drag($0) }
        handle.ended = { [weak self] in self?.endDrag($0) }
        container.addSubview(handle)
        panel.contentView = container

        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        let timer = Timer(timeInterval: 1 / 30, target: self, selector: #selector(trackPointer), userInfo: nil, repeats: true)
        tracking = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func show() {
        if let dock, state == .hidden || state == .closing {
            waitsForPanelEntry = true
            reveal(dock)
            return
        }
        if !panel.isVisible, let screen = preferredScreen() {
            let bounds = screen.visibleFrame
            let origin = CGPoint(x: bounds.maxX - size.width - 28, y: bounds.maxY - size.height - 28)
            panel.setFrame(PanelDock.fit(CGRect(origin: origin, size: size), inside: bounds), display: false)
        }
        effects.setVisible(true)
        panel.orderFrontRegardless()
    }

    func hide() {
        let point = NSEvent.mouseLocation
        guard let anchor = dock ?? defaultDock(point: point) else { return }
        if state == .hidden || state == .closing { return }
        blocked = anchor
        close(at: anchor)
    }

    private func defaultDock(point: CGPoint) -> PanelDock? {
        guard let screen = panel.screen ?? preferredScreen() else { return nil }
        let center = CGPoint(x: screen.frame.maxX, y: panel.frame.midY)
        return PanelDock(edge: .right, display: screen.frame, usable: screen.visibleFrame,
                         pointer: screen.frame.contains(point) ? point : center)
    }

    private func preferredScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func findDock(near point: CGPoint, threshold: CGFloat, cornerInset: CGFloat) -> PanelDock? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(point) }) else {
            return nil
        }
        let neighbors = NSScreen.screens.filter { $0 !== screen }.map(\.frame)
        guard let edge = PanelDock.nearest(to: point, in: screen.frame, neighbors: neighbors,
                                           threshold: threshold, cornerInset: cornerInset) else { return nil }
        return PanelDock(edge: edge, display: screen.frame, usable: screen.visibleFrame, pointer: point)
    }

    private func sameSide(_ a: PanelDock, _ b: PanelDock) -> Bool {
        a.edge == b.edge && a.display == b.display
    }

    private func dragDock(at point: CGPoint) -> PanelDock? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return nil }
        let neighbors = NSScreen.screens.filter { $0 !== screen }.map(\.frame)
        guard let edge = PanelDock.dragEdge(window: panel.frame, pointer: point, display: screen.frame,
                                            neighbors: neighbors) else { return nil }
        return PanelDock(edge: edge, display: screen.frame, usable: screen.visibleFrame, pointer: point)
    }

    @objc private func trackPointer() {
        guard !hasDragged, !editing, state != .floating else { return }
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let current = findDock(near: point, threshold: 3, cornerInset: 16)
        if let blocked, current.map({ sameSide($0, blocked) }) != true { self.blocked = nil }
        let mouseDown = NSEvent.pressedMouseButtons != 0

        if state == .hidden || state == .closing {
            guard !mouseDown, let current, blocked == nil, now >= waitUntil else {
                candidate = nil
                return
            }
            if let candidate, sameSide(candidate, current),
               hypot(candidate.pointer.x - point.x, candidate.pointer.y - point.y) < 7 {
                if now - hoverSince >= 0.35 { reveal(current) }
            } else {
                candidate = current
                hoverSince = now
            }
            return
        }

        guard let dock else { return }
        let desiredFrame = dock.shownFrame(size: size)
        if waitsForPanelEntry {
            guard state == .docked, panel.frame.contains(point) else { return }
            waitsForPanelEntry = false
        }
        if mouseDown || panel.frame.insetBy(dx: -2, dy: -2).contains(point)
            || desiredFrame.insetBy(dx: -2, dy: -2).contains(point) || dock.connects(point, to: desiredFrame)
            || current.map({ sameSide($0, dock) }) == true {
            departedAt = nil
        } else if let departedAt {
            if now - departedAt >= 0.30 { close(at: dock) }
        } else {
            departedAt = now
        }
    }

    private func setEditing(_ value: Bool) {
        editing = value
        departedAt = nil
        if value { panel.makeKey() }
    }

    private func reveal(_ anchor: PanelDock) {
        let interrupt = state == .closing && dock.map { sameSide($0, anchor) } == true
        if !interrupt {
            stopAnimation()
            panel.setFrame(anchor.hiddenFrame(size: size), display: false)
        }
        dock = anchor
        state = .revealing
        candidate = nil
        departedAt = nil
        waitUntil = ProcessInfo.processInfo.systemUptime + 0.45
        effects.setVisible(true)
        effects.setDockHint(nil)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        let frame = anchor.shownFrame(size: size)
        animate(to: frame, strength: 1, contact: contact(in: frame, for: anchor))
    }

    private func close(at anchor: PanelDock) {
        waitsForPanelEntry = false
        dock = anchor
        state = .closing
        candidate = nil
        departedAt = nil
        effects.setDockHint(nil)
        effects.setDragVelocity(.zero)
        panel.ignoresMouseEvents = true
        animate(to: anchor.hiddenFrame(size: size), strength: 0.85, contact: contact(in: panel.frame, for: anchor))
    }

    private func contact(in frame: CGRect, for anchor: PanelDock) -> CGPoint {
        normalized(anchor.edge.contact(in: frame, alignedWith: anchor.pointer), in: frame)
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / frame.width, y: (frame.maxY - point.y) / frame.height)
    }

    private func animate(to frame: CGRect, strength: Double, contact: CGPoint) {
        target = frame.origin
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAnimation()
            if state == .revealing {
                panel.alphaValue = 0
                panel.setFrame(frame, display: true)
            }
            let direction = state
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                panel.animator().alphaValue = direction == .revealing ? 1 : 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.state == direction else { return }
                    self.finishAnimation()
                }
            }
            return
        }
        effects.ripple(at: contact, strength: strength)
        guard animation == nil else { return }
        animationStarted = ProcessInfo.processInfo.systemUptime
        lastFrame = animationStarted
        let timer = Timer(timeInterval: 1 / 120, target: self, selector: #selector(stepAnimation), userInfo: nil, repeats: true)
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func stepAnimation() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - lastFrame, 1 / 30)
        lastFrame = now
        var origin = panel.frame.origin
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        velocity.dx += (465 * dx - 41 * velocity.dx) * dt
        velocity.dy += (465 * dy - 41 * velocity.dy) * dt
        origin.x += velocity.dx * dt
        origin.y += velocity.dy * dt
        if (hypot(dx, dy) < 0.8 && hypot(velocity.dx, velocity.dy) < 12) || now - animationStarted > 0.9 {
            finishAnimation()
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    private func finishAnimation() {
        stopAnimation()
        if state == .closing {
            panel.orderOut(nil)
            panel.alphaValue = 1
            effects.setVisible(false)
            state = .hidden
        } else if state == .revealing {
            panel.setFrameOrigin(target)
            panel.alphaValue = 1
            state = .docked
        }
    }

    private func stopAnimation() {
        animation?.invalidate()
        animation = nil
        velocity = .zero
    }

    private func beginDrag(_ event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragOrigin = panel.frame.origin
        lastDrag = (NSEvent.mouseLocation, event.timestamp)
        hasDragged = false
    }

    private func drag(_ event: NSEvent) {
        guard let dragStart else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        if !hasDragged {
            guard hypot(dx, dy) >= 3 else { return }
            hasDragged = true
            stopAnimation()
            state = .floating
            dock = nil
            effects.ripple(at: normalized(dragStart, in: panel.frame), strength: 0.4)
        }
        if let lastDrag, event.timestamp > lastDrag.time {
            let dt = event.timestamp - lastDrag.time
            effects.setDragVelocity(CGVector(dx: (point.x - lastDrag.point.x) / dt, dy: (lastDrag.point.y - point.y) / dt))
        }
        lastDrag = (point, event.timestamp)
        panel.setFrameOrigin(CGPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy))
        let previous = hint
        hint = dragDock(at: point)
        effects.setDockHint(hint?.edge)
        if let hint, previous.map({ sameSide($0, hint) }) != true {
            effects.ripple(at: contact(in: panel.frame, for: hint), strength: 0.38)
        }
    }

    private func endDrag(_ event: NSEvent) {
        defer { dragStart = nil; lastDrag = nil; hasDragged = false; hint = nil }
        guard hasDragged else { return }
        let point = NSEvent.mouseLocation
        effects.setDragVelocity(.zero)
        effects.setDockHint(nil)
        if let anchor = dragDock(at: point) {
            blocked = anchor
            waitUntil = ProcessInfo.processInfo.systemUptime + 0.45
            close(at: anchor)
        } else if let screen = preferredScreen() {
            panel.setFrame(PanelDock.fit(panel.frame, inside: screen.visibleFrame), display: true)
        }
    }

    @objc private func displaysChanged() {
        guard let screen = preferredScreen() else { return }
        if state == .hidden { return }
        stopAnimation()
        state = .floating
        dock = nil
        candidate = nil
        blocked = nil
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.setFrame(PanelDock.fit(panel.frame, inside: screen.visibleFrame), display: true)
    }
}
