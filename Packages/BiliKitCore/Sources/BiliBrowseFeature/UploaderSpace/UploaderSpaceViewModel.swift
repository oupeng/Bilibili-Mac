import BiliApplication
import BiliModels
import Foundation
import Observation

public enum UploaderSpaceState: Sendable, Equatable {
    case closed
    case loading(page: Int)
    case loaded(UploaderVideoPage)
    case failed(page: Int, error: ContentApplicationError)
}

@MainActor
@Observable
/// 拥有侧栏 UP 主空间层的 UP 主、排序、页码与最新请求 Task。
///
/// 按页替换，不追加；同一 UP 主再次打开保持当前状态。总页数与投稿数取自最近一次成功的页，
/// 翻页加载或失败期间保留，页码条不会消失。
public final class UploaderSpaceViewModel {
    public private(set) var owner: VideoOwner?
    public private(set) var order: UploaderVideoOrder = .newest
    public private(set) var state: UploaderSpaceState = .closed
    public private(set) var pageCount = 1
    public private(set) var totalCount = 0
    /// 凭据失效（而非未登录）时递增，由 App 触发账户复核。
    public private(set) var authenticationRevalidationGeneration: UInt64 = 0

    public var currentPage: Int {
        switch state {
        case .closed:
            1
        case .loading(let page), .failed(let page, _):
            page
        case .loaded(let page):
            page.pageNumber
        }
    }

    public var requiresAuthentication: Bool {
        if case .failed(_, .authenticationRequired) = state {
            return true
        }
        return false
    }

    @ObservationIgnored private let useCase: UploaderVideoUseCase
    @ObservationIgnored private let loadTask = LatestTask()

    public init(useCase: UploaderVideoUseCase) {
        self.useCase = useCase
    }

    public func open(owner: VideoOwner) {
        guard self.owner?.id != owner.id else { return }
        self.owner = owner
        order = .newest
        resetPagination()
        load(page: 1)
    }

    public func close() {
        loadTask.cancel()
        owner = nil
        order = .newest
        resetPagination()
        state = .closed
    }

    /// 换排序回到第 1 页。
    public func setOrder(_ order: UploaderVideoOrder) {
        guard owner != nil, self.order != order else { return }
        self.order = order
        resetPagination()
        load(page: 1)
    }

    /// 页码超出已知范围、或请求当前已显示的页时不发请求；失败的页可以再次请求。
    public func showPage(_ page: Int) {
        guard owner != nil, (1...pageCount).contains(page) else { return }
        if case .loaded(let loaded) = state, loaded.pageNumber == page { return }
        if case .loading(let loading) = state, loading == page { return }
        load(page: page)
    }

    /// 重新读取当前页：失败重试，或登录状态变化后刷新。
    public func reload() {
        guard owner != nil else { return }
        load(page: currentPage)
    }

    private func resetPagination() {
        pageCount = 1
        totalCount = 0
    }

    private func load(page: Int) {
        guard let ownerID = owner?.id else { return }
        let order = order
        let useCase = useCase
        state = .loading(page: page)
        loadTask.replace { [weak self] isCurrent in
            let result: Result<UploaderVideoPage, ContentApplicationError>
            do {
                result = .success(
                    try await useCase.page(ownerID: ownerID, order: order, page: page)
                )
            } catch {
                // 本任务未被取消却收到取消，说明认证会话在请求途中切换；给出可重试终态而不是停在 loading。
                result = .failure(error as? ContentApplicationError ?? .unavailable)
            }
            guard let self, isCurrent() else { return }
            apply(result, page: page)
        }
    }

    private func apply(_ result: Result<UploaderVideoPage, ContentApplicationError>, page: Int) {
        switch result {
        case .success(let loaded):
            pageCount = loaded.pageCount
            totalCount = loaded.totalCount
            state = .loaded(loaded)
        case .failure(let error):
            if error == .authenticationInvalid {
                authenticationRevalidationGeneration &+= 1
            }
            state = .failed(page: page, error: error)
        }
    }
}
