import BiliModels
import Foundation

public struct SponsorBlockSkipEvent: Sendable, Equatable {
    public let segment: SponsorSegment
    public let skippedFromSeconds: Double
    public let skippedToSeconds: Double

    public init(segment: SponsorSegment, skippedFromSeconds: Double, skippedToSeconds: Double) {
        self.segment = segment
        self.skippedFromSeconds = skippedFromSeconds
        self.skippedToSeconds = skippedToSeconds
    }
}

@MainActor
public final class SponsorBlockController {
    private let repository: SponsorBlockRepositoryPort
    private let timeline: any PlaybackTimelineProviding
    private let seekHandler: @MainActor (Double) -> Void

    private var currentTask: Task<Void, Never>?
    private var timelineObservationCancel: (@MainActor @Sendable () -> Void)?

    private var currentIdentity: PlaybackItemIdentity?
    private var currentSegments: [SponsorSegment] = []
    private var skippedSegmentIDs: Set<String> = []
    private var lastSkippedTime: Date?

    private var settings: SponsorBlockSettings
    private var skipEventContinuations: [UUID: AsyncStream<SponsorBlockSkipEvent>.Continuation] = [:]

    public init(
        repository: SponsorBlockRepositoryPort,
        timeline: any PlaybackTimelineProviding,
        settings: SponsorBlockSettings = .default,
        seekHandler: @escaping @MainActor (Double) -> Void
    ) {
        self.repository = repository
        self.timeline = timeline
        self.settings = settings
        self.seekHandler = seekHandler
        setupTimelineObservation()
    }

    deinit {
        timelineObservationCancel?()
        currentTask?.cancel()
        for continuation in skipEventContinuations.values {
            continuation.finish()
        }
    }

    public func updateSettings(_ newSettings: SponsorBlockSettings) {
        self.settings = newSettings
    }

    public func skipEvents() -> AsyncStream<SponsorBlockSkipEvent> {
        let subscriptionID = UUID()
        let stream = AsyncStream<SponsorBlockSkipEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(5)
        )
        skipEventContinuations[subscriptionID] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.skipEventContinuations.removeValue(forKey: subscriptionID)
            }
        }
        return stream.stream
    }

    private func setupTimelineObservation() {
        timelineObservationCancel = timeline.observeTimeline { [weak self] snapshot in
            self?.handleTimelineSnapshot(snapshot)
        }
    }

    private func handleTimelineSnapshot(_ snapshot: PlaybackTimelineSnapshot) {
        guard settings.isEnabled else { return }

        // 若当前播放的视频改变，清理缓存并重新请求 segments
        if snapshot.identity != currentIdentity {
            currentIdentity = snapshot.identity
            currentSegments = []
            skippedSegmentIDs = []
            currentTask?.cancel()

            if let identity = snapshot.identity {
                loadSegments(for: identity.bvid)
            }
            return
        }

        guard snapshot.state == .playing || snapshot.state == .ready else { return }
        guard let identity = snapshot.identity, !currentSegments.isEmpty else { return }

        let currentPosition = snapshot.positionSeconds

        // 防抖：如果刚刚跳过未满 0.5 秒，暂不进行下一次跳过判定
        if let lastSkippedTime, Date().timeIntervalSince(lastSkippedTime) < 0.5 {
            return
        }

        // 检查是否有匹配可跳过的片段
        for segment in currentSegments {
            guard settings.enabledCategories.contains(segment.category) else { continue }
            guard segment.actionType == .skip else { continue }
            guard !skippedSegmentIDs.contains(segment.id) else { continue }

            // 包含微小容差 (0.1秒)
            if currentPosition >= (segment.startSeconds - 0.1) && currentPosition < (segment.endSeconds - 0.2) {
                skippedSegmentIDs.insert(segment.id)
                lastSkippedTime = Date()

                seekHandler(segment.endSeconds)

                let event = SponsorBlockSkipEvent(
                    segment: segment,
                    skippedFromSeconds: currentPosition,
                    skippedToSeconds: segment.endSeconds
                )
                publishSkipEvent(event)
                break
            }
        }
    }

    private func loadSegments(for bvid: String) {
        let serverURL = settings.serverURL
        currentTask = Task { [weak self] in
            guard let self else { return }
            let segments = (try? await self.repository.fetchSegments(bvid: bvid, serverURL: serverURL)) ?? []
            if !Task.isCancelled {
                self.currentSegments = segments
            }
        }
    }

    private func publishSkipEvent(_ event: SponsorBlockSkipEvent) {
        for continuation in skipEventContinuations.values {
            continuation.yield(event)
        }
    }
}
