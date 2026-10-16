import BiliModels

/// 弹幕分段读取的应用级错误。
///
/// 弹幕失败只让该分段静默失败，会话不再请求它，因此没有“需要登录”“本地凭据读不到”等独立状态，它们由
/// adapter 归入 `unavailable`；只有凭据失效需要区分，用于触发账户复核。
public enum DanmakuApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case authenticationInvalid
    case requestRestricted
    case transportFailure
    case invalidResponse
    case unavailable
}

extension DanmakuApplicationError {
    /// 只有凭据失效需要窗口复核账户会话；`DanmakuSession` 据此发出一次复核通知。
    public var requiresAccountRevalidation: Bool {
        self == .authenticationInvalid
    }
}

public protocol DanmakuSegmentRepository: Sendable {
    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment
}

/// 验证弹幕分段请求边界，并拒绝 adapter 返回与请求 index 不一致的结果。
public struct DanmakuSegmentUseCase: Sendable {
    public static let maximumSegmentIndex = 10_000

    private let repository: any DanmakuSegmentRepository

    public init(repository: any DanmakuSegmentRepository) {
        self.repository = repository
    }

    public func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        guard (1...Self.maximumSegmentIndex).contains(index),
            !identity.bvid.isEmpty,
            identity.cid > 0
        else {
            throw DanmakuApplicationError.invalidRequest
        }
        let segment = try await repository.segment(index: index, for: identity)
        guard segment.index == index else {
            throw DanmakuApplicationError.invalidResponse
        }
        return segment
    }
}
