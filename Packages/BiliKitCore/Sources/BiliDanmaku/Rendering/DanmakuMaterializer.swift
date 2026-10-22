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
///   时间移除、替换并挂上全部弹幕，落在同一次 Core Animation 提交里；缓存全部命中时当场完成。按
///   `StagedCommitKind` 分两类：设置或屏幕引起的整张重排、打开弹幕与接管 surface 是整屏暂存，之后的
///   重新对齐不拆开它；分段到达引起的布局表替换可以被重新对齐取代。暂存期间的普通 reconcile 只立即移除
///   按自己的 placement 已不在取景框里的 layer（窗口缩小或时间推进），其余等提交：提交总按最新的表、
///   时间与取景框整屏对齐一次，窗口放大时新露出的部分要等到提交。
/// - 重新对齐：时间跳变（seek、拖动、回跳、换项后第一次读到新 item 的 D）之后使用，只看此刻的状态在前两者之间
///   选，见 `realign()`。新的对齐取代未完成的暂存提交时，新集合仍需要的在途与已就绪纹理都保留，只作废
///   不再需要的。
///
/// 媒体时间是宿主时钟层的显示时间 D：reconcile 与 backing scale 变化时由呈现控制器传入它在入口读到的值，
/// 纹理异步完成时自己经 `currentPosition` 重新读此刻的 D，所以迟到纹理是否挂上、暂存提交按哪一刻整屏对齐、
/// 腾纹理字节时谁已走完，都与画面同一条时间线。异步完成时读不到 D（时钟换绑或解绑之后；正常到不了，换绑、
/// 解绑与交还 surface 都先 `clear`，在途完成按 generation 丢弃）就不挂上、不提交，不沿用旧时间：结果照常
/// 记下，暂存的等待集合照常扣减；等齐了却没能提交的暂存由下一次有 D 的 reconcile 提交，普通 reconcile 也算。
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
        case staged(StagedCommitKind)
        case realign
    }

    /// 暂存提交能不能被之后的重新对齐取代。
    enum StagedCommitKind {
        /// 整屏暂存：设置、规划尺寸或 backing scale 引起的整张重排，打开弹幕，接管 surface。屏上弹幕的
        /// 车道会变，拆开上屏会新旧混排，所以重新对齐只在新集合上继续整屏暂存，连极小的回跳也不拆开它。
        case wholeScreen
        /// 可取代：重新对齐自己发起的暂存，以及分段到达引起的布局表替换。分段到达主要填补原本空着的区域，
        /// 拆开也不会新旧混排；若也受保护，拖进未缓存区域时分段陆续到达、每段都发起一次不可拆的暂存，
        /// 而拖动中要等的集合一直在换，画面会一直停着。
        case supersedable
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
    /// 正在等的暂存提交属于哪一类；只在 `awaitedByCommit` 非 nil 时有意义，`commit` 与 `clear` 时复位。
    private var stagedCommitKind = StagedCommitKind.supersedable
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
        case .staged(let kind):
            // 整屏暂存还在等时来了可取代的暂存（例如设置重排未完成时分段到达），新表仍是那次重排的一部分，
            // 保持整屏。
            let keepsWholeScreen = isCommitPending && stagedCommitKind == .wholeScreen
            beginStagedCommit(keepsWholeScreen ? .wholeScreen : kind)
        case .realign:
            realign()
        case .incremental where awaitedByCommit?.isEmpty == true:
            // 暂存已经等齐，只是纹理完成时读不到 D 没能提交：按这次的 D 提交。不提交的话它永远不会再有完成
            // 回调来推动，之后的普通 reconcile 都只移除、不挂上。
            commit()
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
        stagedCommitKind = .supersedable
        hasRetryableRejections = false
        unpreparable.removeAll(keepingCapacity: false)
    }

    /// 纹理按 backing scale 栅格化；scale 变化时作废在途与暂存的纹理，有暂存提交时按最近的表、取景框与
    /// `position`（呈现控制器在入口读到的 D）重新开始。
    ///
    /// 已在屏的弹幕不移除，之后的 reconcile 为它们按新 scale 准备纹理并原位替换。调用方必须先让 backend 换
    /// scale（它静默取消在途准备、不回调），再调用这里：反过来的话这里重开发出的请求会被那次取消吞掉。
    /// `position` 为 nil 时（正常到不了，见类型说明）放弃等待中的暂存，不按旧时间重开，下一次有 D 的
    /// reconcile 按当时的状态重新决定。
    func setBackingScale(_ scale: Double, at position: Double?) {
        guard scale != backingScale else { return }
        backingScale = scale
        preparationGeneration &+= 1
        backend.cancelPendingPreparations()
        pending.removeAll(keepingCapacity: false)
        parked.removeAll(keepingCapacity: false)
        guard isCommitPending else { return }
        guard let position else {
            awaitedByCommit = nil
            stagedCommitKind = .supersedable
            return
        }
        self.position = position
        beginStagedCommit(stagedCommitKind)
    }

    /// 发起 `kind` 类的暂存提交，见 `StagedCommitKind`。
    private func beginStagedCommit(_ kind: StagedCommitKind) {
        _ = requestStagedPreparations()
        stagedCommitKind = kind
        awaitPendingPreparations()
    }

    /// 时间跳变之后的对齐：先按暂存的方式发起准备（缓存命中的同步结果放进 `parked`），再只看
    /// 此刻的状态决定怎样上屏。
    ///
    /// - 已进场而缺纹理的不超过 `incrementalMissingTextureLimit`：当场提交，缺的各自就绪后出现。缓存
    ///   全部命中的跳转因此仍是一次调用里的整屏替换。
    /// - 缺得多、且这次对齐取代了还没完成的可取代暂存（上一步重新对齐或分段到达发起的）：已就绪的当场
    ///   挂上、取景框外的当场移除，其余仍暂存，齐了再一次挂上。连续拖动时每一步都取代上一步的暂存，拖进
    ///   未缓存区域时陆续到达的分段也一样，于是每一步都把已就绪的挂上，画面跟着走；停下之后剩下的在一次
    ///   提交里补齐。不这样做的话每一步都换一个新的等待集合，提交永远等不齐，拖动
    ///   期间屏上只剩旧 layer 各自滑出动画区间。
    /// - 缺得多、没有可取代的暂存（单次跳到没缓存的地方）：暂存，旧画面保留到新纹理齐了一次替换。
    ///
    /// 正在等的是整屏暂存（`StagedCommitKind.wholeScreen`）时，不按上面三条选，只在新集合上继续整屏
    /// 暂存：否则显示时间 D 自己的小幅回跳（速率 0 时往回 seek、在宿主时钟层的等待窗口里暂停）也会把
    /// 一次整屏替换拆成部分挂上、露出新旧表混在一起的画面。
    private func realign() {
        if isCommitPending, stagedCommitKind == .wholeScreen {
            beginStagedCommit(.wholeScreen)
            return
        }
        let supersedesCommit = isCommitPending
        stagedCommitKind = .supersedable
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
        stagedCommitKind = .supersedable
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

    /// 准备完成：暂存期间先放着，否则此刻仍在取景框里（车道按当前取景框、时间按此刻的 D）就立即挂上。
    ///
    /// 在 `prepare` 内同步回调（缓存命中、立即拒绝）时只记下结果，由发起请求的调用收尾，时间就是那次
    /// reconcile 传入的 D；异步回调时先读此刻的 D，再自己推进暂存提交，或在有被拒绝的请求时重新 reconcile
    /// 一次补上它们。异步回调读不到 D 时只记下结果、扣减暂存的等待集合，不挂上、不提交（见类型说明）。
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
            if awaitedByCommit != nil {
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
        if var awaited = awaitedByCommit {
            awaited.remove(eventID)
            awaitedByCommit = awaited
            if awaited.isEmpty, now != nil {
                commit()
            }
            return
        }
        guard now != nil else { return }
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
