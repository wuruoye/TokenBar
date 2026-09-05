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

        #expect(weeklyOnly == 79)
        #expect(weeklyAndFiveHour - weeklyOnly == 54)
        #expect(weeklyOnly < weeklyAndFiveHour)
        #expect(weeklyOnly < weeklyAndResetCredits)
        #expect(weeklyAndFiveHour < allRows)
        #expect(weeklyAndResetCredits < allRows)
    }

    @Test("single-platform header omits the selector height")
    func compactSinglePlatformHeader() {
        #expect(
            DashboardOverviewView.headerHeight(
                showsClaude: false,
                showsGrok: false,
                showsAntigravity: false)
                == DashboardOverviewView.compactHeaderHeight)
        #expect(
            DashboardOverviewView.headerHeight(
                showsClaude: false,
                showsGrok: false,
                showsAntigravity: false)
                < DashboardOverviewView.headerHeight(
                    showsClaude: true,
                    showsGrok: false,
                    showsAntigravity: false))
        #expect(
            DashboardOverviewView.headerHeight(
                showsClaude: false,
                showsGrok: false,
                showsAntigravity: false)
                < DashboardOverviewView.headerHeight(
                    showsClaude: false,
                    showsGrok: false,
                    showsAntigravity: true))
    }
}
