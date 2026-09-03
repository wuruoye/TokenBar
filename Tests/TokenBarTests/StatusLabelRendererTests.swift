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
        let grok = StatusLabelRenderer.image(
            platform: .grok,
            today: "12K",
            weekly: "80%")
        let antigravity = StatusLabelRenderer.image(
            platform: .antigravity,
            today: "12K",
            weekly: "80%")

        #expect(codex.isTemplate)
        #expect(claude.isTemplate)
        #expect(grok.isTemplate)
        #expect(antigravity.isTemplate)
        #expect(codex.size.width > plain.size.width)
        #expect(claude.size.width > plain.size.width)
        #expect(grok.size.width > plain.size.width)
        #expect(antigravity.size.width > plain.size.width)
        #expect(codex.size.height == plain.size.height)
        #expect(claude.size.height == plain.size.height)
        #expect(grok.size.height == plain.size.height)
        #expect(antigravity.size.height == plain.size.height)
    }

    @Test("Combined status label routes all visual regions to matching tabs")
    func combinedHitRegions() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%",
            claudeToday: "8K",
            claudeWeekly: "60%",
            grokToday: "4K",
            grokWeekly: "40%",
            antigravityToday: "2K",
            antigravityWeekly: "—")
        let claudeStart = layout.regions[1].startX
        let grokStart = layout.regions[2].startX
        let antigravityStart = layout.regions[3].startX

        #expect(layout.image.isTemplate)
        #expect(layout.regions.map(\.scope) == [.codex, .claude, .grok, .antigravity])
        #expect(layout.scope(at: 0) == .codex)
        #expect(layout.scope(at: claudeStart - 0.1) == .codex)
        #expect(layout.scope(at: claudeStart) == .claude)
        #expect(layout.scope(at: grokStart - 0.1) == .claude)
        #expect(layout.scope(at: grokStart) == .grok)
        #expect(layout.scope(at: antigravityStart - 0.1) == .grok)
        #expect(layout.scope(at: antigravityStart) == .antigravity)
        #expect(layout.scope(at: layout.image.size.width) == .antigravity)
    }

    @Test("Codex-only status label has one hit region")
    func codexOnlyHitRegion() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%")

        #expect(layout.regions.map(\.scope) == [.codex])
        #expect(layout.scope(at: layout.image.size.width) == .codex)
    }

    @Test("Grok remains clickable when Claude is hidden")
    func codexAndGrokHitRegions() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%",
            grokToday: "4K",
            grokWeekly: "40%")

        #expect(layout.regions.map(\.scope) == [.codex, .grok])
        #expect(layout.scope(at: layout.regions[1].startX) == .grok)
    }
}
