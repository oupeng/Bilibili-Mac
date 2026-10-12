import BiliApplication
import BiliModels
import Foundation

struct DanmakuDensityAdmissionPolicy: Sendable, Equatable {
    let minimumHorizontalGap: Double
    let maximumOverlapDepth: Int

    init(_ density: DanmakuDensity) {
        switch density {
        case .normal:
            minimumHorizontalGap = 64
            maximumOverlapDepth = 1
        case .increased:
            minimumHorizontalGap = 32
            maximumOverlapDepth = 1
        case .overlapping:
            minimumHorizontalGap = 0
            maximumOverlapDepth = 3
        }
    }
}

public struct DanmakuRendererStatistics: Sendable, Equatable {
    public private(set) var droppedNoLane = 0
    public private(set) var droppedCapacity = 0
    public private(set) var active = 0

    public init() {}

    mutating func record(_ admission: DanmakuLaneAdmission) {
        droppedNoLane += admission.dropCounts.noLane
        droppedCapacity += admission.dropCounts.capacity
    }

    mutating func recordCapacityDrops(_ count: Int) {
        droppedCapacity += max(count, 0)
    }

    mutating func recordPreparationDrop(
        _ reason: DanmakuPreparationRejectionReason
    ) {
        switch reason {
        case .capacity:
            droppedCapacity += 1
        case .invalidInput, .oversized:
            droppedNoLane += 1
        case .cancelled:
            break
        }
    }

    mutating func updateActive(_ count: Int) {
        active = count
    }
}

