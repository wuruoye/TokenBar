import Foundation
import ServiceManagement
import Testing
@testable import TokenBar

@MainActor
@Suite("Login item controller")
struct LoginItemControllerTests {
    @Test("reads the current system status")
    func readsCurrentStatus() {
        let service = TestLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        #expect(controller.isEnabled)
        #expect(controller.isAvailable)
        #expect(!controller.requiresApproval)
        #expect(controller.detail == "TokenBar opens automatically after you sign in.")
    }

    @Test("registers the app as a login item")
    func registers() {
        let service = TestLoginItemService(
            status: .notRegistered,
            statusAfterRegister: .enabled)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCount == 1)
        #expect(service.unregisterCount == 0)
        #expect(controller.isEnabled)
        #expect(controller.errorMessage == nil)
    }

    @Test("shows approval guidance and unregisters a pending login item")
    func approvalAndUnregister() {
        let service = TestLoginItemService(
            status: .notRegistered,
            statusAfterRegister: .requiresApproval)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        controller.openSystemSettings()

        #expect(controller.isEnabled)
        #expect(controller.requiresApproval)
        #expect(service.openSystemSettingsCount == 1)

        controller.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
    }

    @Test("restores the system status and reports registration errors")
    func registrationError() {
        let service = TestLoginItemService(status: .notRegistered)
        service.registerError = .registrationFailed
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(!controller.isEnabled)
        #expect(
            controller.errorMessage
                == "Could not enable launch at login: Registration failed.")

        service.registerError = nil
        service.status = .enabled
        controller.refresh()

        #expect(controller.isEnabled)
        #expect(controller.errorMessage == nil)
    }

    @Test("disables the control when the app installation is unavailable")
    func unavailableInstallation() {
        let service = TestLoginItemService(status: .unavailable)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(!controller.isAvailable)
        #expect(!controller.isEnabled)
        #expect(service.registerCount == 0)
    }

    @Test("treats a packaged main app as retryable when the system loses its service record")
    func packagedAppRecovery() {
        #expect(
            SystemLoginItemService.map(
                status: SMAppService.Status.notFound,
                runsFromAppBundle: true) == .notRegistered)
        #expect(
            SystemLoginItemService.map(
                status: SMAppService.Status.notFound,
                runsFromAppBundle: false) == .unavailable)
    }
}

@MainActor
private final class TestLoginItemService: LoginItemServicing {
    var status: LoginItemServiceStatus
    var statusAfterRegister: LoginItemServiceStatus
    var registerError: TestLoginItemError?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSystemSettingsCount = 0

    init(
        status: LoginItemServiceStatus,
        statusAfterRegister: LoginItemServiceStatus = .enabled)
    {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
    }

    func register() throws {
        self.registerCount += 1
        if let registerError = self.registerError {
            throw registerError
        }
        self.status = self.statusAfterRegister
    }

    func unregister() throws {
        self.unregisterCount += 1
        self.status = .notRegistered
    }

    func openSystemSettings() {
        self.openSystemSettingsCount += 1
    }
}

private enum TestLoginItemError: LocalizedError {
    case registrationFailed

    var errorDescription: String? {
        "Registration failed."
    }
}
