import CoreGraphics

enum PanelEdge: CaseIterable, Equatable {
    case left, right, top, bottom

    var isVertical: Bool { self == .left || self == .right }

    func distance(to point: CGPoint, in frame: CGRect) -> CGFloat {
        switch self {
        case .left: abs(point.x - frame.minX)
        case .right: abs(frame.maxX - point.x)
        case .top: abs(frame.maxY - point.y)
        case .bottom: abs(point.y - frame.minY)
        }
    }

    func project(_ point: CGPoint, onto frame: CGRect, outward inset: CGFloat = 0) -> CGPoint {
        switch self {
        case .left: CGPoint(x: frame.minX - inset, y: point.y)
        case .right: CGPoint(x: frame.maxX + inset, y: point.y)
        case .top: CGPoint(x: point.x, y: frame.maxY + inset)
        case .bottom: CGPoint(x: point.x, y: frame.minY - inset)
        }
    }

    func contact(in frame: CGRect, alignedWith pointer: CGPoint) -> CGPoint {
        let point = CGPoint(x: min(max(pointer.x, frame.minX), frame.maxX),
                            y: min(max(pointer.y, frame.minY), frame.maxY))
        return project(point, onto: frame)
    }
}

struct PanelDock: Equatable {
    var edge: PanelEdge
    var display: CGRect
    var usable: CGRect
    var pointer: CGPoint

    func shownFrame(size: CGSize) -> CGRect {
        let margin: CGFloat = 9
        var origin = CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2)
        switch edge {
        case .left: origin.x = usable.minX + margin
        case .right: origin.x = usable.maxX - size.width - margin
        case .top: origin.y = usable.maxY - size.height - margin
        case .bottom: origin.y = usable.minY + margin
        }
        return Self.fit(CGRect(origin: origin, size: size), inside: usable.insetBy(dx: margin, dy: margin))
    }

    func hiddenFrame(size: CGSize) -> CGRect {
        var frame = shownFrame(size: size)
        switch edge {
        case .left: frame.origin.x = display.minX - size.width - 32
        case .right: frame.origin.x = display.maxX + 32
        case .top: frame.origin.y = display.maxY + 32
        case .bottom: frame.origin.y = display.minY - size.height - 32
        }
        return frame
    }

    func connects(_ point: CGPoint, to frame: CGRect) -> Bool {
        let radius: CGFloat = 7
        let start = edge.contact(in: frame, alignedWith: pointer)
        let end = edge.project(start, onto: display)
        let bridge = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -radius, dy: -radius)
        return bridge.contains(point)
    }

    static func nearest(to point: CGPoint, in display: CGRect, neighbors: [CGRect],
                        threshold: CGFloat, cornerInset: CGFloat) -> PanelEdge? {
        guard display.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        return PanelEdge.allCases.filter { edge in
            let alongEdge = edge.isVertical ? point.y - display.minY : point.x - display.minX
            let span = edge.isVertical ? display.height : display.width
            let across = edge.project(point, onto: display, outward: 2)
            return alongEdge >= cornerInset && alongEdge <= span - cornerInset
                && edge.distance(to: point, in: display) <= threshold
                && !neighbors.contains { $0.contains(across) }
        }.min { $0.distance(to: point, in: display) < $1.distance(to: point, in: display) }
    }

    static func dragEdge(window: CGRect, pointer: CGPoint, display: CGRect, neighbors: [CGRect]) -> PanelEdge? {
        if let edge = nearest(to: pointer, in: display, neighbors: neighbors, threshold: 28, cornerInset: 0) {
            return edge
        }
        return PanelEdge.allCases.compactMap { edge -> (PanelEdge, CGFloat)? in
            let contact = edge.contact(in: window, alignedWith: pointer)
            let onScreen = edge.project(contact, onto: display)
            let distance = edge.distance(to: contact, in: display)
            guard distance <= 18, display.insetBy(dx: -1, dy: -1).contains(onScreen),
                  !neighbors.contains(where: { $0.contains(edge.project(contact, onto: display, outward: 2)) }) else {
                return nil
            }
            return (edge, distance)
        }.min { $0.1 < $1.1 }?.0
    }

    static func fit(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        CGRect(x: max(bounds.minX, min(frame.minX, bounds.maxX - frame.width)),
               y: max(bounds.minY, min(frame.minY, bounds.maxY - frame.height)),
               width: frame.width, height: frame.height)
    }
}
