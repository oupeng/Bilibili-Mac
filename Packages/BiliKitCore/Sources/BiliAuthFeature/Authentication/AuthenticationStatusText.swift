import BiliApplication
import Foundation

/// 账号 sheet 各状态的标题、失败说明与读屏通告，界面与通告共用同一份文案。
enum AuthenticationStatusText {
    static func title(for state: AuthenticationState) -> String {
        switch state {
        case .signedOut: AuthFeatureStrings.localized("尚未登录")
        case .restoring: AuthFeatureStrings.localized("正在检查本机登录状态…")
        case .requestingQRCode: AuthFeatureStrings.localized("正在获取登录二维码…")
        case .awaitingScan: AuthFeatureStrings.localized("请扫码登录")
        case .awaitingConfirmation: AuthFeatureStrings.localized("请在手机上确认")
        case .finalizing: AuthFeatureStrings.localized("正在验证并安全保存登录状态…")
        case .signedIn: AuthFeatureStrings.localized("已登录")
        case .signingOut: AuthFeatureStrings.localized("正在清除本机登录状态…")
        case .expired: AuthFeatureStrings.localized("二维码已过期")
        case .failed: AuthFeatureStrings.localized("登录未完成")
        }
    }

    static func detail(for failure: AuthenticationFailure) -> String {
        switch failure {
        case .network:
            AuthFeatureStrings.localized("网络暂时不可用，请稍后重试。")
        case .serviceUnavailable:
            AuthFeatureStrings.localized("登录服务未接受本次请求，请重新扫码。")
        case .invalidResponse:
            AuthFeatureStrings.localized("登录协议返回了无法安全处理的数据。")
        case .credentialUnavailable:
            AuthFeatureStrings.localized("无法访问本机 Keychain；请解锁 Mac 后重试。")
        }
    }

    /// 进入这个状态时要通告给读屏的一句话；为 nil 时不通告。
    ///
    /// sheet 的内容整块替换，原来的焦点按钮随之消失，扫码确认、过期与恢复结果又由手机或网络推动，读屏用户
    /// 不会自己发现内容变了，所以每个落定的状态都报它的标题，失败连同原因。进度态不报：它们在一次请求内
    /// 就会被结果取代，报了只会被下一条打断。
    static func announcement(for state: AuthenticationState) -> String? {
        switch state {
        case .restoring, .requestingQRCode, .finalizing, .signingOut:
            nil
        case .failed(let failure):
            AuthFeatureStrings.localized("登录未完成：\(detail(for: failure))")
        case .signedOut, .awaitingScan, .awaitingConfirmation, .signedIn, .expired:
            title(for: state)
        }
    }
}
