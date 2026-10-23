import BiliModels
import Foundation

/// 让 backend 上的弹幕 layer 等于布局表在当前媒体时间、当前取景框下应有的集合。
///
/// 对给定时刻 t，应在 backend 上的是布局表里 `admittedAt ≤ t + lookahead`、在取景框里可见到 t 之后、
/// 且车道落在取景框里的 placement（见 `DanmakuViewport`）：已经进场、还在窗口里的，加上不久就要进场、
/// 提前以将来的开始时间挂上的。layer 按媒体时间运动，所以同一张布局表下，seek 到 t 之后 reconcile 一次
/// 与连续推进到 t 得到同一组 layer；不需要补位、去重或投递游标。纹理迟到时挂上去也直接出现在中途应在
/// 的位置。窗口尺寸变化只换取景框、照常 reconcile：放大时补上新露出的、正在飞的弹幕，缩小时移除被裁
/// 掉的。
///
/// 拥有在屏 placement 的记录与在途纹理准备；不拥有布局表（`DanmakuLayoutCoordinator`）与 layer（backend），
/// 也不决定何时 reconcile（`DanmakuPresentationController`）。每次 reconcile 都立即增删、换车道，缺纹理的弹幕
/// 各自就绪、此刻仍应在屏就立即挂上，不为等别的弹幕扣住。时间推进与跳变（seek、拖动、回跳）、分段到达、
/// 整张重排、打开弹幕、接管 surface 与窗口尺寸变化都是这一种：
/// - 跳变之后旧 layer 在新时刻都落在自己的动画区间外，扣住新纹理只会让画面空得更久；缓存命中的纹理在发起
///   请求的调用里同步就绪，所以跳到已缓存的地方仍在一次调用里换成那一刻的样子，没命中的逐条出现。
/// - 整张重排（设置、规划尺寸或 backing scale 变化）时纹理与车道无关，在屏的弹幕在新表到来的同一次调用里
///   原位换车道，命中缓存的新弹幕同时出现，没命中的逐条出现；屏上的 placement 因此总出自当前布局表，任何
///   时刻都不新旧混排。
///
/// 媒体时间是宿主时钟层的显示时间 D：reconcile 时由呈现控制器传入它在入口读到的值，纹理异步完成时自己经
/// `currentDisplayTime` 重新读此刻的 D，所以迟到纹理是否挂上、腾纹理字节时谁已走完，都与画面同一条时间线。
/// 异步完成时读不到 D（时钟换绑或解绑之后；正常到不了，换绑、解绑与交还 surface 都先 `clear`，在途完成按
/// generation 丢弃）就不挂上、交还 backend，不沿用旧时间；下一次有 D 的 reconcile 按当时的状态重来。
///
/// `preparationGeneration` 在 `clear` 与 backing scale 变化时递增；准备请求带上发起时的值，完成时不等、
/// 或这条弹幕已不在待准备记录里（不再需要或已换成新的请求），结果就被丢弃。
@MainActor
final class DanmakuMaterializer {
    /// 提前挂上即将进场的弹幕的时长（媒体秒）。
    ///
    /// 按步长推进时每隔 `DanmakuPresentationController.reconcileStride` reconcile 一次，前瞻必须长于步长加相邻两次
    /// 检查的间隔，即将进场的弹幕才在进场前请求过纹理，余下的时间留给栅格化（见步长的说明）。调大会同时挂着
    /// 更多还没进场的 layer，调小则高密度时更容易迟到。
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
    /// 准备因容量被拒绝过；下一次准备完成时重新 reconcile，补上它们。
    private var hasRetryableRejections = false
    /// 在当前 backing scale 下纹理无法生成的弹幕（文本无效、超出尺寸），`clear` 或换 scale 之前不再请求，
    /// 所以超限的弹幕在同一 scale 下只失败一次。
    ///
    /// 换 scale 时清空：尺寸上限按像素算，在 2x 下超限的长文本在 1x 下可能放得下。布局表按当前 scale 测量、
    /// 本不含超限的弹幕，记下它们是因为换 scale 后新表落地之前仍按旧表对齐；不清的话，挪回放得下它的屏幕后
    /// 新表含它却不再请求。文本无效与 scale 无关，同样不进布局表，清掉最多多请求一次。
    private var unpreparable: Set<String> = []
    private var preparationGeneration: UInt64 = 0
    /// 正在发起准备请求的调用层数；大于 0 时同步回调只记下结果，不嵌套 reconcile。
    private var requestDepth = 0
    private var nextPreparationID: UInt64 = 0
    private var backingScale = DanmakuTextureRasterizer.defaultBackingScale
    private var table: [Int: DanmakuSegmentLayout] = [:]
    /// 最近一次使用的 D：reconcile 传入的，或异步完成时重新读到的。
    private var position = 0.0
    /// 读此刻的 D，由呈现控制器提供；读不到时为 nil。
    private let currentDisplayTime: @MainActor () -> Double?
    /// 最近一次 reconcile 的取景框；迟到的纹理按它判断可见。
    private var viewport = DanmakuViewport(width: 0, height: 0, displayAreaFraction: 0)

