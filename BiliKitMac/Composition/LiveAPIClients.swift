import BiliAPI
import BiliAuth
import BiliNetworking
import Foundation

/// 生产 `BiliAPIClient` 的唯一构造处与账户读取 allowlist 的唯一声明处，按角色给出 client：窗口主 API、线路测速、
/// 观看进度 writer。
///
/// 每个 client 自有一个无凭据 ephemeral transport 工厂，授权器只按这里声明的 allowlist 放行账户读取；唯一的写能力
/// （观看进度 heartbeat）只在 `watchProgressWriter()` 打开。调用方不能自选 allowlist 或写能力。见 SECURITY-MODEL §3。
enum LiveAPIClients {
    // 三组 allowlist 只引用 endpoint 导出的 path 常量（`BiliAccountReadPath`、会话校验的
    // `BiliAuthenticationService.sessionValidationPath`），不另写字面量；哪组放行哪些 path 是这里的决定。
    // 见 SECURITY-MODEL §3。
    static let accountSessionValidationAllowedPaths: Set<String> = [
        BiliAuthenticationService.sessionValidationPath
    ]

    static let mainAccountReadAllowedPaths: Set<String> = [
        BiliAccountReadPath.playURL,
        BiliAccountReadPath.subtitleCatalog,
        BiliAccountReadPath.uploaderVideos,
        BiliAccountReadPath.danmakuSegment,
        BiliAccountReadPath.commentReplies,
        BiliAccountReadPath.rootComments,
        BiliAccountReadPath.relatedVideos,
        BiliAccountReadPath.uploaderCard,
        BiliAccountReadPath.watchHistory,
        BiliAccountReadPath.watchLater,
        BiliAccountReadPath.favoriteFolders,
        BiliAccountReadPath.favoriteFolderContent,
        BiliAccountReadPath.popular,
        BiliAccountReadPath.recommendations,
        BiliAccountReadPath.videoSearch,
        BiliAccountReadPath.videoDetail
    ]

    static let cdnBenchmarkAccountReadAllowedPaths: Set<String> = [
        BiliAccountReadPath.playURL,
        BiliAccountReadPath.videoDetail
    ]

    static let watchProgressAccountReadAllowedPaths: Set<String>? = nil

    /// 窗口主 API：内容、播放、评论、弹幕、观看历史、稍后再看与收藏夹的读取。
    ///
    /// `isConfirmedSignedOut` 只给它：已确认未登录时 Keychain 不可用不影响游客浏览。
    static func main(isConfirmedSignedOut: @escaping @Sendable () -> Bool) -> BiliAPIClient {
        make(
            accountReadAllowedPaths: mainAccountReadAllowedPaths,
            historyWriteEnabled: false,
            isConfirmedSignedOut: isConfirmedSignedOut
        )
    }

    /// 线路测速：只读样本的详情与 playurl。
    static func cdnBenchmark() -> BiliAPIClient {
        make(
            accountReadAllowedPaths: cdnBenchmarkAccountReadAllowedPaths,
            historyWriteEnabled: false,
            isConfirmedSignedOut: { false }
        )
    }

    /// 进程唯一的观看进度 writer：不做账户读取，只开 heartbeat 写授权。
    static func watchProgressWriter() -> BiliAPIClient {
        make(
            accountReadAllowedPaths: watchProgressAccountReadAllowedPaths,
            historyWriteEnabled: true,
            isConfirmedSignedOut: { false }
        )
    }

    private static func make(
        accountReadAllowedPaths: Set<String>?,
        historyWriteEnabled: Bool,
        isConfirmedSignedOut: @escaping @Sendable () -> Bool
    ) -> BiliAPIClient {
        let requestAuthorizer = accountReadAllowedPaths.map {
            BiliCredentialRequestAuthorizer(
                allowedPaths: $0,
                isConfirmedSignedOut: isConfirmedSignedOut
            )
        }
        let historyWriteAuthorizer: (any HTTPRequestAuthorizing)? =
            historyWriteEnabled ? BiliPlaybackHeartbeatRequestAuthorizer() : nil
        let transportFactory: @Sendable () -> any HTTPTransport = {
            URLSessionTransport(configuration: .credentialFreeEphemeral())
        }
        return BiliAPIClient(
            requestAuthorizer: requestAuthorizer,
            historyWriteAuthorizer: historyWriteAuthorizer,
            transportFactory: transportFactory
        )
    }
}
