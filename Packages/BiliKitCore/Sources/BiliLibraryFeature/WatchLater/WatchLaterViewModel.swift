import BiliApplication
import BiliModels
import Foundation
import Observation

public enum WatchLaterState: Sendable, Equatable {
    case idle
    case loading
    case loaded(items: [WatchLaterItem])
    case failed(WatchLaterError)
}

@MainActor
@Observable
public final class WatchLaterViewModel {
    public private(set) var state: WatchLaterState = .idle

    public var requiresAuthentication: Bool {
        switch state {
        case .failed(.authenticationRequired):
            true
        default:
            false
        }
    }

    public var isBusy: Bool {
        switch state {
        case .loading:
            true
        case .idle, .loaded, .failed:
            false
        }
    }

    @ObservationIgnored private let useCase: WatchLaterUseCase
    @ObservationIgnored private let loadTask = LatestTask()

    public init(useCase: WatchLaterUseCase) {
        self.useCase = useCase
    }

    public func loadIfNeeded() {
        guard state == .idle else { return }
        reload()
    }

    public func reload() {
        state = .loading
        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let items = try await useCase.load()
                guard isCurrent() else { return }
                state = .loaded(items: items)
            } catch {
                guard isCurrent() else { return }
                state = .failed(error as? WatchLaterError ?? .transportFailure)
            }
        }
    }

    public func reset() {
        loadTask.cancel()
        state = .idle
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }
}
