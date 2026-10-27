import AppKit
import SwiftUI

enum TokenBarVisualStyle {
    /// Raised thumb of the platform switcher, matching a native segmented control.
    static let selectedSegmentNSColor = NSColor(name: "TokenBarSelectedSegment") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(white: 1, alpha: 0.2)
            : NSColor(white: 1, alpha: 1)
    }

    static var selectedSegmentColor: Color {
        Color(nsColor: self.selectedSegmentNSColor)
    }

    static let tierBadgeAccentNSColor = NSColor(name: "TokenBarTierBadgeAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.72, green: 0.66, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.40, green: 0.30, blue: 0.86, alpha: 1)
    }
}
