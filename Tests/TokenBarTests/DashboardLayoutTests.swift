import Testing
@testable import TokenBar

@MainActor
@Suite("Dashboard layout")
struct DashboardLayoutTests {
    @Test("quota height follows the rows returned by the provider")
    func quotaHeightFollowsAvailableRows() {
        let weeklyOnly = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: false,
            hasResetCredits: false)
        let weeklyAndFiveHour = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: true,
            hasResetCredits: false)
        let weeklyAndResetCredits = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: false,
            hasResetCredits: true)
        let allRows = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: true,
            hasResetCredits: true)

        #expect(weeklyOnly < weeklyAndFiveHour)
        #expect(weeklyOnly < weeklyAndResetCredits)
        #expect(weeklyAndFiveHour < allRows)
        #expect(weeklyAndResetCredits < allRows)
    }

    @Test("single-platform header omits the selector height")
    func compactSinglePlatformHeader() {
        #expect(
            DashboardOverviewView.headerHeight(showsClaude: false)
                == DashboardOverviewView.compactHeaderHeight)
        #expect(
            DashboardOverviewView.headerHeight(showsClaude: false)
                < DashboardOverviewView.headerHeight(showsClaude: true))
    }
}
