import BiliModels
import Foundation

@MainActor
/// 观察播放时间线，在播放到 SponsorBlock 片段区间时自动触发 Seek 跳过恰饭/赞助片段。
public final class SponsorBlockSession {
    public typealias SegmentFetcher = @Sendable (String, Int64?) async throws -> [SponsorSegment]
    public typealias SeekHandler = @MainActor (Double) -> Void
    public typealias SkippedHandler = @MainActor (SponsorSegment) -> Void

    public var isEnabled: Bool = true

    private let timeline: any PlaybackTimelineProviding
    private let fetchSegments: SegmentFetcher
    private let performSeek: SeekHandler
    private let onSegmentSkipped: SkippedHandler?

    private var cancelTimelineObservation: (@MainActor @Sendable () -> Void)?
    private var fetchTask: Task<Void, Never>?

    private var currentIdentity: PlaybackItemIdentity?
    public private(set) var segments: [SponsorSegment] = []
    private var skippedSegmentUUIDs: Set<String> = []

    public init(
        timeline: any PlaybackTimelineProviding,
        fetchSegments: @escaping SegmentFetcher,
        performSeek: @escaping SeekHandler,
        onSegmentSkipped: SkippedHandler? = nil
    ) {
        self.timeline = timeline
        self.fetchSegments = fetchSegments
        self.performSeek = performSeek
        self.onSegmentSkipped = onSegmentSkipped
    }

    deinit {
        if let cancelTimelineObservation {
            Task { @MainActor in cancelTimelineObservation() }
        }
        fetchTask?.cancel()
    }

    public func start() {
        guard cancelTimelineObservation == nil else { return }
        cancelTimelineObservation = timeline.observeTimeline { [weak self] snapshot in
            self?.consume(snapshot)
        }
    }

    public func stop() {
        cancelTimelineObservation?()
        cancelTimelineObservation = nil
        fetchTask?.cancel()
        fetchTask = nil
        currentIdentity = nil
        segments = []
        skippedSegmentUUIDs.removeAll()
    }

    private func consume(_ snapshot: PlaybackTimelineSnapshot) {
        guard isEnabled, let identity = snapshot.identity else {
            if currentIdentity != nil {
                segments = []
                skippedSegmentUUIDs.removeAll()
                currentIdentity = nil
            }
            return
        }

        if currentIdentity != identity {
            currentIdentity = identity
            segments = []
            skippedSegmentUUIDs.removeAll()
            loadSegments(for: identity)
            return
        }

        guard !segments.isEmpty,
            snapshot.state == .playing || snapshot.state == .buffering
        else {
            return
        }

        let pos = snapshot.positionSeconds

        // 如果用户倒放/手动 seek 到片段前 1 秒以上，恢复该片段的可跳过状态
        for segment in segments {
            if pos < segment.startTimeSeconds - 1.0 {
                skippedSegmentUUIDs.remove(segment.uuid)
            }
        }

        // 检查当前进度是否落入未跳过的片段区间内
        for segment in segments {
            guard !skippedSegmentUUIDs.contains(segment.uuid) else { continue }
            if pos >= segment.startTimeSeconds - 0.2 && pos < segment.endTimeSeconds - 0.5 {
                skippedSegmentUUIDs.insert(segment.uuid)
                performSeek(segment.endTimeSeconds)
                onSegmentSkipped?(segment)
                break
            }
        }
    }

    private func loadSegments(for identity: PlaybackItemIdentity) {
        fetchTask?.cancel()
        let bvid = identity.bvid
        let cid = identity.cid
        fetchTask = Task { [weak self] in
            let resultSegments: [SponsorSegment]
            do {
                resultSegments = try await fetchSegments(bvid, cid)
            } catch {
                resultSegments = []
            }
            guard !Task.isCancelled else { return }
            self?.segments = resultSegments
        }
    }
}
