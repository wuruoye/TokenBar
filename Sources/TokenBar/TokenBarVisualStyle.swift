import AppKit
import SwiftUI

enum TokenBarVisualStyle {
    static let costAccentNSColor = NSColor(name: "TokenBarCostAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.00, green: 0.46, blue: 0.54, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.16, blue: 0.27, alpha: 1)
    }

    static var costAccentColor: Color {
        Color(nsColor: self.costAccentNSColor)
    }

    static let tierBadgeAccentNSColor = NSColor(name: "TokenBarTierBadgeAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.72, green: 0.66, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.40, green: 0.30, blue: 0.86, alpha: 1)
    }
}
