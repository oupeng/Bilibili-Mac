import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct UploaderSpaceViewModelTests {
    private let owner = VideoOwner(id: 10_001, name: "作者")
    private let anotherOwner = VideoOwner(id: 10_002, name: "另一位作者")

    @Test
    func openLoadsFirstPageOfNewest() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)

        model.open(owner: owner)
        #expect(model.state == .loading(page: 1))
        await waitForLoaded(model, page: 1)

        #expect(model.owner == owner)
        #expect(model.pageCount == 3)
        #expect(model.totalCount == 61)
        #expect(await repository.calls == [.init(ownerID: 10_001, order: .newest, page: 1)])
    }

    @Test
    func reopeningTheSameOwnerKeepsCurrentPage() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        await waitForLoaded(model, page: 2)

        model.open(owner: owner)

        #expect(model.currentPage == 2)
        #expect(await repository.calls.count == 2)
    }

    @Test
    func openingAnotherOwnerResetsOrderAndPage() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.setOrder(.mostPlayed)
        await waitForLoaded(model, page: 1)
        model.showPage(3)
        await waitForLoaded(model, page: 3)

        model.open(owner: anotherOwner)
        await waitForLoaded(model, page: 1)

        #expect(model.order == .newest)
        #expect(await repository.calls.last == .init(ownerID: 10_002, order: .newest, page: 1))
    }

    @Test
    func changingOrderReturnsToFirstPage() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        await waitForLoaded(model, page: 2)

        model.setOrder(.mostFavorited)
        await waitForLoaded(model, page: 1)

        #expect(
            await repository.calls.last == .init(ownerID: 10_001, order: .mostFavorited, page: 1)
        )
    }

    @Test(arguments: [0, 4, 1])
    func pagesOutOfRangeOrAlreadyShownSendNothing(page: Int) async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)

        model.showPage(page)

        #expect(model.currentPage == 1)
        #expect(await repository.calls.count == 1)
    }

    @Test
    func pageCountStaysWhileTheNextPageLoadsAndAfterItFails() async {
        let repository = UploaderVideoRepositoryStub(failingPages: [2: .transportFailure])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)

        model.showPage(2)
        #expect(model.state == .loading(page: 2))
        #expect(model.pageCount == 3)
        await waitForObservedState { model.state == .failed(page: 2, error: .transportFailure) }

        #expect(model.pageCount == 3)
        #expect(model.totalCount == 61)
    }

    @Test
    func failedPageRetriesTheSamePage() async {
        let repository = UploaderVideoRepositoryStub(failingPages: [2: .transportFailure])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        await waitForObservedState { model.state == .failed(page: 2, error: .transportFailure) }
        await repository.setFailure(nil, page: 2)

        model.reload()
        await waitForLoaded(model, page: 2)

        #expect(await repository.calls.map(\.page) == [1, 2, 2])
    }

    @Test
    func missingLoginAsksForSignInWithoutRevalidation() async {
        let repository = UploaderVideoRepositoryStub(failingPages: [1: .authenticationRequired])
        let model = makeModel(repository)

        model.open(owner: owner)
        await waitForObservedState { model.state != .loading(page: 1) }

        #expect(model.requiresAuthentication)
        #expect(model.authenticationRevalidationGeneration == 0)
    }

    @Test
    func expiredLoginRequestsRevalidation() async {
        let repository = UploaderVideoRepositoryStub(failingPages: [1: .authenticationInvalid])
        let model = makeModel(repository)

        model.open(owner: owner)
        await waitForObservedState { model.state != .loading(page: 1) }

        #expect(!model.requiresAuthentication)
        #expect(model.authenticationRevalidationGeneration == 1)
    }

    @Test
    func lateResultOfASupersededPageIsDiscarded() async throws {
        let gate = TestGate()
        let repository = UploaderVideoRepositoryStub(gate: gate, gatedPages: [2])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)

        model.showPage(2)
        try await gate.waitForEntries()
        model.showPage(3)
        try await gate.waitForCancellations()
        await waitForLoaded(model, page: 3)
        await gate.open()
        await repository.waitForCompletions(3)

        #expect(model.currentPage == 3)
    }

    @Test
    func closeCancelsTheRequestAndIgnoresItsLateResult() async throws {
        let gate = TestGate()
        let repository = UploaderVideoRepositoryStub(gate: gate, gatedPages: [1])
        let model = makeModel(repository)

        model.open(owner: owner)
        try await gate.waitForEntries()
        model.close()
        try await gate.waitForCancellations()
        await gate.open()
        await repository.waitForCompletions(1)

        #expect(model.state == .closed)
        #expect(model.owner == nil)
        #expect(model.pageCount == 1)
    }

    @Test
    func emptySpaceLoadsAnEmptyFirstPage() async {
        let repository = UploaderVideoRepositoryStub(totalCount: 0)
        let model = makeModel(repository)

        model.open(owner: owner)
        await waitForObservedState { model.state != .loading(page: 1) }

        guard case .loaded(let page) = model.state else {
            Issue.record("expected a loaded empty page, got \(model.state)")
            return
        }
        #expect(page.videos.isEmpty)
        #expect(model.pageCount == 1)
    }

    private func makeModel(_ repository: UploaderVideoRepositoryStub) -> UploaderSpaceViewModel {
        UploaderSpaceViewModel(useCase: UploaderVideoUseCase(repository: repository))
    }

    private func waitForLoaded(_ model: UploaderSpaceViewModel, page: Int) async {
        await waitForObservedState {
            if case .loaded(let loaded) = model.state { return loaded.pageNumber == page }
            return false
        }
    }
}

/// 本 target 唯一的 `UploaderVideoRepository` 替身：按页返回一条视频，可让指定页失败或挂起。
actor UploaderVideoRepositoryStub: UploaderVideoRepository {
    struct Call: Equatable, Sendable {
        let ownerID: Int64
        let order: UploaderVideoOrder
        let page: Int
    }

    private(set) var calls: [Call] = []
    private let totalCount: Int
    private var failingPages: [Int: ContentApplicationError]
    private let gate: TestGate?
    private let gatedPages: Set<Int>
    private let completions = TestEventCounter()

    init(
        totalCount: Int = 61,
        failingPages: [Int: ContentApplicationError] = [:],
        gate: TestGate? = nil,
        gatedPages: Set<Int> = []
    ) {
        self.totalCount = totalCount
        self.failingPages = failingPages
        self.gate = gate
        self.gatedPages = gatedPages
    }

    func setFailure(_ error: ContentApplicationError?, page: Int) {
        failingPages[page] = error
    }

    func waitForCompletions(_ count: Int) async {
        try? await completions.wait(until: count)
    }

    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage {
        calls.append(Call(ownerID: ownerID, order: order, page: page))
        if let gate, gatedPages.contains(page) {
            await gate.pass()
        }
        defer { Task { await completions.signal() } }
        if let error = failingPages[page] {
            throw error
        }
        let videos =
            totalCount == 0
            ? []
            : [
                UploaderVideo(
                    bvid: "BV1Page\(page)Fixture",
                    title: "第 \(page) 页",
                    coverURL: nil,
                    durationSeconds: 60,
                    viewCount: 1,
                    danmakuCount: 0,
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    isCollaboration: false
                )
            ]
        return UploaderVideoPage(
            videos: videos,
            pageNumber: page,
            pageSize: 30,
            totalCount: totalCount
        )
    }
}
