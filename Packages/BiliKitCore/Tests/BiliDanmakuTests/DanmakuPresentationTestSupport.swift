import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 呈现测试的车道配置：800 × 360pt（10 条车道）、12pt 间距、全屏显示区域，只变化宽度。
func configuration(surfaceWidth: Double = 800) -> DanmakuLaneConfiguration {
    DanmakuLaneConfiguration(
        surfaceWidth: surfaceWidth,
        surfaceHeight: 360,
        minimumHorizontalGap: 12,
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
    let lanes = configuration(surfaceWidth: surfaceWidth)
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
/// 记录在屏弹幕的 placement、静止、清屏与画面尺寸，可延迟纹理准备由测试逐个完成；在屏集合
/// 每次变化时检查等待条件。
@MainActor
final class RecordingRenderingBackend: DanmakuRenderingBackend {
    /// 此刻在屏的弹幕与它们的 placement。
    private(set) var installed: [String: DanmakuLanePlacement] = [:]
    /// 每次新挂上的事件 ID，按顺序。
    private(set) var installedHistory: [String] = []
    /// 每次原位替换（同一 ID 已在屏时再次安装）的事件 ID，按顺序。
    private(set) var replacedHistory: [String] = []
    /// 每次移除的事件 ID，按顺序。
    private(set) var removedHistory: [String] = []
    private(set) var isStill = false
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    /// 每次 `updateSurfaceSize` 收到的宽高，按顺序。
    private(set) var surfaceSizes: [(width: Double, height: Double)] = []
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
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        if delaysPreparation {
            delayedCompletions.append((event.id, completion))
        } else {
            completion(.ready(DanmakuTextMetrics(width: 120, height: 24)))
        }
    }

    /// 按发起顺序完成前 `count` 个延迟的准备（默认全部）；`reversed` 时倒序完成它们。
    func completePreparations(_ count: Int? = nil, reversed: Bool = false) {
        let completing = Array(delayedCompletions.prefix(count ?? delayedCompletions.count))
        delayedCompletions.removeFirst(completing.count)
        for item in reversed ? completing.reversed() : completing {
            item.completion(.ready(DanmakuTextMetrics(width: 120, height: 24)))
        }
    }

    /// 不限纹理字节；已在屏的同一 ID 视为原位替换，记入 `replacedHistory`。
    @discardableResult
    func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        at position: Double
    ) -> DanmakuInstallResult {
        let eventID = placement.request.event.id
        if installed[eventID] != nil {
            replacedHistory.append(eventID)
        } else {
            installedHistory.append(eventID)
        }
        installed[eventID] = placement
        notifyWaiters()
        return DanmakuInstallResult(isInstalled: true, evictedEventIDs: [])
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
        removedHistory.append(eventID)
        installed[eventID] = nil
        notifyWaiters()
    }

    func clearAll() {
        clearCount += 1
        delayedCompletions.removeAll()
        installed.removeAll()
        notifyWaiters()
    }

    func setStill(_ still: Bool) {
        isStill = still
    }

    func recompositeIfStill() {}

    func setOpacity(_ opacity: DanmakuOpacity) {}

    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        surfaceSizes.append((width, height))
    }

    func stop() {
        stopCount += 1
        delayedCompletions.removeAll()
        installed.removeAll()
        notifyWaiters()
    }

    /// 等到在屏状态满足 `isSatisfied`；每次在屏集合变化时检查。
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
