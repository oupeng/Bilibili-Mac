import BiliModels
import Foundation

/// 让 backend 上的弹幕 layer 等于布局表在当前媒体时间应有的集合。
///
/// 对给定时刻 t，应在 backend 上的是布局表里 `admittedAt ≤ t + lookahead` 且 `expiresAt > t` 的
/// placement：已经进场、还没走完的，加上不久就要进场、提前以将来的开始时间挂上的。layer 按媒体时间
/// 运动，所以同一张布局表下，seek 到 t 之后 reconcile 一次与连续推进到 t 得到同一组 layer；
/// 不需要补位、去重或投递游标。纹理迟到时挂上去也直接出现在中途应在的位置。
///
/// 拥有在屏 placement 的记录、在途纹理准备与「暂存提交」；不拥有布局表（`DanmakuLayoutCoordinator`）
/// 与 layer（backend）。两种 reconcile：
/// - 普通：增删与布局替换立即生效，缺纹理的弹幕各自准备好时再挂上；时间推进时使用。
/// - 暂存：先为应在屏而缺纹理的弹幕准备纹理，全部有结果（就绪或被拒）后才在一次调用里按此刻的媒体
///   时间移除、替换并挂上全部弹幕，落在同一次 Core Animation 提交里；缓存全部命中时当场完成。布局表
///   替换、落地、打开弹幕与接管 surface 时使用，整屏因此一次换成新的样子。暂存期间的普通 reconcile
///   推迟到提交之后再做一次。
///
/// `preparationGeneration` 在 `clear` 与 backing scale 变化时递增；准备请求带上发起时的值，完成时不等、
/// 或这条弹幕已不在待准备记录里（不再需要或已换成新的请求），结果就被丢弃。
@MainActor
final class DanmakuMaterializer {
    /// 提前挂上即将进场的弹幕的时长（媒体秒）。
    ///
    /// 普通 reconcile 每隔 `DanmakuPresentationController.reconcileStride` 做一次，前瞻必须比它长，
    /// 纹理才有时间在进场前准备好。调大会同时挂着更多还没进场的 layer，调小则高密度时更容易迟到。
    static let lookaheadSeconds = 2.0

    private struct Preparation {
        let preparationID: UInt64
        var placement: DanmakuLanePlacement
    }

    private let backend: any DanmakuRenderingBackend

    /// backend 上每条在屏弹幕当前使用的 placement。
    private(set) var installed: [String: DanmakuLanePlacement] = [:]
    /// 每条在屏弹幕的纹理按哪个 backing scale 栅格化，是这件事唯一的记录；与当前 scale 不同的要重新
    /// 准备、原位换纹理，renderer 不另记。
    private var installedScales: [String: Double] = [:]
    /// 已发起、尚未完成的纹理准备。
    private var pending: [String: Preparation] = [:]
    /// 暂存提交期间已就绪、等提交时一起挂上的纹理。
    private var parked: [String: Preparation] = [:]
    /// 暂存提交还在等的弹幕；为 nil 表示没有暂存提交。
    private var awaitedByCommit: Set<String>?
    /// 暂存期间来了普通 reconcile，提交之后补做一次。
    private var reconcilesAfterCommit = false
    /// 准备因容量被拒绝过；下一次准备完成时重新 reconcile，补上它们。
    private var hasRetryableRejections = false
    /// 纹理无法生成的弹幕（文本无效、超出尺寸），`clear` 之前不再请求。
    private var unpreparable: Set<String> = []
    private var preparationGeneration: UInt64 = 0
    /// 正在发起准备请求的调用层数；大于 0 时同步回调只记下结果，不嵌套推进提交或 reconcile。
    private var requestDepth = 0
    private var nextPreparationID: UInt64 = 0
    private var backingScale = DanmakuTextureRasterizer.defaultBackingScale
    private var table: [Int: DanmakuSegmentLayout] = [:]
    private var position = 0.0

    init(backend: any DanmakuRenderingBackend) {
        self.backend = backend
    }

    /// 是否有等待中的暂存提交。
    var isCommitPending: Bool { awaitedByCommit != nil }

    /// 布局表在 `position` 时刻应在 backend 上的 placement，按 (时间, ID) 排序。
    static func desiredPlacements(
        in table: [Int: DanmakuSegmentLayout],
        at position: Double
    ) -> [DanmakuLanePlacement] {
        var desired: [DanmakuLanePlacement] = []
        for layout in table.values {
            let candidates = layout.placements(at: position, lookahead: lookaheadSeconds)
            desired.append(contentsOf: candidates.filter { $0.expiresAtSeconds > position })
        }
        desired.sort(by: DanmakuLanePlacement.precedes)
        return desired
    }

