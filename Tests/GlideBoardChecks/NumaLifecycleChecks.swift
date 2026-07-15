import Foundation
@testable import GlideBoardCore

private final class LoginServiceFake: MainAppServiceProviding {
    var status: MainAppServiceStatus
    var statusAfterRegister: MainAppServiceStatus?
    var registerCount = 0
    var openCount = 0
    var registerError: Error?

    init(_ status: MainAppServiceStatus) { self.status = status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        if let statusAfterRegister { status = statusAfterRegister }
    }

    func openSystemSettings() { openCount += 1 }
}

@MainActor
func numaLifecycleChecks() async {
    let c = Checks.shared
    c.begin("Numa lifecycle")

    await c.test("multiple blockers resume only after the last one leaves") {
        var blockers = WorkspaceLifecycleBlockers()
        try expectTrue(blockers.insert(.sessionInactive))
        try expectFalse(blockers.insert(.sleeping))
        try expectFalse(blockers.remove(.sleeping))
        try expectTrue(blockers.isSuspended)
        try expectTrue(blockers.remove(.sessionInactive))
        try expectFalse(blockers.isSuspended)
    }

    await c.test("enabled login item is not registered twice") {
        let service = LoginServiceFake(.enabled)
        let controller = LaunchAtLoginController(service: service)
        try expectEqual(controller.ensureRegistered(), .enabled)
        try expectEqual(service.registerCount, 0)
    }

    await c.test("not registered is attempted once and re-read truthfully") {
        let service = LoginServiceFake(.notRegistered)
        service.statusAfterRegister = .requiresApproval
        let controller = LaunchAtLoginController(service: service)
        try expectEqual(controller.ensureRegistered(), .requiresApproval)
        try expectEqual(service.registerCount, 1)
        controller.openSystemSettings()
        try expectEqual(service.openCount, 1)
    }

    await c.test("registration errors remain visible") {
        let service = LoginServiceFake(.notRegistered)
        service.registerError = NSError(domain: "login", code: 7,
                                        userInfo: [NSLocalizedDescriptionKey: "denegado"])
        let result = LaunchAtLoginController(service: service).ensureRegistered()
        guard case .unavailable(let message) = result else {
            throw CheckFailure(message: "expected unavailable, got \(result)", location: #fileID)
        }
        try expectTrue(message.contains("denegado"))
    }
}
