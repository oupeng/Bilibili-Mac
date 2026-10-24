import Foundation

/// 进程级的账户写入效果集线器：把一个窗口确认成功的写入效果转给其他已打开的窗口。
///
/// 由 `ProcessComposition` 持有、随进程存活。拥有已打开窗口的效果路由登记表：窗口 `open()` 时登记、`close()` 时注销，
/// 注销后不再收到效果；登记期间强引用路由（路由只引用窗口模型，窗口关闭时一并释放）。不判断效果属于哪个账户：
/// 各窗口的路由按自己的账户与会话代次取舍。只在主线程使用，不持有 Task，不排队、不持久化效果。
@MainActor
final class AccountWriteEffectHub {
    private var routers: [UUID: AccountWriteEffectRouter] = [:]

    func register(_ router: AccountWriteEffectRouter) -> UUID {
        let registrationID = UUID()
        routers[registrationID] = router
        return registrationID
    }

    func unregister(_ registrationID: UUID) {
        routers[registrationID] = nil
    }

    /// 转给除 `origin`（发起写入的窗口的路由，它已在本窗口内处理过）以外的全部已登记窗口。
    func publish(_ delivery: AccountWriteEffectDelivery, excluding origin: AccountWriteEffectRouter) {
        for router in routers.values where router !== origin {
            router.apply(delivery, appliedLocally: false)
        }
    }
}
