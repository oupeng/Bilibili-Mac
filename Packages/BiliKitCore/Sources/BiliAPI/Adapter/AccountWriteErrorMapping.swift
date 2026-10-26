import BiliApplication

/// 账户写入 adapter 把远端失败映射为 `AccountWriteError` 的唯一对应处。
///
/// 规则见 `AccountWriteError`（见 SECURITY-MODEL §3）；各写操作只给出自己接口的业务码含义，其余业务码一律是
/// `rejected(code:)`。无状态。
enum AccountWriteErrorMapping {
    /// 把一次写入失败映射为 `AccountWriteError`，取消原样传播。
    ///
    /// `businessCode` 返回 nil 的业务码按普通业务拒绝显示错误码。
    static func error(
        for error: any Error,
        businessCode: (Int) -> AccountWriteError?
    ) -> any Error {
        BiliAPIError.domainError(for: error, fallback: AccountWriteError.unavailable) { failure in
            switch failure {
            case .invalidRequest:
                .invalidRequest
            case .authorizationRequired:
                .authenticationRequired
            case .authenticationInvalid:
                .authenticationInvalid
            case .authorizationUnavailable:
                .authenticationUnavailable
            case .restricted:
                .restricted
            case .contentUnavailable:
                .contentUnavailable
            case .rejected(let code):
                businessCode(code) ?? .rejected(code: code)
            // 写入可能已经生效，只是拿不到可判定的结果：与网络失败一样提示“暂时无法完成”，不自动重试。
            case .transport, .unexpectedHTTPStatus, .invalidResponse, .unsupportedMedia,
                .noPlayableMedia:
                .unavailable
            }
        }
    }
}