@MainActor
/// 在调度 batch 与具体 renderer 之间执行 identity/generation 检查、lane 分配与容量治理。
///
/// surface owner ID 防止旧 `AVPlayerView` 的迟到 resize/detach 操作清空新宿主；换 identity、
/// seek generation 或显式清屏都会同步清空 allocator 与 backend。
public final class DanmakuPresentationController:
    DanmakuPresentationSink,
    DanmakuRenderingBackendDelegate
{
    private struct PendingPreparation {
        let event: DanmakuEvent
        let speedLevel: DanmakuSpeedLevel
        let identity: PlaybackItemIdentity
        let discontinuityGeneration: UInt64
        let preparationGeneration: UInt64
        /// 补位批次的编号：补位弹幕按自己的时间点进场，同一批全部准备好后一起上屏。
        let catchUpGroup: UInt64?
    }

    /// 已准入、等同批其余纹理准备好再一起上屏的补位弹幕。
    private struct DeferredCatchUp {
        let placement: DanmakuLanePlacement
        let preparationID: UInt64
    }

    /// 补位时每条车道最多准备的候选数：一屏里同一车道同时可见的滚动弹幕很少超过这个数，
    /// 再多只会准备出马上被丢弃的纹理。
    static let catchUpCandidatesPerLane = 4

    public private(set) var statistics = DanmakuRendererStatistics()

    private let backend: any DanmakuRenderingBackend
    private var allocator: DanmakuLaneAllocator
    private var configuration: DanmakuLaneConfiguration
    private var speedLevel = DanmakuSpeedLevel.default
    private var displayArea = DanmakuDisplayArea.default
    private var density = DanmakuDensity.default
    private var identity: PlaybackItemIdentity?
    private var discontinuityGeneration: UInt64?
    private var surfaceOwnerID: UUID?
    private var backingScale = 2.0
    private var preparationGeneration: UInt64 = 0
    private var nextPreparationID: UInt64 = 0
    private var pendingPreparations: [UInt64: PendingPreparation] = [:]
    private var pendingOrder: [UInt64] = []
    private var completedPreparations: [UInt64: DanmakuPreparationResult] = [:]
    private var latestSnapshot: PlaybackTimelineSnapshot?
    private var nextCatchUpGroup: UInt64 = 0
    private var deferredCatchUps: [UInt64: [DeferredCatchUp]] = [:]

    public init(
        backend: any DanmakuRenderingBackend,
        configuration: DanmakuLaneConfiguration
    ) {
        self.backend = backend
        self.allocator = DanmakuLaneAllocator(configuration: configuration)
        self.configuration = configuration
        backend.delegate = self
        backend.updateSurfaceSize(
            width: configuration.surfaceWidth,
            height: configuration.surfaceHeight,
            backingScale: backingScale
        )
    }

    public var catchUpWindowSeconds: Double {
        DanmakuMotionPolicy.catchUpWindow(
            surfaceWidth: configuration.surfaceWidth,
            speedLevel: speedLevel
        )
    }

    /// 只呈现与快照 identity 和 discontinuity generation 完全匹配的 batch。
    public func apply(_ update: DanmakuPresentationUpdate) {
        guard let updateIdentity = update.snapshot.identity else {
            stopPresentation()
            return
        }
        let matchingBatch = update.batch.flatMap { batch in
            batch.identity == updateIdentity
                && batch.discontinuityGeneration
                    == update.snapshot.discontinuityGeneration
                ? batch
                : nil
        }

        let changesIdentity = identity != updateIdentity
        let changesGeneration =
            discontinuityGeneration
            != update.snapshot.discontinuityGeneration
        if changesIdentity
            || changesGeneration
            || matchingBatch?.clearsExisting == true
        {
            clearBackendAndAllocator()
        }
        identity = updateIdentity
        discontinuityGeneration =
            update.snapshot.discontinuityGeneration
        latestSnapshot = update.snapshot

        let effectiveRate =
            update.snapshot.state == .playing
            ? update.snapshot.rate
            : 0
        backend.setPlaybackRate(effectiveRate)

        guard let batch = matchingBatch,
            !batch.clearsExisting
        else {
            return
        }

        let availablePreparationSlots = max(
            DanmakuLaneConfiguration.hardMaximumActiveCount
                - pendingPreparations.count,
            0
        )
        let candidates: [DanmakuEvent]
        let attemptedEvents: ArraySlice<DanmakuEvent>
        if batch.catchesUp {
            // 补位：只准备当前窗口内的，按时间先后准备与准入；超出上限时保留最新的。
            let windowStart = update.snapshot.positionSeconds - catchUpWindowSeconds
            candidates = batch.events.filter { $0.timeSeconds > windowStart }
            attemptedEvents = candidates.suffix(
                min(availablePreparationSlots, catchUpCandidateLimit)
            )
        } else {
            candidates = batch.events
            attemptedEvents = candidates.prefix(availablePreparationSlots)
        }
        statistics.recordCapacityDrops(
            candidates.count - attemptedEvents.count
        )
        var catchUpGroup: UInt64?
        if batch.catchesUp {
            nextCatchUpGroup &+= 1
            catchUpGroup = nextCatchUpGroup
        }
        enqueuePreparations(
            Array(attemptedEvents),
            identity: updateIdentity,
            discontinuityGeneration: update.snapshot.discontinuityGeneration,
            catchUpGroup: catchUpGroup
        )
    }

    /// 补位候选上限：显示区域的车道数 × 重叠层数 × 每车道候选数。
    private var catchUpCandidateLimit: Int {
        let displayHeight =
            configuration.surfaceHeight * configuration.displayAreaFraction
        let laneCount =
            configuration.laneHeight > 0 && displayHeight.isFinite
            ? max(Int(displayHeight / configuration.laneHeight), 1) : 1
        return laneCount * max(configuration.maximumOverlapDepth, 1)
            * Self.catchUpCandidatesPerLane
    }

    public func clearPresentation() {
        clearBackendAndAllocator()
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        self.speedLevel = speedLevel
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        backend.setOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        self.displayArea = displayArea
        updateAdmissionPolicy()
    }

    public func setDensity(_ density: DanmakuDensity) {
        self.density = density
        updateAdmissionPolicy()
    }

    public func stopPresentation() {
        cancelPendingPreparations()
        _ = allocator.clear()
        backend.stop()
        identity = nil
        discontinuityGeneration = nil
        latestSnapshot = nil
        statistics.updateActive(0)
    }

    private func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        let normalizedScale = Self.normalizedBackingScale(backingScale)
        if normalizedScale != self.backingScale {
            self.backingScale = normalizedScale
            cancelPendingPreparations()
        }
        configuration = DanmakuLaneConfiguration(
            surfaceWidth: width,
            surfaceHeight: height,
            laneHeight: configuration.laneHeight,
            minimumHorizontalGap: configuration.minimumHorizontalGap,
            maximumActiveCount: configuration.maximumActiveCount,
            displayAreaFraction: configuration.displayAreaFraction,
            maximumOverlapDepth: configuration.maximumOverlapDepth
        )
        allocator.updateConfiguration(configuration)
        backend.updateSurfaceSize(
            width: width,
            height: height,
            backingScale: normalizedScale
        )
    }

    @discardableResult
    public func attachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID != ownerID else { return true }
        surfaceOwnerID = ownerID
        clearBackendAndAllocator()
        return true
    }

    @discardableResult
    public func detachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        surfaceOwnerID = nil
        clearBackendAndAllocator()
        return true
    }

    @discardableResult
    public func updateSurface(
        width: Double,
        height: Double,
        backingScale: Double = 2,
        ownerID: UUID
    ) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        updateSurfaceSize(
            width: width,
            height: height,
            backingScale: backingScale
        )
        return true
    }

    public func rendererDidFinish(eventID: String) {
        allocator.remove(eventID: eventID)
        statistics.updateActive(allocator.activeCount)
    }

    private func clearBackendAndAllocator() {
        cancelPendingPreparations()
        _ = allocator.clear()
        backend.clearAll()
        statistics.updateActive(0)
    }

    /// 先登记整批再开始准备：缓存命中会同步完成，补位批次必须在第一条完成前就知道同批还有谁。
    private func enqueuePreparations(
        _ events: [DanmakuEvent],
        identity: PlaybackItemIdentity,
        discontinuityGeneration: UInt64,
        catchUpGroup: UInt64?
    ) {
        let generation = preparationGeneration
        var registered: [(id: UInt64, event: DanmakuEvent)] = []
        for event in events {
            nextPreparationID &+= 1
            let preparationID = nextPreparationID
            pendingPreparations[preparationID] = PendingPreparation(
                event: event,
                speedLevel: speedLevel,
                identity: identity,
                discontinuityGeneration: discontinuityGeneration,
                preparationGeneration: generation,
                catchUpGroup: catchUpGroup
            )
            pendingOrder.append(preparationID)
            registered.append((preparationID, event))
        }
        for (preparationID, event) in registered {
            backend.prepare(
                event,
                preparationID: preparationID,
                generation: generation,
                backingScale: backingScale
            ) { [weak self] result in
                self?.completePreparation(
                    preparationID: preparationID,
                    generation: generation,
                    result: result
                )
            }
        }
    }

    private func completePreparation(
        preparationID: UInt64,
        generation: UInt64,
        result: DanmakuPreparationResult
    ) {
        guard generation == preparationGeneration,
            pendingPreparations[preparationID]?.preparationGeneration
                == generation
        else {
            backend.discardPreparation(preparationID: preparationID)
            return
        }
        completedPreparations[preparationID] = result
        drainCompletedPreparations()
    }

    private func drainCompletedPreparations() {
        while let preparationID = pendingOrder.first,
            let result = completedPreparations.removeValue(
                forKey: preparationID
            )
        {
            pendingOrder.removeFirst()
            guard
                let pending = pendingPreparations.removeValue(
                    forKey: preparationID
                )
            else {
                backend.discardPreparation(preparationID: preparationID)
                continue
            }
            processPreparation(
                result,
                preparationID: preparationID,
                pending: pending
            )
            if let group = pending.catchUpGroup,
                !pendingPreparations.values.contains(where: { $0.catchUpGroup == group })
            {
                flushCatchUp(group: group)
            }
        }
    }

    /// 同批补位弹幕一起上屏，已走过的时长按此刻计算；等待期间已经走完的不再显示。
    private func flushCatchUp(group: UInt64) {
        guard let deferred = deferredCatchUps.removeValue(forKey: group) else { return }
        guard let now = latestSnapshot?.positionSeconds else {
            releaseDeferred(deferred)
            return
        }
        var failedRenders = 0
        for item in deferred {
            let placement = item.placement
            let isVisible = placement.expiresAtSeconds > now
            if isVisible,
                backend.renderPrepared(
                    placement,
                    preparationID: item.preparationID,
                    generation: preparationGeneration,
                    elapsedSeconds: now - placement.admittedAtSeconds
                )
            {
                continue
            }
            if isVisible {
                failedRenders += 1
            }
            allocator.remove(eventID: placement.request.event.id)
            backend.discardPreparation(preparationID: item.preparationID)
        }
        statistics.recordCapacityDrops(failedRenders)
        statistics.updateActive(allocator.activeCount)
    }

    private func processPreparation(
        _ result: DanmakuPreparationResult,
        preparationID: UInt64,
        pending: PendingPreparation
    ) {
        guard pending.preparationGeneration == preparationGeneration,
            identity == pending.identity,
            discontinuityGeneration == pending.discontinuityGeneration,
            let snapshot = latestSnapshot,
            snapshot.identity == pending.identity,
            snapshot.discontinuityGeneration
                == pending.discontinuityGeneration
        else {
            backend.discardPreparation(preparationID: preparationID)
            return
        }
        guard case .ready(let metrics) = result else {
            if case .rejected(let reason) = result {
                statistics.recordPreparationDrop(reason)
            }
            backend.discardPreparation(preparationID: preparationID)
            return
        }

        let durationSeconds = DanmakuMotionPolicy.duration(
            for: pending.event.mode,
            textWidth: metrics.width,
            surfaceWidth: configuration.surfaceWidth,
            speedLevel: pending.speedLevel
        )
        let request = DanmakuLaneRequest(
            event: pending.event,
            width: metrics.width,
            height: metrics.height,
            durationSeconds: durationSeconds
        )
        // 补位弹幕按自己的时间点准入，车道按连续播放时的位置计算；准备期间已经走完的不再显示。
        // 准备按入队顺序完成，补位批次又按时间排序，准入时间因此不会倒退。
        let now = snapshot.positionSeconds
        let admissionSeconds =
            pending.catchUpGroup == nil ? now : min(pending.event.timeSeconds, now)
        if pending.catchUpGroup != nil, !(admissionSeconds + durationSeconds > now) {
            backend.discardPreparation(preparationID: preparationID)
            return
        }
        let admission = allocator.admit(
            [request],
            at: admissionSeconds
        )
        for expired in admission.expired {
            backend.remove(eventID: expired.request.event.id)
        }
        if let group = pending.catchUpGroup {
            if admission.admitted.isEmpty {
                backend.discardPreparation(preparationID: preparationID)
            }
            deferredCatchUps[group, default: []].append(
                contentsOf: admission.admitted.map {
                    DeferredCatchUp(placement: $0, preparationID: preparationID)
                }
            )
            statistics.record(admission)
            return
        }
        var installed: [DanmakuLanePlacement] = []
        for placement in admission.admitted {
            if backend.renderPrepared(
                placement,
                preparationID: preparationID,
                generation: preparationGeneration,
                elapsedSeconds: now - admissionSeconds
            ) {
                installed.append(placement)
            } else {
                allocator.remove(eventID: placement.request.event.id)
            }
        }
        if installed.isEmpty {
            backend.discardPreparation(preparationID: preparationID)
        }
        statistics.recordCapacityDrops(
            admission.admitted.count - installed.count
        )
        statistics.record(
            DanmakuLaneAdmission(
                expired: admission.expired,
                admitted: installed,
                dropCounts: admission.dropCounts
            )
        )
        statistics.updateActive(allocator.activeCount)
    }

    /// 等待上屏的补位弹幕已占用车道，丢弃时一并归还，否则车道会被看不见的弹幕占到过期。
    private func releaseDeferred(_ deferred: [DeferredCatchUp]) {
        for item in deferred {
            allocator.remove(eventID: item.placement.request.event.id)
            backend.discardPreparation(preparationID: item.preparationID)
        }
        statistics.updateActive(allocator.activeCount)
    }

    private func cancelPendingPreparations() {
        preparationGeneration &+= 1
        releaseDeferred(deferredCatchUps.values.flatMap(\.self))
        deferredCatchUps.removeAll(keepingCapacity: false)
        pendingPreparations.removeAll(keepingCapacity: false)
        pendingOrder.removeAll(keepingCapacity: false)
        completedPreparations.removeAll(keepingCapacity: false)
        backend.cancelPendingPreparations()
    }

    private static func normalizedBackingScale(_ scale: Double) -> Double {
        scale.isFinite
            ? min(max(scale, 1), DanmakuTextureRasterizer.maximumBackingScale)
            : 2
    }

    private func updateAdmissionPolicy() {
        let effectiveDensity: DanmakuDensity =
            displayArea == .full ? density : .normal
        let policy = DanmakuDensityAdmissionPolicy(effectiveDensity)
        configuration = DanmakuLaneConfiguration(
            surfaceWidth: configuration.surfaceWidth,
            surfaceHeight: configuration.surfaceHeight,
            laneHeight: configuration.laneHeight,
            minimumHorizontalGap: policy.minimumHorizontalGap,
            maximumActiveCount: configuration.maximumActiveCount,
            displayAreaFraction: displayArea.fraction,
            maximumOverlapDepth: policy.maximumOverlapDepth
        )
        allocator.updateConfiguration(configuration)
    }
}
