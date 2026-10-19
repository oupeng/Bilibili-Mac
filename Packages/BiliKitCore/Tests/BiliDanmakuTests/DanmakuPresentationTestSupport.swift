import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 呈现控制器测试的车道配置：800pt 宽、30pt 车道、全屏显示区域，只变化容量与高度。
func configuration(
    maximumActiveCount: Int,
    surfaceHeight: Double = 300
) -> DanmakuLaneConfiguration {
    DanmakuLaneConfiguration(
        surfaceWidth: 800,
        surfaceHeight: surfaceHeight,
        laneHeight: 30,
        minimumHorizontalGap: 12,
        maximumActiveCount: maximumActiveCount,
        displayAreaFraction: 1
    )
}

/// 呈现控制器测试的一次时间线更新：有弹幕或要求清屏时附带同 identity、同落地代号的批次；
/// `generation` 同时作为不连续代号与落地代号。
func update(
    identity: PlaybackItemIdentity,
    position: Double,
    generation: UInt64,
    state: PlaybackTimelineState = .playing,
    rate: Double = 1,
    events: [DanmakuEvent] = [],
    catchesUp: Bool = false,
    clearsExisting: Bool = false
) -> DanmakuPresentationUpdate {
    let snapshot = PlaybackTimelineSnapshot(
        identity: identity,
        positionSeconds: position,
        durationSeconds: 100,
        rate: rate,
        state: state,
        discontinuityGeneration: generation,
        landingGeneration: generation
    )
    let batch =
        events.isEmpty && !clearsExisting
        ? nil
        : DanmakuBatch(
            identity: identity,
            landingGeneration: generation,
            events: events,
            clearsExisting: clearsExisting,
            catchesUp: catchesUp
        )
    return DanmakuPresentationUpdate(snapshot: snapshot, batch: batch)
}

/// 补位测试用的弹幕：时间点与模式可变，文字与字号固定。
func timedEvent(
    id: String,
    time: Double,
    mode: DanmakuPresentationMode = .scrolling
) -> DanmakuEvent {
    DanmakuEvent(
        id: id,
        timeSeconds: time,
        mode: mode,
        text: "fixture",
        fontSize: 25,
        colorRGB: 0xFFFFFF,
        colorStyle: .solid,
        weight: 1
    )
}

/// 呈现控制器测试唯一的渲染后端替身：记录准备、上屏、移除、清屏、速率、重新合成请求与停止，
/// 可延迟纹理准备由测试逐个完成，也可让上屏失败；不创建任何 layer。
@MainActor
final class RecordingRenderingBackend: DanmakuRenderingBackend {
    weak var delegate: (any DanmakuRenderingBackendDelegate)?
    /// `+id` 表示安装、`-id` 表示移除，只用于断言移除先于新准入。
    private(set) var lifecycle: [String] = []
    private(set) var renderedEventIDs: [String] = []
    /// 已安装且尚未被移除、清屏或停止的弹幕，即此刻在屏上的弹幕。
    private(set) var activeEventIDs: Set<String> = []
    private(set) var renderedPlacements: [DanmakuLanePlacement] = []
    private(set) var renderedElapsedSeconds: [Double] = []
    private(set) var rates: [Double] = []
    /// 每次请求静止重新合成时已发生的清屏与上屏次数，用来断言它在一整批改动之后才被调用。
    private(set) var recomposites: [(clearCount: Int, renderCount: Int)] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    private(set) var measureCount = 0
    var delaysPreparation = false
    var renderPreparedResult = true
    private(set) var preparationIDs: [UInt64] = []
    private(set) var cancelPreparationCount = 0
    private var preparationCompletions:
        [UInt64: @MainActor @Sendable (DanmakuPreparationResult) -> Void] = [:]

    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        preparationIDs.append(preparationID)
        if delaysPreparation {
            preparationCompletions[preparationID] = completion
        } else {
            measureCount += 1
            completion(.ready(DanmakuTextMetrics(width: 120, height: 24)))
        }
    }

    @discardableResult
    func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64,
        elapsedSeconds: Double
    ) -> Bool {
        guard renderPreparedResult else { return false }
        let eventID = placement.request.event.id
        lifecycle.append("+" + eventID)
        renderedEventIDs.append(eventID)
        activeEventIDs.insert(eventID)
        renderedPlacements.append(placement)
        renderedElapsedSeconds.append(elapsedSeconds)
        return true
    }

    func completePreparation(_ preparationID: UInt64) {
        preparationCompletions[preparationID]?(
            .ready(DanmakuTextMetrics(width: 120, height: 24))
        )
    }

    func discardPreparation(preparationID: UInt64) {}

    func cancelPendingPreparations() {
        cancelPreparationCount += 1
    }

    func remove(eventID: String) {
        lifecycle.append("-" + eventID)
        activeEventIDs.remove(eventID)
    }

    func clearAll() {
        clearCount += 1
        activeEventIDs.removeAll()
    }

    func setPlaybackRate(_ rate: Double) {
        rates.append(rate)
    }

    func recompositeIfStill() {
        recomposites.append((clearCount, renderedEventIDs.count))
    }

    func setOpacity(_ opacity: DanmakuOpacity) {}

    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {}

    func stop() {
        stopCount += 1
        activeEventIDs.removeAll()
    }
}
