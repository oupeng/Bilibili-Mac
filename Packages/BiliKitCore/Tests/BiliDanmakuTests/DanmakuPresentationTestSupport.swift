import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 呈现测试的车道配置：800pt 宽、30pt 车道、全屏显示区域，只变化容量与高度。
func configuration(
    maximumActiveCount: Int = DanmakuLaneConfiguration.hardMaximumActiveCount,
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

/// 时间点与模式可变、文字与字号固定的弹幕。
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

/// 用测试测量把分段排成布局表；设置取 `configuration()` 与默认速度。
func layoutTable(
    _ segments: [Int: [DanmakuEvent]],
    surfaceWidth: Double = 800
) -> [Int: DanmakuSegmentLayout] {
    let base = configuration()
    let lanes = DanmakuLaneConfiguration(
        surfaceWidth: surfaceWidth,
        surfaceHeight: base.surfaceHeight,
        laneHeight: base.laneHeight,
        minimumHorizontalGap: base.minimumHorizontalGap,
        maximumActiveCount: base.maximumActiveCount,
        displayAreaFraction: base.displayAreaFraction
    )
    return DanmakuLayoutPlanner.layouts(
        for: segments,
        reusing: [:],
        parameters: DanmakuLayoutParameters(
            configuration: lanes,
            speedLevel: .default,
            backingScale: 2,
            filter: DanmakuFilter()
        ),
        measure: fixtureMetrics
    ) ?? [:]
}

/// 呈现测试唯一的渲染后端替身，不创建任何 layer。
///
/// 记录在屏弹幕的 placement、显隐、静止、清屏与重新合成请求，可延迟纹理准备由测试逐个完成；在屏集合
/// 每次变化时检查等待条件。
@MainActor
final class RecordingRenderingBackend: DanmakuRenderingBackend {
    /// 此刻在屏的弹幕与它们的 placement。
    private(set) var installed: [String: DanmakuLanePlacement] = [:]
    /// 每次安装的事件 ID，按顺序。
    private(set) var installedHistory: [String] = []
    private(set) var isHidden = false
    private(set) var isStill = false
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    private(set) var recompositeCount = 0
    private(set) var preparedEventIDs: [String] = []
    /// 为 true 时准备不立即完成，等测试调用 `completePreparations`。
    var delaysPreparation = false
    private var delayedCompletions:
        [(eventID: String, completion: @MainActor @Sendable (DanmakuPreparationResult) -> Void)] =
            []
    private var waiters:
        [UUID: (isSatisfied: @MainActor () -> Bool, continuation: CheckedContinuation<Void, Never>)] =
            [:]

    var installedEventIDs: Set<String> { Set(installed.keys) }
    var pendingPreparationCount: Int { delayedCompletions.count }

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
        preparedEventIDs.append(event.id)
        if delaysPreparation {
            delayedCompletions.append((event.id, completion))
        } else {
            completion(.ready(DanmakuTextMetrics(width: 120, height: 24)))
        }
    }

    /// 按发起顺序完成前 `count` 个延迟的准备（默认全部）。
    func completePreparations(_ count: Int? = nil) {
        let completing = Array(delayedCompletions.prefix(count ?? delayedCompletions.count))
        delayedCompletions.removeFirst(completing.count)
        for item in completing {
            item.completion(.ready(DanmakuTextMetrics(width: 120, height: 24)))
        }
    }

    @discardableResult
    func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64
    ) -> Bool {
        let eventID = placement.request.event.id
        guard installed[eventID] == nil else { return false }
        installed[eventID] = placement
        installedHistory.append(eventID)
        notifyWaiters()
        return true
    }

    @discardableResult
    func update(_ placement: DanmakuLanePlacement) -> Bool {
        let eventID = placement.request.event.id
        guard installed[eventID] != nil else { return false }
        installed[eventID] = placement
        notifyWaiters()
        return true
    }

    func discardPreparation(preparationID: UInt64) {}

    func cancelPendingPreparations() {
        delayedCompletions.removeAll()
    }

    func remove(eventID: String) {
        installed[eventID] = nil
        notifyWaiters()
    }

    func clearAll() {
        clearCount += 1
        delayedCompletions.removeAll()
        installed.removeAll()
        notifyWaiters()
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        notifyWaiters()
    }

    func setStill(_ still: Bool) {
        isStill = still
    }

    func recompositeIfStill() {
        recompositeCount += 1
    }

    func setOpacity(_ opacity: DanmakuOpacity) {}

    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {}

    func stop() {
        stopCount += 1
        delayedCompletions.removeAll()
        installed.removeAll()
        isHidden = false
        notifyWaiters()
    }

    /// 等到在屏状态满足 `isSatisfied`；每次在屏集合或显隐变化时检查。
    func waitUntil(_ isSatisfied: @escaping @MainActor () -> Bool) async {
        guard !isSatisfied() else { return }
        await withCheckedContinuation { continuation in
            waiters[UUID()] = (isSatisfied, continuation)
        }
    }

    private func notifyWaiters() {
        let ready = waiters.filter { $0.value.isSatisfied() }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }
}
