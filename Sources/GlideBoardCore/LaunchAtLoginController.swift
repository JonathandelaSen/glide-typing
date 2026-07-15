import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case unavailable(String)
}

enum MainAppServiceStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

protocol MainAppServiceProviding: AnyObject {
    var status: MainAppServiceStatus { get }
    func register() throws
    func openSystemSettings()
}

@available(macOS 13.0, *)
private final class SystemMainAppService: MainAppServiceProviding {
    private let service = SMAppService.mainApp

    var status: MainAppServiceStatus {
        switch service.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class LaunchAtLoginController {
    private let service: MainAppServiceProviding

    convenience init() {
        self.init(service: SystemMainAppService())
    }

    init(service: MainAppServiceProviding) {
        self.service = service
    }

    func ensureRegistered() -> LaunchAtLoginState {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable("macOS no encuentra la app principal para inicio automático")
        case .notRegistered:
            do {
                try service.register()
            } catch {
                return .unavailable(error.localizedDescription)
            }
            return map(service.status)
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func map(_ status: MainAppServiceStatus) -> LaunchAtLoginState {
        switch status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable("macOS no encuentra la app principal para inicio automático")
        }
    }
}
