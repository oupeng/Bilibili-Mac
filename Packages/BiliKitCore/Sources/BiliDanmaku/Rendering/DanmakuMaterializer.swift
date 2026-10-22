import BiliModels
import Foundation

/// 让 backend 上的弹幕 layer 等于布局表在当前媒体时间、当前取景框下应有的集合。
///
/// 对给定时刻 t，应在 backend 上的是布局表里 `admittedAt ≤ t + lookahead`、在取景框里可见到 t 之后、
/// 且车道落在取景框里的 placement（见 `DanmakuViewport`）：已经进场、还在窗口里的，加上不久就要进场、
/// 提前以将来的开始时间挂上的。layer 按媒体时间运动，所以同一张布局表下，seek 到 t 之后 reconcile 一次
/// 与连续推进到 t 得到同一组 layer；不需要补位、去重或投递游标。纹理迟到时挂上去也直接出现在中途应在
/// 的位置。窗口尺寸变化只换取景框、走普通 reconcile：放大时补上新露出的、正在飞的弹幕，缩小时移除被裁
/// 掉的。
///
/// 拥有在屏 placement 的记录、在途纹理准备与车道重排的暂存提交；不拥有布局表（`DanmakuLayoutCoordinator`）
/// 与 layer（backend），也不决定何时 reconcile（`DanmakuPresentationController`）。两种 reconcile（`Mode`）：
/// - 普通：增删与换车道立即生效，缺纹理的弹幕各自就绪、此刻仍应在屏就立即挂上，不为等别的弹幕扣住。时间推进与
///   跳变（seek、拖动、回跳）、分段到达、打开弹幕、接管 surface 与窗口尺寸变化都用它：跳变之后旧 layer 在新时刻
///   都落在自己的动画区间外，扣住新纹理只会让画面空得更久；缓存命中的纹理在发起请求的调用里同步就绪，所以
///   跳到已缓存的地方仍在一次调用里换成那一刻的样子，没命中的逐条出现。
/// - 暂存：只用于设置、规划尺寸或 backing scale 引起的整张重排。先为应在屏而缺纹理的弹幕准备纹理，发起时在途的
///   那一组全部有结果（就绪或被拒）后，才在一次调用里按此刻的媒体时间移除、换车道并挂上全部弹幕，落在同一次
///   Core Animation 提交里；缓存全部命中时当场完成。暂存期间的普通 reconcile 只立即移除按自己的 placement 已不在
///   取景框里的 layer（窗口缩小或时间推进），不发请求、不换车道：提交前屏上仍是旧表，等待集合从发起到提交不变，
///   所以拖动中也会提交。提交总按最新的表、时间与取景框整屏对齐一次，窗口放大时新露出的部分要等到提交。新的
///   整张重排取代未完成的暂存时，新集合仍需要的在途与已就绪纹理都保留，只作废不再需要的。
///
/// 媒体时间是宿主时钟层的显示时间 D：reconcile 与 backing scale 变化时由呈现控制器传入它在入口读到的值，
/// 纹理异步完成时自己经 `currentPosition` 重新读此刻的 D，所以迟到纹理是否挂上、暂存提交按哪一刻整屏对齐、
/// 腾纹理字节时谁已走完，都与画面同一条时间线。异步完成时读不到 D（时钟换绑或解绑之后；正常到不了，换绑、
/// 解绑与交还 surface 都先 `clear`，在途完成按 generation 丢弃）就不挂上，不沿用旧时间：结果交还 backend，
/// 有暂存时放弃整次暂存（见 `abandonStagedCommit()`），下一次有 D 的 reconcile 按当时的状态重来。
///
/// `preparationGeneration` 在 `clear` 与 backing scale 变化时递增；准备请求带上发起时的值，完成时不等、
/// 或这条弹幕已不在待准备记录里（不再需要或已换成新的请求），结果就被丢弃。
@MainActor
final class DanmakuMaterializer {
    /// 提前挂上即将进场的弹幕的时长（媒体秒）。
    ///
    /// 普通 reconcile 每隔 `DanmakuPresentationController.reconcileStride` 做一次，前瞻必须长于步长加相邻两次
    /// 检查的间隔，即将进场的弹幕才在进场前请求过纹理，余下的时间留给栅格化（见步长的说明）。调大会同时挂着
    /// 更多还没进场的 layer，调小则高密度时更容易迟到。
    static let lookaheadSeconds = 2.0

    /// reconcile 的方式，见类型说明。
    enum Mode {
        case incremental
        case staged
    }

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
    ///
    /// 发起时定为当时全部在途的准备，之后只随它们完成而减少，取空时提交。
    private var awaitedByCommit: Set<String>?
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
    /// 最近一次使用的 D：reconcile 传入的，或异步完成时重新读到的。
    private var position = 0.0
    /// 读此刻的 D，由呈现控制器提供；读不到时为 nil。
    private let currentPosition: @MainActor () -> Double?
    /// 最近一次 reconcile 的取景框；暂存提交与迟到的纹理都按它判断可见。
    private var viewport = DanmakuViewport(width: 0, height: 0, displayAreaFraction: 0)

    init(
        backend: any DanmakuRenderingBackend,
        currentPosition: @escaping @MainActor () -> Double?
    ) {
        self.backend = backend
        self.currentPosition = currentPosition
    }

    /// 是否有等待中的暂存提交。
    var isCommitPending: Bool { awaitedByCommit != nil }

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

