import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 呈现测试的车道配置：默认 800 × 360pt（10 条车道）、12pt 间距、全屏显示区域、不叠放。
func configuration(
    surfaceWidth: Double = 800,
    surfaceHeight: Double = 360
) -> DanmakuLaneConfiguration {
    DanmakuLaneConfiguration(
        surfaceWidth: surfaceWidth,
        surfaceHeight: surfaceHeight,
        minimumHorizontalGap: 12,
        displayAreaFraction: 1
    )
}

/// 显示区域为全屏的取景框；默认与 `configuration()` 的规划画布一样大。
func viewport(width: Double = 800, height: Double = 360) -> DanmakuViewport {
    DanmakuViewport(width: width, height: height, displayAreaFraction: 1)
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
    surfaceWidth: Double = 800,
    surfaceHeight: Double = 360
) -> [Int: DanmakuSegmentLayout] {
    let lanes = configuration(surfaceWidth: surfaceWidth, surfaceHeight: surfaceHeight)
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
/// 记录在屏弹幕的 placement、清屏与画面尺寸，可延迟纹理准备由测试逐个完成；在屏集合变化或
/// 收到延迟的准备请求时检查等待条件。backing scale 变化时与 renderer 一样静默取消在途准备。
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
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    /// 每次 `updateSurfaceSize` 收到的宽高，按顺序。
    private(set) var surfaceSizes: [(width: Double, height: Double)] = []
    private var backingScale = DanmakuTextureRasterizer.defaultBackingScale
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
            notifyWaiters()
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

    func setOpacity(_ opacity: DanmakuOpacity) {}

    /// 与 renderer 一样：backing scale 变化时静默取消在途准备，不回调。
    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        surfaceSizes.append((width, height))
        if backingScale != self.backingScale {
            self.backingScale = backingScale
            delayedCompletions.removeAll()
        }
    }

    func stop() {
        stopCount += 1
        delayedCompletions.removeAll()
        installed.removeAll()
        notifyWaiters()
    }

    /// 等到状态满足 `isSatisfied`；每次在屏集合变化或收到延迟的准备请求时检查。
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

/// 呈现测试唯一的显示时间替身：测试直接设定宿主时钟层发布的 D；`time` 为 nil 表示读不到（从未绑定、换绑后
/// 新纪元还没写入）。
final class ManualDisplayClock: DanmakuDisplayClock, @unchecked Sendable {
    // 只在 MainActor 上的测试里读写，不跨线程；`@unchecked` 只为满足 port 的 Sendable 要求。
    var time: Double?

    init(time: Double? = nil) {
        self.time = time
    }

    func displayTime() -> Double? {
        time
    }
}

/// t 时刻屏上真正看得见的弹幕：在屏、已进场，且按自己的 placement 在取景框里还没走完。
///
/// 只看 backend 记录的 placement 与时刻，不看 materializer 的内部记录；前瞻挂上、还没进场的不算。
@MainActor
func visibleEventIDs(
    on backend: RecordingRenderingBackend,
    at time: Double,
    viewport: DanmakuViewport
) -> Set<String> {
    Set(
        backend.installed.values
            .filter { $0.admittedAtSeconds <= time && viewport.shows($0, at: time) }
            .map(\.request.event.id)
    )
}

/// 布局表在 t 时刻应该看得见的弹幕：直接由布局表与取景框求，不经过 materializer，不含前瞻。
func expectedVisibleEventIDs(
    in table: [Int: DanmakuSegmentLayout],
    at time: Double,
    viewport: DanmakuViewport
) -> Set<String> {
    Set(
        table.values.flatMap { layout in
            layout.placements(at: time, lookahead: 0)
                .filter { $0.admittedAtSeconds <= time && viewport.shows($0, at: time) }
                .map(\.request.event.id)
        }
    )
}

/// 可见性采样相对 D 的偏移（媒体秒）：此刻、区间中段、上次对齐覆盖的区间末端之前。
private let visibilitySampleOffsets = [0, 0.5, 1.4]

/// 显示时间停在 `displayTime` 时，此刻与之后 1.4 媒体秒内看得见的都与布局表一致。
@MainActor
func expectVisibilityMatchesTheTable(
    on backend: RecordingRenderingBackend,
    table: [Int: DanmakuSegmentLayout],
    viewport: DanmakuViewport,
    at displayTime: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for offset in visibilitySampleOffsets {
        let time = displayTime + offset
        #expect(
            visibleEventIDs(on: backend, at: time, viewport: viewport)
                == expectedVisibleEventIDs(in: table, at: time, viewport: viewport),
            "D + \(offset) 秒时看得见的集合与布局表不一致",
            sourceLocation: sourceLocation
        )
    }
}
