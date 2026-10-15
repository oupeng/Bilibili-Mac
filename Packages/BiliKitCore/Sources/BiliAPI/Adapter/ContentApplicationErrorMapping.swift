import BiliApplication

extension BiliAPIError {
    /// 内容类 adapter（内容、观看历史，以及今后的稍后再看与收藏夹）唯一的错误映射：取消原样传播，
    /// `BiliAPIError` 按 `Failure` 分类，其余错误为 `unavailable`。
    static func contentApplicationError(for error: any Error) -> any Error {
        domainError(
            for: error,
            fallback: ContentApplicationError.unavailable,
            ContentApplicationError.init
        )
    }
}

extension ContentApplicationError {
    init(_ failure: BiliAPIError.Failure) {
        self =
            switch failure {
            case .invalidRequest:
                .invalidRequest
            case .authorizationRequired:
                .authenticationRequired
            case .authenticationInvalid:
                .authenticationInvalid
            case .authorizationUnavailable:
                .authenticationUnavailable
            case .transport:
                .transportFailure
            case .unexpectedHTTPStatus:
                .unavailable
            case .restricted:
                .requestRestricted
            case .contentUnavailable:
                .contentUnavailable
            case .rejected(let code):
                .serviceRejected(code: code)
            case .unsupportedMedia:
                .unsupportedMedia
            case .noPlayableMedia:
                .playbackUnavailable
            case .invalidResponse:
                .invalidResponse
            }
    }
}
