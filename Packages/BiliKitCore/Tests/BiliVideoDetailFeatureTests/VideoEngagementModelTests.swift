import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播放页互动状态：有可写入账户时按展示的视频读取，没有时不读、按钮不可用；换视频先丢掉旧状态；点赞乐观改动与计数，
/// 回滚只放回同一次状态；投币与三连按结果增加；重读发现别处的改动时计数随之增减；凭据失败只自动复核重读一次。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VideoEngagementModelTests {
    @Test
    func presentingAVideoReadsItsEngagementOnlyWithAnAccount() async {
        let repository = EngagementRepositoryStub()
        let account = MutableAccount()
        let model = makeModel(repository: repository, account: account)

        model.present(detail("BV17x411w7KC"))
        #expect(model.phase == .unavailable)
        #expect(model.likeCount == 100)

        account.id = 7
        model.present(detail("BV17x411w7KC"))
        await model.waitForCurrentTask()

        #expect(
            model.engagement
                == VideoEngagementState(isLiked: false, coinCount: 1, isFavorited: false)
        )
        #expect(model.remainingCoins == 1)
        #expect(await repository.reads == ["BV17x411w7KC"])
    }

    @Test
    func anotherVideoDropsTheOldStateBeforeReading() async {
        let repository = EngagementRepositoryStub()
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail("BV17x411w7KC"))
        await model.waitForCurrentTask()

        model.present(detail("BV1xx411c7mD"))

        #expect(model.phase == .loading)
        #expect(model.bvid == "BV1xx411c7mD")
    }

    @Test
    func likeIsOptimisticAndRollsBackToTheSameState() async throws {
        let model = makeModel(
            repository: EngagementRepositoryStub(),
            account: MutableAccount(id: 7)
        )
        model.present(detail("BV17x411w7KC"))
        await model.waitForCurrentTask()

        let snapshot = try #require(model.applyLike(true, bvid: "BV17x411w7KC"))
        #expect(model.engagement?.isLiked == true)
        #expect(model.likeCount == 101)
        #expect(model.applyLike(true, bvid: "BV17x411w7KC") == nil)
        #expect(model.applyLike(false, bvid: "BV1xx411c7mD") == nil)

        model.restore(snapshot)
        #expect(model.engagement?.isLiked == false)
        #expect(model.likeCount == 100)
    }

    /// 写入之后重读成功过：回滚不再放回，重读的结果已是服务端此刻的状态。
    @Test
    func rollbackAfterAReloadIsDropped() async throws {
        let repository = EngagementRepositoryStub()
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail("BV17x411w7KC"))
        await model.waitForCurrentTask()
        let snapshot = try #require(model.applyLike(true, bvid: "BV17x411w7KC"))
        await repository.setState(
            VideoEngagementState(isLiked: true, coinCount: 1, isFavorited: false)
        )

        model.reload()
        await model.waitForCurrentTask()
        model.restore(snapshot)

        #expect(model.engagement?.isLiked == true)
        #expect(model.likeCount == 101)
    }

    @Test
    func coinsAndTripleAddTheirResults() async {
        let model = makeModel(
            repository: EngagementRepositoryStub(),
            account: MutableAccount(id: 7)
        )
        model.present(detail("BV17x411w7KC"))
        await model.waitForCurrentTask()

        model.applyCoins(1, alsoLiked: true, bvid: "BV17x411w7KC")
        #expect(
            model.engagement
                == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: false)
        )
        #expect(model.coinCount == 21)
        #expect(model.likeCount == 101)
        #expect(model.remainingCoins == 0)

        model.applyTriple(
            VideoTripleOutcome(isLiked: true, isCoined: true, isFavorited: true, addedCoinCount: 0),
            bvid: "BV17x411w7KC"
        )
        #expect(
            model.engagement == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: true)
        )
        #expect(model.favoriteCount == 31)
        #expect(model.likeCount == 101)
        #expect(model.coinCount == 21)
    }

    /// 别处的写入（另一窗口点赞、「收藏到…」）后重读：计数随状态的变化增减。
    @Test
    func reloadCarriesChangesMadeElsewhereIntoTheCounts() async {
        let repository = EngagementRepositoryStub()
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail("BV17x411w7KC"))
        await model.waitForCurrentTask()
        await repository.setState(
            VideoEngagementState(isLiked: true, coinCount: 1, isFavorited: true)
        )

        model.markNeedsReload(bvid: "BV1xx411c7mD")
        model.markNeedsReload(bvid: "BV17x411w7KC")
        await model.waitForCurrentTask()

        #expect(model.likeCount == 101)
        #expect(model.favoriteCount == 31)
        #expect(await repository.reads.count == 2)
    }

    @Test
    func credentialFailureRequestsOneRevalidationReload() async {
        let repository = EngagementRepositoryStub(failure: .authenticationInvalid)
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail("BV17x411w7KC"))
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 1)

        model.authenticationRevalidationSucceeded()
        await model.waitForCurrentTask()
        model.authenticationRevalidationSucceeded()
        await model.waitForCurrentTask()

        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(await repository.reads.count == 2)
        #expect(model.phase == .failed(.authenticationInvalid))
    }

    private func makeModel(
        repository: EngagementRepositoryStub,
        account: MutableAccount
    ) -> VideoEngagementModel {
        VideoEngagementModel(
            useCase: VideoEngagementUseCase(repository: repository),
            accountID: { account.id }
        )
    }

    private func detail(_ bvid: String) -> VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "标题",
            summary: "",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            statistics: VideoStatistics(viewCount: 1_000, danmakuCount: 10, likeCount: 100),
            durationSeconds: 60,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engagementSummary: VideoEngagementSummary(
                coinCount: 20,
                favoriteCount: 30,
                isReposted: false
            )
        )
    }
}

/// 测试里可变的写入账户；闭包在主线程读取。
@MainActor
private final class MutableAccount {
    var id: Int64?

    init(id: Int64? = nil) {
        self.id = id
    }
}

/// 本 target 唯一的 `VideoEngagementRepository` 替身：读取返回可替换的状态（或固定失败）并记录；写入不在这里测试。
private actor EngagementRepositoryStub: VideoEngagementRepository {
    private var state = VideoEngagementState(isLiked: false, coinCount: 1, isFavorited: false)
    private let failure: ContentApplicationError?
    private(set) var reads: [String] = []

    init(failure: ContentApplicationError? = nil) {
        self.failure = failure
    }

    func setState(_ state: VideoEngagementState) {
        self.state = state
    }

    func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState {
        reads.append(target.bvid)
        if let failure { throw failure }
        return state
    }

    func setLiked(_ isLiked: Bool, target: VideoWriteTarget, accountID: Int64) async throws {}

    func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> Bool { alsoLike }

    func triple(target: VideoWriteTarget, accountID: Int64) async throws -> VideoTripleOutcome {
        VideoTripleOutcome(isLiked: true, isCoined: true, isFavorited: true, addedCoinCount: 2)
    }
}
