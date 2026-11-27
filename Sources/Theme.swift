import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case fuguang, blue, orange, purple, pink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fuguang: "浮光青"
        case .blue: "深海蓝"
        case .orange: "暖阳橙"
        case .purple: "暮山紫"
        case .pink: "胭脂粉"
        }
    }

    var lightRGB: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .fuguang: (0.00, 0.36, 0.41)
        case .blue: (0.05, 0.28, 0.63)
        case .orange: (0.72, 0.38, 0.05)
        case .purple: (0.38, 0.24, 0.62)
        case .pink: (0.66, 0.16, 0.38)
        }
    }

    var darkRGB: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .fuguang: (0.59, 0.90, 0.91)
        case .blue: (0.55, 0.75, 1.0)
        case .orange: (1.0, 0.72, 0.42)
        case .purple: (0.72, 0.60, 1.0)
        case .pink: (1.0, 0.62, 0.78)
        }
    }

    var dynamicColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = dark ? self.darkRGB : self.lightRGB
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
    }

    var color: Color {
        Color(nsColor: dynamicColor)
    }
}