    /// 按布局表、媒体时间与取景框对齐 backend；`mode` 见类型说明。
    func reconcile(
        table: [Int: DanmakuSegmentLayout],
        position: Double,
        viewport: DanmakuViewport,
        mode: Mode
    ) {
        self.table = table
        self.position = position
        self.viewport = viewport
        switch mode {
        case .staged:
            beginStagedCommit()
        case .incremental where isCommitPending:
            // 暂存提交未完成时窗口变了或时间变了：取景框外已挂上的弹幕立即移除，否则锚点已按新窗口移动，
            // 缩小时会露出 N 以外车道的弹幕。只移除、不换 placement、不发请求：提交前屏上仍是旧表，等待集合
            // 也不变；新露出与新进场的部分等提交，提交按最新的表、时间与取景框挂上。
            removeInstalledOutsideViewport()
        case .incremental:
            reconcileNow()
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
        hasRetryableRejections = false
        unpreparable.removeAll(keepingCapacity: false)
    }

    /// 纹理按 backing scale 栅格化；scale 变化时作废在途与暂存的纹理，有暂存提交时按最近的表、取景框与
    /// `position`（呈现控制器在入口读到的 D）重新开始。
    ///
    /// 已在屏的弹幕不移除，之后的 reconcile 为它们按新 scale 准备纹理并原位替换。调用方必须先让 backend 换
    /// scale（它静默取消在途准备、不回调），再调用这里：反过来的话这里重开发出的请求会被那次取消吞掉。
    /// `position` 为 nil 时（正常到不了，见类型说明）放弃等待中的暂存，不按旧时间重开。
    func setBackingScale(_ scale: Double, at position: Double?) {
        guard scale != backingScale else { return }
        backingScale = scale
        preparationGeneration &+= 1
        backend.cancelPendingPreparations()
        pending.removeAll(keepingCapacity: false)
        parked.removeAll(keepingCapacity: false)
        guard isCommitPending else { return }
        guard let position else {
            abandonStagedCommit()
            return
        }
        self.position = position
        beginStagedCommit()
    }

    /// 发起整张重排的暂存提交：为此刻应在屏而缺纹理的弹幕发起准备，再等此刻全部在途的准备；没有要等的就当场
    /// 提交。
    ///
    /// 先把 `awaitedByCommit` 置为非 nil，同步回调（缓存命中）的结果放进 `parked` 而不是立即挂上；新集合不再
    /// 需要的在途与已就绪准备作废，仍需要的保留并换上新 placement，并入这一次。等待集合在这里定下，提交之前
    /// 不再发请求（见 `reconcile`），所以它只会变小。
    private func beginStagedCommit() {
        awaitedByCommit = []
        let desired = Self.desiredPlacements(in: table, at: position, viewport: viewport)
        discardPreparations(notIn: Self.byEventID(desired))
        for placement in desired {
            let eventID = placement.request.event.id
            if needsTexture(eventID), pending[eventID] == nil, parked[eventID] == nil {
                requestPreparation(for: placement)
            }
        }
        let awaited = Set(pending.keys)
        awaitedByCommit = awaited
        if awaited.isEmpty {
            commit()
        }
    }

    /// 放弃等待中的暂存提交；只在读不到 D 时调用（正常到不了，见类型说明），不按旧时间提交，下一次有 D 的
    /// reconcile 按当时的状态重来。
    ///
    /// 已就绪与在途的准备逐条交还 backend：已就绪的不交还，会一直占着纹理准备 owner 的未完成名额；在途的留着，
    /// D 回来之后、下一次 reconcile 之前完成的会按新表挂上，与屏上旧表的车道混排。
    private func abandonStagedCommit() {
        guard isCommitPending else { return }
        for preparation in parked.values {
            backend.discardPreparation(preparationID: preparation.preparationID)
        }
        for preparation in pending.values {
            backend.discardPreparation(preparationID: preparation.preparationID)
        }
        parked.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        awaitedByCommit = nil
    }

    /// 结束暂存：按此刻的表与时间一次完成移除、换车道，挂上 `parked` 里已就绪的纹理，再按最新状态补做
    /// 一次普通 reconcile（暂存期间推迟的增删都在这里完成）；还在途的准备之后各自就绪时挂上。
    ///
    /// 等待集合取空时调用（发起时没有要等的也算）。
    private func commit() {
        awaitedByCommit = nil
        let desired = Self.desiredPlacements(in: table, at: position, viewport: viewport)
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
    }

    /// 普通 reconcile：立即移除与替换，缺纹理的发起准备。
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

    /// 移除按自己的 placement 已不在取景框里的 layer；不看布局表，暂存提交期间也不会提前换上新表。
    private func removeInstalledOutsideViewport() {
        for (eventID, placement) in installed where !viewport.shows(placement, at: position) {
            backend.remove(eventID: eventID)
            installed[eventID] = nil
            installedScales[eventID] = nil
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

    /// 准备完成：暂存期间先放着，否则此刻仍在取景框里（车道按当前取景框、时间按此刻的 D）就立即挂上。
    ///
    /// 在 `prepare` 内同步回调（缓存命中、立即拒绝）时只记下结果，由发起请求的调用收尾，时间就是那次
    /// reconcile 传入的 D；异步回调时先读此刻的 D，再自己推进暂存提交，或在有被拒绝的请求时重新 reconcile
    /// 一次补上它们。异步回调读不到 D 时不挂上，有暂存就放弃它（见类型说明）。
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
        let now = requestDepth > 0 ? position : currentPosition()
        if let now {
            position = now
        }
        switch result {
        case .ready:
            if isCommitPending {
                parked[eventID] = preparation
            } else if let now, viewport.shows(preparation.placement, at: now) {
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
        guard now != nil else {
            abandonStagedCommit()
            return
        }
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