    init(
        backend: any DanmakuRenderingBackend,
        currentDisplayTime: @escaping @MainActor () -> Double?
    ) {
        self.backend = backend
        self.currentDisplayTime = currentDisplayTime
    }

    /// 布局表在 `position` 时刻、`viewport` 取景框下应在 backend 上的 placement，按 (时间, ID) 排序。
    static func desiredPlacements(
        in table: [Int: DanmakuSegmentLayout],
        at position: Double,
        viewport: DanmakuViewport
    ) -> [DanmakuLanePlacement] {
        var desired: [DanmakuLanePlacement] = []
        for layout in table.values {
            let candidates = layout.placements(at: position, lookahead: lookaheadSeconds)
            desired.append(contentsOf: candidates.filter { viewport.shows($0, at: position) })
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

    /// 按布局表、媒体时间与取景框对齐 backend：立即移除不再应在屏的、原位换车道，缺纹理的发起准备。
    func reconcile(
        table: [Int: DanmakuSegmentLayout],
        position: Double,
        viewport: DanmakuViewport
    ) {
        self.table = table
        self.position = position
        self.viewport = viewport
        reconcileNow()
    }

    /// 移除全部 layer 并作废在途准备。
    func clear() {
        preparationGeneration &+= 1
        backend.cancelPendingPreparations()
        backend.clearAll()
        installed.removeAll(keepingCapacity: false)
        installedScales.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        hasRetryableRejections = false
        unpreparable.removeAll(keepingCapacity: false)
    }

    /// 纹理按 backing scale 栅格化；scale 变化时作废在途准备、忘掉在旧 scale 下无法生成的记录，自己不发请求。
    ///
    /// 已在屏的弹幕不移除，之后的 reconcile 为它们按新 scale 准备纹理并原位替换。backend 换 scale 时静默取消
    /// 在途准备、不回调；它与这里之间不得发准备请求：这里不发请求，所以两步谁先谁后都一样，但若先调用这里、
    /// 两步之间又发了请求，这些请求被 backend 随后的取消吞掉，`pending` 里留着永远不回调的记录，这些弹幕再也
    /// 不会被请求。
    func setBackingScale(_ scale: Double) {
        guard scale != backingScale else { return }
        backingScale = scale
        preparationGeneration &+= 1
        backend.cancelPendingPreparations()
        pending.removeAll(keepingCapacity: false)
        unpreparable.removeAll(keepingCapacity: false)
    }

    /// 按最近一次的表、时间与取景框立即移除与替换，缺纹理的发起准备。
    private func reconcileNow() {
        let desired = Self.desiredPlacements(in: table, at: position, viewport: viewport)
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
    /// 纹理按旧 backing scale 栅格化的也立即换：旧纹理按新 placement 拉伸，新纹理就绪后原位替换，所以屏上的
    /// placement 总出自当前布局表。新纹理被 backend 的纹理字节上限拒绝时，这条弹幕一直用旧纹理到离场，但车道
    /// 仍是新表的，不与新表的邻居重叠。
    private func removeInstalled(notIn desiredByID: [String: DanmakuLanePlacement]) {
        for (eventID, placement) in installed {
            guard let desired = desiredByID[eventID] else {
                backend.remove(eventID: eventID)
                installed[eventID] = nil
                installedScales[eventID] = nil
                continue
            }
            guard desired != placement else { continue }
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

    /// 丢弃不再需要的在途准备；仍需要的换上最新的 placement。
    private func discardPreparations(notIn desiredByID: [String: DanmakuLanePlacement]) {
        for (eventID, preparation) in pending {
            if let desired = desiredByID[eventID] {
                pending[eventID]?.placement = desired
            } else {
                pending[eventID] = nil
                backend.discardPreparation(preparationID: preparation.preparationID)
            }
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

    /// 准备完成：此刻仍在取景框里（车道按当前取景框、时间按此刻的 D）就立即挂上，否则交还 backend。
    ///
    /// 在 `prepare` 内同步回调（缓存命中、立即拒绝）时只记下结果，由发起请求的调用收尾，时间就是那次
    /// reconcile 传入的 D；异步回调时先读此刻的 D，有被拒绝的请求时再重新 reconcile 一次补上它们。异步回调
    /// 读不到 D 时不挂上（见类型说明）。
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
        let now = requestDepth > 0 ? position : currentDisplayTime()
        if let now {
            position = now
        }
        switch result {
        case .ready:
            if let now, viewport.shows(preparation.placement, at: now) {
                installPrepared(preparation.placement, preparationID: preparationID)
            } else {
                backend.discardPreparation(preparationID: preparationID)
            }
        case .rejected(.capacity):
            hasRetryableRejections = true
        case .rejected(.invalidInput), .rejected(.oversized):
            unpreparable.insert(eventID)
        }
        guard requestDepth == 0, now != nil, hasRetryableRejections else { return }
        hasRetryableRejections = false
        reconcileNow()
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
