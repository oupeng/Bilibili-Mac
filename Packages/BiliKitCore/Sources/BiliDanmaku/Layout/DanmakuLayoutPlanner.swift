import BiliApplication
import BiliModels
import Foundation

/// 决定弹幕布局的全部设置。
///
/// 包括车道几何与容量、滚动速度档、纹理的 backing scale（决定测量出的宽高）与过滤；任一项变化，
/// 整张布局表都要重新计算。
struct DanmakuLayoutParameters: Sendable, Equatable {
    let configuration: DanmakuLaneConfiguration
    let speedLevel: DanmakuSpeedLevel
    let backingScale: Double
    let filter: DanmakuFilter
}

/// 一个分段的确定性布局：每条通过过滤并被准入的弹幕的车道、层与运动时长，以及分段末尾的车道占用。
///
/// placement 的时间都是媒体时间，`admittedAtSeconds` 就是弹幕自己的时间点；按 (时间, ID) 排序。
/// `endOccupancy` 是下一分段布局的种子。
struct DanmakuSegmentLayout: Sendable {
    let index: Int
    let placements: [DanmakuLanePlacement]
    /// 本段 placement 的最长运动时长；查询某一时刻在屏上的弹幕时，只需往前看这么久。
    let maximumDurationSeconds: Double
    let endOccupancy: DanmakuLaneAllocator

    /// 在 `position` 时刻已进场或将在 `lookahead` 秒内进场、且尚未走完的 placement，按时间排序。
    func placements(
        at position: Double,
        lookahead: Double
    ) -> ArraySlice<DanmakuLanePlacement> {
        let earliest = position - maximumDurationSeconds
        let latest = position + lookahead
        var lower = 0
        var upper = placements.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if placements[middle].admittedAtSeconds <= earliest {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var end = lower
        while end < placements.count, placements[end].admittedAtSeconds <= latest {
            end += 1
        }
        return placements[lower..<end]
    }
}

/// 把已缓存的分段排成确定的布局：同一组已缓存分段、同一组设置总得到同样的车道。
///
/// 每段把通过过滤的事件按 (时间, ID) 排序，逐条在弹幕自己的时间点交给 `DanmakuLaneAllocator` 准入；
/// allocator 只用媒体时间，输入顺序与宽高确定时结果就确定。同屏上限（`hardMaximumActiveCount`）也在这里
/// 按同一规则丢弃，纹理字节上限不参与。
///
/// 分段边界接着上一段末尾的车道占用继续排，边界处不重叠；上一段已有的 ID 不在本段重复显示。上一段不在
/// 缓存里时本段从空占用开始排。所以第 N 段的车道取决于第 N-1 段当时是否在缓存：只有上一段在缓存、且它的
/// 种子链一直能接到第一段时，结果才与从头连续排一致；否则只在分段开头、两份占用收敛之前与之不同（实测多在
/// 一两条弹幕的最长时长之内）。缓存只有三段，从远处 seek 过来时常是后一种情况。上一段晚到时先排上一段，
/// 再以它末尾的占用为种子重排本段，屏上少数弹幕可能换一次车道；末尾占用变了才继续重排下一段。
///
/// 纯逻辑，可在后台调用；测量由调用方注入。检查 `Task.isCancelled`，被取消时返回 nil。
enum DanmakuLayoutPlanner {
    /// 每排这么多条弹幕检查一次取消。
    ///
    /// 一条弹幕的测量（未命中缓存时）约 10～20µs，准入更快，256 条对应约几毫秒：设置变化或换视频后，
    /// 作废的任务最多再跑这么久就停下。调小取消更及时，但每条都查 `Task.isCancelled` 的开销会显出来；
    /// 调大则作废的任务多占后台更久、新任务更晚开始。
    private static let cancellationCheckInterval = 256

    /// 为 `segments` 里每个分段给出布局；`existing` 是同一组设置下已有的布局，仍有效的原样沿用。
    ///
    /// 沿用的条件是：分段已有布局，且上一段没有被重排成不同的末尾占用。设置变化时调用方传空的
    /// `existing`，全部重排。不在 `segments` 里的分段不出现在结果中。
    static func layouts(
        for segments: [Int: [DanmakuEvent]],
        reusing existing: [Int: DanmakuSegmentLayout],
        parameters: DanmakuLayoutParameters,
        measure: (DanmakuEvent) -> DanmakuTextMetrics?
    ) -> [Int: DanmakuSegmentLayout]? {
        var result: [Int: DanmakuSegmentLayout] = [:]
        // 末尾占用与旧布局不同（或原本没有布局）的分段；它的下一段必须重排。
        var changedEnds: Set<Int> = []
        for index in segments.keys.sorted() {
            if let previous = existing[index], !changedEnds.contains(index - 1) {
                result[index] = previous
                continue
            }
            let seed =
                result[index - 1]?.endOccupancy
                ?? DanmakuLaneAllocator(configuration: parameters.configuration)
            guard
                let layout = layout(
                    index: index,
                    events: segments[index] ?? [],
                    seed: seed,
                    excludingIDs: Set(segments[index - 1]?.map(\.id) ?? []),
                    parameters: parameters,
                    measure: measure
                )
            else {
                return nil
            }
            result[index] = layout
            if existing[index].map({ !$0.endOccupancy.hasSameOccupancy(as: layout.endOccupancy) })
                ?? true
            {
                changedEnds.insert(index)
            }
        }
        return result
    }

    /// 从 `seed` 的车道占用开始排一个分段。
    ///
    /// 相邻分段可能重复给出同一条弹幕（同一 ID，时间也可能略有不同）：`excludingIDs` 是上一段的全部 ID，
    /// 这些弹幕只在上一段显示；同一段里重复的 ID 只取 (时间, ID) 顺序上的第一条。
    static func layout(
        index: Int,
        events: [DanmakuEvent],
        seed: DanmakuLaneAllocator,
        excludingIDs: Set<String>,
        parameters: DanmakuLayoutParameters,
        measure: (DanmakuEvent) -> DanmakuTextMetrics?
    ) -> DanmakuSegmentLayout? {
        var seenIDs = excludingIDs
        let ordered = events.filter(parameters.filter.allows)
            .sorted(by: DanmakuEvent.precedes)
            .filter { seenIDs.insert($0.id).inserted }
        var allocator = seed
        var placements: [DanmakuLanePlacement] = []
        var maximumDuration = 0.0
        for (offset, event) in ordered.enumerated() {
            if offset % cancellationCheckInterval == 0, Task.isCancelled {
                return nil
            }
            guard let metrics = measure(event) else { continue }
            let duration = DanmakuMotionPolicy.duration(
                for: event.mode,
                textWidth: metrics.width,
                planningWidth: parameters.configuration.planningWidth,
                speedLevel: parameters.speedLevel
            )
            let request = DanmakuLaneRequest(
                event: event,
                width: metrics.width,
                height: metrics.height,
                durationSeconds: duration
            )
            if let placement = allocator.admit(request, at: event.timeSeconds) {
                placements.append(placement)
                maximumDuration = max(maximumDuration, duration)
            }
        }
        return DanmakuSegmentLayout(
            index: index,
            placements: placements,
            maximumDurationSeconds: maximumDuration,
            endOccupancy: allocator
        )
    }
}