    /// 按事件 ID 索引；ID 重复（远端数据不可信）时取时间在前的一条，不崩溃。
    private static func byEventID(
        _ placements: [DanmakuLanePlacement]
    ) -> [String: DanmakuLanePlacement] {
        Dictionary(placements.map { ($0.request.event.id, $0) }) { first, _ in first }
    }

    /// 按布局表与媒体时间对齐 backend；`staged` 见类型说明。
    func reconcile(
        table: [Int: DanmakuSegmentLayout],
        position: Double,
        staged: Bool
    ) {
        self.table = table
        self.position = position
        if staged {
            beginStagedCommit()
        } else if isCommitPending {
            reconcilesAfterCommit = true
        } else {
            reconcileNow()
            backend.recompositeIfStill()
        }
    }

    /// 移除全部 layer 并作废在途准备；暂存提交随之取消。
    func clear() {
        preparationGeneration &+= 1
        backend.cancelPendingPreparations()
        backend.clearAll()
        installed.removeAll(keepingCapacity: false)
        installedScales.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        parked.removeAll(keepingCapacity: false)
        awaitedByCommit = nil
        reconcilesAfterCommit = false
        hasRetryableRejections = false
        unpreparable.removeAll(keepingCapacity: false)
    }

    /// 纹理按 backing scale 栅格化；scale 变化时作废在途与暂存的纹理，有暂存提交时按最近的表与时间重新开始。
    ///
    /// 已在屏的弹幕不移除，之后的 reconcile 为它们按新 scale 准备纹理并原位替换。
    func setBackingScale(_ scale: Double) {
        guard scale != backingScale else { return }
        backingScale = scale
        preparationGeneration &+= 1
        backend.cancelPendingPreparations()
        pending.removeAll(keepingCapacity: false)
        parked.removeAll(keepingCapacity: false)
        if isCommitPending {
            beginStagedCommit()
        }
    }

    private func beginStagedCommit() {
        // 新的暂存提交取代旧的：旧的已就绪纹理仍可用，并入这一次。
        awaitedByCommit = []
        let desired = Self.desiredPlacements(in: table, at: position)
        let desiredByID = Self.byEventID(desired)
        discardPreparations(notIn: desiredByID)
        for placement in desired {
            let eventID = placement.request.event.id
            if needsTexture(eventID), pending[eventID] == nil, parked[eventID] == nil {
                requestPreparation(for: placement)
            }
        }
        awaitedByCommit = Set(pending.keys)
        if awaitedByCommit?.isEmpty == true {
            commit()
        }
    }

    /// 暂存的纹理都有了结果：按此刻的表与时间一次完成移除、替换与挂上，再补做推迟的普通 reconcile。
    private func commit() {
        awaitedByCommit = nil
        reconcilesAfterCommit = false
        let desired = Self.desiredPlacements(in: table, at: position)
        let desiredByID = Self.byEventID(desired)
        let ready = parked
        parked.removeAll(keepingCapacity: false)
        removeInstalled(notIn: desiredByID)
        // 按 (时间, ID) 顺序挂上：纹理字节吃紧时先进场的优先，结果与纹理完成的先后无关。
        for placement in desired {
            guard let preparation = ready[placement.request.event.id] else { continue }
            installPrepared(placement, preparationID: preparation.preparationID)
        }
        for (eventID, preparation) in ready where desiredByID[eventID] == nil {
            backend.discardPreparation(preparationID: preparation.preparationID)
        }
        reconcileNow()
        backend.recompositeIfStill()
    }

    /// 普通 reconcile：立即移除与替换，缺纹理的发起准备。
    private func reconcileNow() {
        let desired = Self.desiredPlacements(in: table, at: position)
        let desiredByID = Self.byEventID(desired)
        removeInstalled(notIn: desiredByID)
        discardPreparations(notIn: desiredByID)
        for placement in desired where needsTexture(placement.request.event.id) {
            if pending[placement.request.event.id] == nil {
                requestPreparation(for: placement)
            }
        }
    }

