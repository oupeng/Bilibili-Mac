import BiliApplication
import BiliUI
import Testing

/// 登录门槛只按账户呈现状态选择形态：暂时无法确认与确定登出是两种不同的门槛。
struct AccountGatePhaseTests {
    @Test(arguments: [
        (AccountPresentationState.signedIn(nil), AccountGatePhase.content),
        (.signedOut, .signIn),
        (.resolving, .progress),
        (.unavailable, .unavailable)
    ])
    func eachAccountStateMapsToOneGatePhase(
        state: AccountPresentationState,
        phase: AccountGatePhase
    ) {
        #expect(AccountGatePhase(state) == phase)
    }
}
