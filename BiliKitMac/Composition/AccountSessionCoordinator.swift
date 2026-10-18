import BiliApplication
import BiliAuthFeature
import Foundation
import Observation

/// 进程内所有窗口共享的账户会话：已发布的账户范围与代次，以及登出、换号、凭据失效时要一并失效的会话注册表。
///
/// 由 `ProcessComposition` 持有、随进程存活。窗口 open 时登记自己的 API transport、close 时注销；进程级的测速
/// client 与观看进度 writer 在进程组装时登记，不注销。范围只由窗口发布（`publish`），代次在范围真正变化时递增，
/// 其他窗口据此复核。
@MainActor
@Observable
final class AccountSessionCoordinator: AuthenticatedSessionInvalidating {
    private(set) var generation: UInt64 = 0
    private(set) var scope = AccountSessionScope.unresolved
    @ObservationIgnored
    private var sessionInvalidators: [UUID: any AuthenticatedSessionInvalidating] = [:]

    func publish(_ scope: AccountSessionScope) {
        guard scope != .unresolved, scope != self.scope else { return }
        self.scope = scope
        generation &+= 1
    }

    func registerSessionInvalidator(
        _ invalidator: any AuthenticatedSessionInvalidating
    ) -> UUID {
        let registrationID = UUID()
        sessionInvalidators[registrationID] = invalidator
        return registrationID
    }

    func unregisterSessionInvalidator(_ registrationID: UUID) {
        sessionInvalidators[registrationID] = nil
    }

    func invalidateAuthenticatedSession() async {
        let invalidators = Array(sessionInvalidators.values)
        await withTaskGroup(of: Void.self) { group in
            for invalidator in invalidators {
                group.addTask {
                    await invalidator.invalidateAuthenticatedSession()
                }
            }
        }
    }
}

/// 一个窗口的 API transport 在账户会话里的登记：窗口打开时登记、关闭时注销，登出与换号时随会话一起失效。
///
/// 由窗口 adapter 的 `open`／`close` 调用（`WindowAdapters.live`），各只生效一次；弱引用账户会话，不延长它。
@MainActor
final class WindowSessionRegistration {
    private weak var coordinator: AccountSessionCoordinator?
    private let invalidator: any AuthenticatedSessionInvalidating
    private var registrationID: UUID?

    init(
        coordinator: AccountSessionCoordinator,
        invalidator: any AuthenticatedSessionInvalidating
    ) {
        self.coordinator = coordinator
        self.invalidator = invalidator
    }

    func open() {
        guard registrationID == nil, let coordinator else { return }
        registrationID = coordinator.registerSessionInvalidator(invalidator)
    }

    func close() {
        guard let registrationID else { return }
        coordinator?.unregisterSessionInvalidator(registrationID)
        self.registrationID = nil
    }
}
