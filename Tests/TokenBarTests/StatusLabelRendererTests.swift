import AppKit
import Testing
@testable import TokenBar

@MainActor
struct StatusLabelRendererTests {
    @Test("Platform status labels use icons beside the stacked values")
    func platformIcons() {
        let plain = StatusLabelRenderer.image(today: "12K", weekly: "80%")
        let codex = StatusLabelRenderer.image(
            platform: .codex,
            today: "12K",
            weekly: "80%")
        let claude = StatusLabelRenderer.image(
            platform: .claude,
            today: "12K",
            weekly: "80%")

        #expect(codex.isTemplate)
        #expect(claude.isTemplate)
        #expect(codex.size.width > plain.size.width)
        #expect(claude.size.width > plain.size.width)
        #expect(codex.size.height == plain.size.height)
        #expect(claude.size.height == plain.size.height)
    }

    @Test("Combined status label routes its two visual regions to matching tabs")
    func combinedHitRegions() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%",
            claudeToday: "8K",
            claudeWeekly: "60%")
        let boundary = layout.claudeBoundaryX

        #expect(layout.image.isTemplate)
        #expect(boundary != nil)
        #expect(layout.scope(at: 0) == .codex)
        #expect(layout.scope(at: (boundary ?? 1) - 0.1) == .codex)
        #expect(layout.scope(at: boundary ?? 0) == .claude)
        #expect(layout.scope(at: layout.image.size.width) == .claude)
    }

    @Test("Codex-only status label has one hit region")
    func codexOnlyHitRegion() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%")

        #expect(layout.claudeBoundaryX == nil)
        #expect(layout.scope(at: layout.image.size.width) == .codex)
    }
}
