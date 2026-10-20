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
/// 拥有在屏 placement 的记录、在途纹理准备与「暂存提交」；不拥有布局表（`DanmakuLayoutCoordinator`）
/// 与 layer（backend），也不决定何时 reconcile（`DanmakuPresentationController`）。三种 reconcile
/// （`Mode`）：
/// - 普通：增删与布局替换立即生效，缺纹理的弹幕各自准备好时再挂上；按步长推进与窗口尺寸变化时使用。
/// - 暂存：先为应在屏而缺纹理的弹幕准备纹理，全部有结果（就绪或被拒）后才在一次调用里按此刻的媒体
///   时间移除、替换并挂上全部弹幕，落在同一次 Core Animation 提交里；缓存全部命中时当场完成。布局表
///   替换、打开弹幕与接管 surface 时使用，整屏因此一次换成新的样子。暂存期间的普通 reconcile 只立即移除
///   按自己的 placement 已不在取景框里的 layer（窗口缩小或时间推进），其余等提交：提交总按最新的表、
///   时间与取景框整屏对齐一次，窗口放大时新露出的部分要等到提交。
/// - 重新对齐：时间跳变（seek、拖动、回跳、换项后的第一个快照）之后使用，只看此刻的状态在前两者之间
///   选，见 `realign()`。新的对齐取代未完成的暂存提交时，新集合仍需要的在途与已就绪纹理都保留，只作废
///   不再需要的；正在等的是上面那类整屏暂存时，重新对齐不拆开它，只在新集合上继续整屏暂存。
///
/// `preparationGeneration` 在 `clear` 与 backing scale 变化时递增；准备请求带上发起时的值，完成时不等、
/// 或这条弹幕已不在待准备记录里（不再需要或已换成新的请求），结果就被丢弃。
@MainActor
final class DanmakuMaterializer {
    /// 提前挂上即将进场的弹幕的时长（媒体秒）。
    ///
    /// 普通 reconcile 每隔 `DanmakuPresentationController.reconcileStride` 做一次，前瞻必须比它长，
    /// 纹理才有时间在进场前准备好；呈现控制器的覆盖区间由它减去准备余量得出，所以前瞻总覆盖整个区间。
    /// 调大会同时挂着更多还没进场的 layer，调小则高密度时更容易迟到。
    static let lookaheadSeconds = 2.0

    /// 重新对齐时，已进场却还缺纹理的弹幕不超过这个数就走普通增量，超过才暂存等齐。
    ///
    /// 栅格化 2 个并发、单条通常是毫秒级，8 条大约一两帧内补齐：零星几条晚一两帧出现，不比整屏停在
    /// 旧画面上等更显眼；缺得更多时逐条蹦出就看得出来，改为暂存。只数已进场的：前瞻弹幕在进场前就绪
    /// 就不会晚出现，按步长推进时缺的几乎都是它们。调大则更多跳转逐条出现，调小则更多跳转要整屏等齐。
    static let incrementalMissingTextureLimit = 8

    /// reconcile 的方式，见类型说明。
    enum Mode {
        case incremental
        case staged
        case realign
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
    private var awaitedByCommit: Set<String>?
    /// 正在等的暂存提交是否由 `.staged`（布局表替换、打开弹幕、接管 surface）发起。
    ///
    /// 只在 `awaitedByCommit` 非 nil 时有意义，`commit` 与 `clear` 时复位。为 true 时重新对齐只换等待
    /// 集合，不走增量也不先挂上已就绪的部分，整屏仍在一次提交里换成新样子。
    private var stagedCommitReplacesWholeScreen = false
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
    /// 最近一次 reconcile 的取景框；暂存提交与迟到的纹理都按它判断可见。
    private var viewport = DanmakuViewport(width: 0, height: 0, displayAreaFraction: 0)

    init(backend: any DanmakuRenderingBackend) {
        self.backend = backend
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
            beginStagedCommit(replacingWholeScreen: true)
        case .realign:
            realign()
        case .incremental where isCommitPending:
            // 暂存提交未完成时窗口变了或时间按步长推进：取景框外已挂上的弹幕立即移除，否则锚点已按
            // 新窗口移动，缩小时会露出 N 以外车道的弹幕。只移除、不换 placement，提交前屏上仍是旧表；
            // 新露出的部分等提交，提交按最新的表、时间与取景框挂上。
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
        stagedCommitReplacesWholeScreen = false
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
            beginStagedCommit(replacingWholeScreen: stagedCommitReplacesWholeScreen)
        }
    }

