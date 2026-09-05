import Foundation
import Observation
import ServiceManagement

enum LoginItemServiceStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable

    var isEnabled: Bool {
        switch self {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .unavailable:
            false
        }
    }
}

@MainActor
protocol LoginItemServicing: AnyObject {
    var status: LoginItemServiceStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLoginItemService: LoginItemServicing {
    private let service: SMAppService
    private let runsFromAppBundle: Bool

    init(
        service: SMAppService = .mainApp,
        bundle: Bundle = .main)
    {
        self.service = service
        self.runsFromAppBundle = Self.runsFromAppBundle(bundle)
    }

    var status: LoginItemServiceStatus {
        Self.map(
            status: self.service.status,
            runsFromAppBundle: self.runsFromAppBundle)
    }

    static func map(
        status: SMAppService.Status,
        runsFromAppBundle: Bool) -> LoginItemServiceStatus
    {
        switch status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            runsFromAppBundle ? .notRegistered : .unavailable
        @unknown default:
            .unavailable
        }
    }

    static func runsFromAppBundle(_ bundle: Bundle) -> Bool {
        guard bundle.bundleURL.pathExtension.lowercased() == "app",
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executableURL = bundle.executableURL,
              let executableName = bundle.object(
                  forInfoDictionaryKey: "CFBundleExecutable") as? String
        else {
            return false
        }

        let expectedExecutableURL = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        return executableURL.standardizedFileURL == expectedExecutableURL.standardizedFileURL
    }

    func register() throws {
        try self.service.register()
    }

    func unregister() throws {
        try self.service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
@Observable
final class LoginItemController {
    static let shared = LoginItemController()

    private(set) var status: LoginItemServiceStatus
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LoginItemServicing

    init(service: any LoginItemServicing = SystemLoginItemService()) {
        self.service = service
        self.status = service.status
    }

    var isEnabled: Bool {
        self.status.isEnabled
    }

    var isAvailable: Bool {
        self.status != .unavailable
    }

    var requiresApproval: Bool {
        self.status == .requiresApproval
    }

    var detail: String {
        switch self.status {
        case .notRegistered:
            "TokenBar opens only when you launch it."
        case .enabled:
            "TokenBar opens automatically after you sign in."
        case .requiresApproval:
            "Approve TokenBar in System Settings to finish enabling this login item."
        case .unavailable:
            "Open the packaged TokenBar.app to configure launch at login."
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        self.errorMessage = nil
        self.status = self.service.status
        guard self.isAvailable, isEnabled != self.status.isEnabled else { return }

        do {
            if isEnabled {
                try self.service.register()
            } else {
                try self.service.unregister()
            }
            self.status = self.service.status
        } catch {
            self.status = self.service.status
            let action = isEnabled ? "enable" : "disable"
            self.errorMessage = "Could not \(action) launch at login: \(error.localizedDescription)"
        }
    }

    func refresh() {
        self.status = self.service.status
        self.errorMessage = nil
    }

    func openSystemSettings() {
        self.service.openSystemSettings()
    }
}
