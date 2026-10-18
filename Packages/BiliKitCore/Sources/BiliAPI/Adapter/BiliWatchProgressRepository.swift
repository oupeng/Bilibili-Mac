import BiliApplication

/// `WatchProgressRepository` 的 B 站实现：转调唯一的写请求（观看进度 heartbeat）并映射为
/// `WatchProgressError`。
///
/// 无状态；进程内只有一个，由 `SerializedWatchProgressRepository` 串行化，
/// 底层是进程级观看进度写入专用的 API client（`ProcessComposition.live`）。
/// 失败只关闭对应的报告会话、不触发账户复核，见 SECURITY-MODEL §3。
public struct BiliWatchProgressRepository: WatchProgressRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func report(_ progress: WatchProgressReport) async throws {
        do {
            try await client.reportWatchProgress(progress)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: WatchProgressError.unavailable,
                Self.map
            )
        }
    }

    private static func map(_ failure: BiliAPIError.Failure) -> WatchProgressError {
        switch failure {
        case .authorizationRequired:
            .authenticationRequired
        case .authenticationInvalid:
            .authenticationInvalid
        case .restricted:
            .requestRestricted
        case .authorizationUnavailable, .transport, .unexpectedHTTPStatus:
            .unavailable
        case .rejected(let code), .contentUnavailable(let code):
            .serviceRejected(code: code)
        case .invalidRequest, .unsupportedMedia, .noPlayableMedia,
            .invalidResponse:
            .invalidResponse
        }
    }
}