    /// 发起暂存提交；`replacingWholeScreen` 为 true 时之后的重新对齐不会把它拆成部分提交。
    private func beginStagedCommit(replacingWholeScreen: Bool) {
        _ = requestStagedPreparations()
        stagedCommitReplacesWholeScreen = replacingWholeScreen
        awaitPendingPreparations()
    }

    /// 时间跳变之后的对齐：先按暂存的方式发起准备（缓存命中的同步结果放进 `parked`），再只看
    /// 此刻的状态决定怎样上屏。
    ///
    /// - 已进场而缺纹理的不超过 `incrementalMissingTextureLimit`：当场提交，缺的各自就绪后出现。缓存
    ///   全部命中的跳转因此仍是一次调用里的整屏替换。
    /// - 缺得多、且这次对齐取代了还没完成的暂存提交：已就绪的当场挂上、取景框外的当场移除，其余仍暂存，
    ///   齐了再一次挂上。连续拖动时每一步都取代上一步的暂存，于是每一步都把已就绪的挂上，画面跟着走；
    ///   停下之后剩下的在一次提交里补齐。不这样做的话每一步都换一个新的等待集合，提交永远等不齐，拖动
    ///   期间屏上只剩旧 layer 各自滑出动画区间。
    /// - 缺得多、没有取代暂存提交（单次跳到没缓存的地方）：整屏暂存，旧画面保留到新纹理齐了一次替换。
    ///
    /// 正在等的是 `.staged` 发起的整屏暂存（布局表替换等）时，不按上面三条选，只在新集合上继续整屏
    /// 暂存：否则恢复播放时的微小回跳之类也会把一次整屏替换拆成部分挂上、露出新旧表混在一起的画面。
    private func realign() {
        if isCommitPending, stagedCommitReplacesWholeScreen {
            beginStagedCommit(replacingWholeScreen: true)
            return
        }
        let supersedesCommit = isCommitPending
        let desired = requestStagedPreparations()
        let missingAdmitted = desired.count(where: { placement in
            let eventID = placement.request.event.id
            return placement.admittedAtSeconds <= position
                && installed[eventID] == nil
                && pending[eventID] != nil
        })
        if missingAdmitted <= Self.incrementalMissingTextureLimit {
            commit()
        } else if supersedesCommit {
            commit()
            awaitPendingPreparations()
        } else {
            awaitPendingPreparations()
        }
    }

    /// 让暂存提交从此刻开始等 `pending` 里的全部准备；没有要等的就当场提交。
    ///
    /// 新的等待集合取代旧的：之前已就绪、新集合仍需要的纹理留在 `parked`，并入这一次。
    private func awaitPendingPreparations() {
        awaitedByCommit = Set(pending.keys)
        if awaitedByCommit?.isEmpty == true {
            commit()
        }
    }

    /// 为此刻应在屏而缺纹理的弹幕发起准备，返回此刻应有的集合。
    ///
    /// 先把 `awaitedByCommit` 置为非 nil，同步回调（缓存命中）的结果放进 `parked` 而不是立即挂上，调用方
    /// 随后决定提交或继续等；新集合不再需要的在途与已就绪准备作废，仍需要的保留并换上新 placement。
    private func requestStagedPreparations() -> [DanmakuLanePlacement] {
        awaitedByCommit = []
        let desired = Self.desiredPlacements(in: table, at: position, viewport: viewport)
        discardPreparations(notIn: Self.byEventID(desired))
        for placement in desired {
            let eventID = placement.request.event.id
            if needsTexture(eventID), pending[eventID] == nil, parked[eventID] == nil {
                requestPreparation(for: placement)
            }
        }
        return desired
    }

    /// 结束暂存：按此刻的表与时间一次完成移除、替换，挂上 `parked` 里已就绪的纹理，再按最新状态补做
    /// 一次普通 reconcile（暂存期间推迟的增删都在这里完成）；还在途的准备之后各自就绪时挂上。
    ///
    /// 暂存的纹理都有了结果时调用；重新对齐决定走增量，或先挂上已就绪的部分时也直接调用。
    private func commit() {
        awaitedByCommit = nil
        stagedCommitReplacesWholeScreen = false
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

    /// 准备完成：暂存期间先放着，否则此刻仍在取景框里（车道与时间都按当前取景框）就立即挂上。
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
            } else if viewport.shows(preparation.placement, at: position) {
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
