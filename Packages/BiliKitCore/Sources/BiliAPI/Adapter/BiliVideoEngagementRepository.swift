import BiliApplication

/// `VideoEngagementRepository` 的 B 站实现：转调窗口主 API 的互动读取与点赞、投币、三连写入，并映射失败。
///
/// 无状态；写入要求底层 client 注入了账户写授权器（`LiveAPIClients.main`）。读取失败经内容域映射；写入的共同映射在
/// `AccountWriteErrorMapping`，这里只给出这几个接口的业务码。取消原样传播。
public struct BiliVideoEngagementRepository: VideoEngagementRepository {
    /// 重复点赞（点赞时）与“取消点赞失败：用户未点赞”（取消时）：服务端已经是目标状态，按成功处理。
    ///
    /// 出处是接口文档与网页端错误码表的交叉核实，未经本项目实测。
    private static let alreadyLikedCode = 65_006
    private static let notLikedCode = 65_004
    /// 投币的业务码：硬币不足、不能给自己投币、投币间隔太短、超过单个稿件投币上限。
    private static let coinsInsufficientCode = -104
    private static let ownVideoCode = 34_002
    private static let coinTooFrequentCode = 34_004
    private static let coinLimitCode = 34_005
    /// 稿件不存在。
    private static let missingVideoCode = 10_003

    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState {
        do {
            return try await client.videoEngagement(bvid: target.bvid)
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }

    public func setLiked(_ isLiked: Bool, target: VideoWriteTarget, accountID: Int64) async throws {
        do {
            try await client.setVideoLiked(isLiked, bvid: target.bvid, accountID: accountID)
        } catch BiliAPIError.apiRejected(let code, _)
            where code == (isLiked ? Self.alreadyLikedCode : Self.notLikedCode)
        {
            return
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> Bool {
        do {
            return try await client.addVideoCoins(
                count,
                alsoLike: alsoLike,
                bvid: target.bvid,
                accountID: accountID
            )
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func triple(
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> VideoTripleOutcome {
        do {
            return try await client.tripleVideo(bvid: target.bvid, accountID: accountID)
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    private static func accountWriteError(for error: any Error) -> any Error {
        AccountWriteErrorMapping.error(for: error) { code in
            switch code {
            case coinsInsufficientCode: .coinsInsufficient
            case ownVideoCode: .ownVideo
            case coinTooFrequentCode: .restricted
            case coinLimitCode: .coinLimitReached
            case missingVideoCode: .contentUnavailable
            default: nil
            }
        }
    }
}
