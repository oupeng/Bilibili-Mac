import BiliApplication

/// `WatchLaterWriteRepository` 的 B 站实现：转调窗口主 API 的稍后再看写入，并把远端失败映射为 `AccountWriteError`。
///
/// 无状态；底层 client 必须注入了账户写授权器（`LiveAPIClients.main`），否则一律按“需要登录”失败。取消原样传播。
/// 映射规则见 `AccountWriteError`，这里是唯一的对应处，见 SECURITY-MODEL §3。
public struct BiliWatchLaterWriteRepository: WatchLaterWriteRepository {
    /// 付费稿件，不能加入稍后再看。
    ///
    /// 这几个业务码的出处是第三方接口文档与网页端错误码表的交叉核实，未经本项目实测。
    private static let paidContentCode = 90_000
    /// 稍后再看已满（“塞满啦”）。
    private static let listFullCode = 90_001
    /// 稿件已被删除。
    private static let deletedCode = 90_003
    // 90002 没有专门映射：只有一个第三方客户端把它当作“移除时不在列表里”并视为成功，接口文档与错误码表都没有收录，
    // 含义未经证实。按普通业务拒绝显示错误码，不当作成功：含义不符时当作成功会让乐观移除掩盖真实的失败。

    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func add(_ target: VideoWriteTarget, accountID: Int64) async throws {
        do {
            try await client.addToWatchLater(bvid: target.bvid, accountID: accountID)
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func remove(_ target: VideoWriteTarget, accountID: Int64) async throws {
        do {
            try await client.removeFromWatchLater(bvid: target.bvid, accountID: accountID)
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    static func accountWriteError(for error: any Error) -> any Error {
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
            case .rejected(let code) where code == paidContentCode:
                .unsupportedContent
            case .rejected(let code) where code == listFullCode:
                .listFull
            case .rejected(let code) where code == deletedCode:
                .contentUnavailable
            case .contentUnavailable:
                .contentUnavailable
            case .rejected(let code):
                .rejected(code: code)
            // 写入可能已经生效，只是拿不到可判定的结果：与网络失败一样提示“暂时无法完成”，不自动重试。
            case .transport, .unexpectedHTTPStatus, .invalidResponse, .unsupportedMedia,
                .noPlayableMedia:
                .unavailable
            }
        }
    }
}