    /// 移除不再需要的 layer；仍需要但 placement 变了的（重新布局）就地换成新 placement。
    ///
    /// 纹理按旧 scale 栅格化的不在这里换：它们已在准备新纹理，挂上时连同新 placement 原位替换。
    private func removeInstalled(notIn desiredByID: [String: DanmakuLanePlacement]) {
        for (eventID, placement) in installed {
            guard let desired = desiredByID[eventID] else {
                backend.remove(eventID: eventID)
                installed[eventID] = nil
                installedScales[eventID] = nil
                continue
            }
            guard desired != placement, !needsTexture(eventID) else { continue }
            if backend.update(desired) {
                installed[eventID] = desired
            } else {
                backend.remove(eventID: eventID)
                installed[eventID] = nil
                installedScales[eventID] = nil
            }
        }
    }

    /// 这条弹幕要不要准备纹理：还没挂上，或挂着的纹理是按旧 backing scale 栅格化的。
    private func needsTexture(_ eventID: String) -> Bool {
        installedScales[eventID] != backingScale
    }

    /// 丢弃不再需要的在途与暂存准备；仍需要的换上最新的 placement。
    private func discardPreparations(notIn desiredByID: [String: DanmakuLanePlacement]) {
        for (eventID, preparation) in pending {
            if let desired = desiredByID[eventID] {
                pending[eventID]?.placement = desired
            } else {
                pending[eventID] = nil
                backend.discardPreparation(preparationID: preparation.preparationID)
            }
        }
        for (eventID, preparation) in parked where desiredByID[eventID] == nil {
            parked[eventID] = nil
            backend.discardPreparation(preparationID: preparation.preparationID)
        }
    }

    /// 先登记再请求：缓存命中会在 `prepare` 内同步回调。
    private func requestPreparation(for placement: DanmakuLanePlacement) {
        let event = placement.request.event
        guard !unpreparable.contains(event.id) else { return }
        nextPreparationID &+= 1
        let preparationID = nextPreparationID
        let generation = preparationGeneration
        pending[event.id] = Preparation(preparationID: preparationID, placement: placement)
        requestDepth += 1
        defer { requestDepth -= 1 }
        backend.prepare(
            event,
            preparationID: preparationID
        ) { [weak self] result in
            self?.completePreparation(
                eventID: event.id,
                preparationID: preparationID,
                generation: generation,
                result: result
            )
        }
    }

    /// 准备完成：暂存期间先放着，否则还没走完就立即挂上。
    ///
    /// 在 `prepare` 内同步回调（缓存命中、立即拒绝）时只记下结果，由发起请求的调用收尾；异步回调时
    /// 自己推进暂存提交，或在有被拒绝的请求时重新 reconcile 一次补上它们。
    private func completePreparation(
        eventID: String,
        preparationID: UInt64,
        generation: UInt64,
        result: DanmakuPreparationResult
    ) {
        guard generation == preparationGeneration,
            let preparation = pending[eventID],
            preparation.preparationID == preparationID
        else {
            backend.discardPreparation(preparationID: preparationID)
            return
        }
        pending[eventID] = nil
        switch result {
        case .ready:
            if awaitedByCommit != nil {
                parked[eventID] = preparation
            } else if preparation.placement.expiresAtSeconds > position {
                installPrepared(preparation.placement, preparationID: preparationID)
            } else {
                backend.discardPreparation(preparationID: preparationID)
            }
        case .rejected(.capacity):
            hasRetryableRejections = true
        case .rejected(.invalidInput), .rejected(.oversized):
            unpreparable.insert(eventID)
        }
        guard requestDepth == 0 else { return }
        if var awaited = awaitedByCommit {
            awaited.remove(eventID)
            awaitedByCommit = awaited
            if awaited.isEmpty {
                commit()
            }
            return
        }
        if hasRetryableRejections {
            hasRetryableRejections = false
            reconcileNow()
        }
        backend.recompositeIfStill()
    }

    /// 挂上或原位替换一条弹幕；为腾纹理字节被 backend 移除的弹幕从记录里删掉，之后的 reconcile 再请求。
    private func installPrepared(_ placement: DanmakuLanePlacement, preparationID: UInt64) {
        let result = backend.install(
            placement,
            preparationID: preparationID,
            at: position
        )
        for eventID in result.evictedEventIDs {
            installed[eventID] = nil
            installedScales[eventID] = nil
        }
        if result.isInstalled {
            installed[placement.request.event.id] = placement
            installedScales[placement.request.event.id] = backingScale
        }
    }
}
