import CoreGraphics

@main
enum WindowGeometryTests {
    static func main() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let usable = CGRect(x: 0, y: 45, width: 1440, height: 830)
        let size = CGSize(width: 380, height: 390)
        let edges: [(PanelEdge, CGPoint)] = [(.left, CGPoint(x: 1, y: 460)),
                                           (.right, CGPoint(x: 1439, y: 320)),
                                           (.top, CGPoint(x: 440, y: 899)),
                                           (.bottom, CGPoint(x: 600, y: 1))]
        for (edge, point) in edges {
            precondition(PanelDock.nearest(to: point, in: display, neighbors: [], threshold: 3, cornerInset: 16) == edge)
            let dock = PanelDock(edge: edge, display: display, usable: usable, pointer: point)
            let shown = dock.shownFrame(size: size)
            let hidden = dock.hiddenFrame(size: size)
            precondition(usable.contains(shown))
            precondition(!display.intersects(hidden))
            precondition(dock.connects(point, to: shown))
        }

        let upperRightDisplay = CGRect(x: 1440, y: 450, width: 1080, height: 720)
        let neighbors = [upperRightDisplay]
        precondition(PanelDock.nearest(to: CGPoint(x: 1439, y: 600), in: display, neighbors: neighbors,
                                      threshold: 3, cornerInset: 16) == nil)
        precondition(PanelDock.nearest(to: CGPoint(x: 1439, y: 320), in: display, neighbors: neighbors,
                                      threshold: 3, cornerInset: 16) == .right)
        precondition(PanelDock.nearest(to: CGPoint(x: 2, y: 2), in: display, neighbors: [],
                                      threshold: 3, cornerInset: 16) == nil)

        let nearRight = CGRect(x: 1050, y: 100, width: 380, height: 390)
        precondition(PanelDock.dragEdge(window: nearRight, pointer: CGPoint(x: 1100, y: 440),
                                       display: display, neighbors: []) == .right)
        precondition(PanelDock.dragEdge(window: nearRight.offsetBy(dx: 0, dy: 200), pointer: CGPoint(x: 1100, y: 640),
                                       display: display, neighbors: neighbors) == nil)
        print("Window geometry passed: four sides, full hiding, hover bridge, corners, drag snapping and shared edges")
    }
}
