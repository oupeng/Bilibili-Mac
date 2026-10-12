import BiliApplication
import BiliModels
import Observation

/// 搜索起始页的 B 站热搜：每次起始页出现时刷新，失败只影响热搜区。
///
/// 已有结果时在后台刷新并保留旧结果，刷新失败也不清空；没有结果时才呈现加载与失败。
@MainActor
@Observable
public final class TrendingSearchViewModel {
    public enum State: Equatable {
        case idle
        case loading
        case loaded([TrendingSearchKeyword])
        case failed(ContentApplicationError)
    }

    public private(set) var state: State = .idle
    @ObservationIgnored private let useCase: TrendingSearchUseCase
    @ObservationIgnored private let loadTask = LatestTask()

    public init(useCase: TrendingSearchUseCase) {
        self.useCase = useCase
    }

    public func refresh() {
        if case .loaded = state {
        } else {
            state = .loading
        }
        loadTask.replace { [weak self, useCase] isCurrent in
            let result: Result<[TrendingSearchKeyword], ContentApplicationError>
            do {
                result = .success(try await useCase.trendingKeywords())
            } catch is CancellationError {
                return
            } catch let error as ContentApplicationError {
                result = .failure(error)
            } catch {
                result = .failure(.unavailable)
            }
            guard let self, isCurrent() else { return }
            self.state = Self.state(after: result, replacing: self.state)
        }
    }

    /// 一次加载结果如何落到状态上：成功总是替换；失败只在没有可用结果时呈现，刷新失败保留旧结果。
    static func state(
        after result: Result<[TrendingSearchKeyword], ContentApplicationError>,
        replacing current: State
    ) -> State {
        switch (result, current) {
        case (.success(let keywords), _):
            .loaded(keywords)
        case (.failure, .loaded):
            current
        case (.failure(let error), _):
            .failed(error)
        }
    }

    /// 关窗时取消在途请求并丢弃结果。
    public func reset() {
        loadTask.cancel()
        state = .idle
    }
}
