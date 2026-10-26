import BiliApplication
import BiliModels
import Observation

/// 「收藏到…」面板的状态：一个视频在自己各收藏夹里的归属、用户勾选的结果，以及由二者算出的改动。
///
/// 每次打开面板构造一份，由 App 的写入协调者持有到面板关闭。拥有归属的读取 Task（`load` 发出，`cancel` 与释放时取消）与
/// 勾选；不拥有写入（确认时协调者取 `change` 发出，Task 归协调者），也不拥有账户复核（读取遇到凭据失败时经
/// `onCredentialFailure` 交给协调者）。账户在构造时固定：读取用它；协调者在重试与确认前核对窗口账户仍是它，窗口账户
/// 一变就关闭面板，所以这里不再核对。每次打开都重读归属、不沿用侧栏的列表：勾选的初始状态必须是服务端此刻的状态，
/// 否则确认会发出用户没有想要的加入或移出。
@MainActor
@Observable
public final class FavoritePickerModel: Identifiable {
    /// 面板的读取状态。
    public enum Phase: Sendable, Equatable {
        case loading
        /// 按接口顺序（与侧栏一致）。
        case loaded([FavoriteFolderMembership])
        case failed(ContentApplicationError)
    }

    public let target: VideoWriteTarget
    public let accountID: Int64
    public private(set) var phase = Phase.loading
    /// 勾选的收藏夹；读取成功时取服务端的归属作初始值。
    public private(set) var selectedFolderIDs: Set<Int64> = []

    @ObservationIgnored private let useCase: FavoritesUseCase
    @ObservationIgnored private let onCredentialFailure: @MainActor () -> Void
    @ObservationIgnored private let loadTask = LatestTask()

    /// `onCredentialFailure` 在读取因凭据缺失或失效结束时调用一次（规则同资料库的 `LibraryAccountRevalidation`）。
    public init(
        target: VideoWriteTarget,
        accountID: Int64,
        useCase: FavoritesUseCase,
        onCredentialFailure: @escaping @MainActor () -> Void
    ) {
        self.target = target
        self.accountID = accountID
        self.useCase = useCase
        self.onCredentialFailure = onCredentialFailure
    }

    /// 勾选与初始归属的差异；没有改动或还没读到归属时为 nil，面板据此禁用确认。
    public var change: FavoriteMembershipChange? {
        guard case .loaded(let memberships) = phase else { return nil }
        let initial = Self.containingFolderIDs(memberships)
        return FavoriteMembershipChange(
            target: target,
            adding: selectedFolderIDs.subtracting(initial),
            removing: initial.subtracting(selectedFolderIDs)
        )
    }

    /// 读取归属（面板出现与失败重试）；新的读取替换旧的，勾选回到服务端的状态。
    public func load() {
        phase = .loading
        selectedFolderIDs = []
        let useCase = useCase
        let target = target
        let accountID = accountID
        loadTask.replace { [weak self] isCurrent in
            do {
                let memberships = try await useCase.memberships(of: target, ownerID: accountID)
                guard let self, isCurrent() else { return }
                selectedFolderIDs = Self.containingFolderIDs(memberships)
                phase = .loaded(memberships)
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换，账户已不是打开面板时的那个，给出可重试的失败。
                guard let self, isCurrent() else { return }
                phase = .failed(.authenticationUnavailable)
            } catch {
                guard let self, isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                phase = .failed(failure)
                if LibraryAccountRevalidation.isCredentialFailure(failure) {
                    onCredentialFailure()
                }
            }
        }
    }

    /// 勾选或取消一个收藏夹；还没读到归属时不动作。
    public func setSelected(_ isSelected: Bool, folderID: Int64) {
        guard case .loaded(let memberships) = phase,
            memberships.contains(where: { $0.id == folderID })
        else { return }
        if isSelected {
            selectedFolderIDs.insert(folderID)
        } else {
            selectedFolderIDs.remove(folderID)
        }
    }

    /// 面板关闭：取消读取。
    public func cancel() {
        loadTask.cancel()
    }

    /// 服务端归属里视频所在的收藏夹：勾选的初始值，也是计算改动的基准。
    private static func containingFolderIDs(_ memberships: [FavoriteFolderMembership]) -> Set<Int64>
    {
        Set(memberships.filter(\.containsVideo).map(\.id))
    }
}
