import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 搜索会话：提交规范化草稿并写入历史，同一条件再次提交原地刷新，排序与筛选替换已提交的条件，清空草稿或关窗撤回
/// 提交，并把提交映射为 Browse 搜索工作集的激活。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VideoSearchSessionTests {
    @Test
    func submitNormalizesTheDraftRecordsHistoryAndActivatesTheSearch() {
        var recorded: [String] = []
        let session = makeSession { recorded.append($0) }

        session.draft = "  猫  "
        session.submit()

        let criteria = VideoSearchCriteria(query: "猫")
        #expect(session.draft == "猫")
        #expect(recorded == ["猫"])
        #expect(session.submittedCriteria == criteria)
        #expect(session.browseActivation == .search(criteria: criteria))
    }

    @Test
    func blankDraftsDoNotSubmitAndClearingTheDraftWithdrawsTheSearch() {
        var recorded: [String] = []
        let session = makeSession { recorded.append($0) }

        session.draft = "   "
        session.submit()
        #expect(session.submittedCriteria == nil)
        #expect(recorded.isEmpty)

        session.search(keyword: "热搜词")
        #expect(session.submittedCriteria?.query == "热搜词")

        session.draft = " "
        #expect(session.submittedCriteria == nil)
        #expect(session.browseActivation == .search(criteria: nil))
    }

    /// 与上次提交相同的条件不再替换提交（激活的 identity 不变），而是原地刷新同一工作集。
    @Test
    func resubmittingTheSameCriteriaRefreshesTheWorkset() async {
        let repository = FeedRepositoryStub(
            search: { request, _ in ContentFixtures().searchPage(page: request.page) }
        )
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: repository))
        var recorded: [String] = []
        let session = VideoSearchSession(browseModel: browseModel) { recorded.append($0) }
        session.search(keyword: "猫")
        await browseModel.activate(session.browseActivation)
        let submitted = session.submittedCriteria

        session.submit()
        await browseModel.waitForCurrentTask()

        #expect(session.submittedCriteria == submitted)
        #expect(recorded == ["猫", "猫"])
        #expect(await repository.searchRequests.count == 2)
    }

    @Test
    func orderAndFiltersReplaceTheSubmittedCriteria() throws {
        let session = makeSession()
        // 与工具栏排序菜单一致：先改选择，再通知会话。
        session.filterSelection.order = .newest
        session.selectOrder(.newest)
        session.search(keyword: "猫")
        #expect(session.submittedCriteria?.order == .newest)

        var selection = session.filterSelection
        selection.duration = .overSixtyMinutes
        selection.publication = .lastSevenDays
        session.filterSelection = selection
        session.applyFilters(selection)
        let filtered = try #require(session.submittedCriteria)
        #expect(filtered.query == "猫")
        #expect(filtered.duration == .overSixtyMinutes)
        #expect(filtered.publicationRange != nil)

        session.clearFilters()
        #expect(session.filterSelection.activeFilterCount == 0)
        #expect(
            session.submittedCriteria
                == VideoSearchCriteria(query: "猫", order: .newest, duration: .all)
        )
    }

    /// 自定义日期不合法时不应用（工具栏弹窗已禁用应用按钮），已提交的条件保持不变。
    @Test
    func invalidCustomDatesAreNotApplied() {
        let session = makeSession()
        session.search(keyword: "猫")
        var selection = SearchFilterSelection()
        selection.publication = .custom
        selection.customStart = Date()
        selection.customEnd = Date(timeIntervalSinceNow: -30 * 86_400)

        session.applyFilters(selection)

        #expect(session.submittedCriteria == VideoSearchCriteria(query: "猫"))
    }

    @Test
    func resetClearsTheDraftAndWithdrawsTheSearch() {
        let session = makeSession()
        session.search(keyword: "猫")

        session.reset()

        #expect(session.draft.isEmpty)
        #expect(session.submittedCriteria == nil)
    }

    private func makeSession(
        recordHistory: @escaping @MainActor (String) -> Void = { _ in }
    ) -> VideoSearchSession {
        VideoSearchSession(
            browseModel: BrowseViewModel(useCase: FeedUseCase(repository: FeedRepositoryStub())),
            recordHistory: recordHistory
        )
    }
}
