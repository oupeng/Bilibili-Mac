import BiliModels

/// 自己的一个收藏夹，以及某个视频此刻是否在里面；「收藏到…」面板打开时读取，勾选的初始状态取它。
public struct FavoriteFolderMembership: Sendable, Equatable, Identifiable {
    public let folder: FavoriteFolder
    public let containsVideo: Bool

    public var id: Int64 { folder.id }

    public init(folder: FavoriteFolder, containsVideo: Bool) {
        self.folder = folder
        self.containsVideo = containsVideo
    }
}

/// 一个视频在自己若干收藏夹里的归属改动：「收藏到…」面板确认时按勾选与初始状态的差异算出，一次请求提交。
///
/// 两侧都是正数、互不相交，至少一侧非空；夹 id 升序，同一改动的两次构造相等，写入协调者据此对在途写入去重。
public struct FavoriteMembershipChange: Sendable, Hashable {
    public let target: VideoWriteTarget
    public let addedFolderIDs: [Int64]
    public let removedFolderIDs: [Int64]

    /// 两侧都为空、相交或含非正数时为 nil：没有改动就不发请求。
    public init?(target: VideoWriteTarget, adding: Set<Int64>, removing: Set<Int64>) {
        guard !(adding.isEmpty && removing.isEmpty),
            adding.isDisjoint(with: removing),
            adding.union(removing).allSatisfy({ $0 > 0 })
        else { return nil }
        self.target = target
        addedFolderIDs = adding.sorted()
        removedFolderIDs = removing.sorted()
    }
}

/// 收藏夹里的一个视频条目，夹内「从此收藏夹移除」的对象。
///
/// 用稿件 av 号而不是 BVID：失效视频的条目可能没有合规 BVID，但仍有 av 号，用户需要能把它移出收藏夹。
public struct FavoriteFolderEntry: Sendable, Hashable {
    public let folderID: Int64
    public let videoAID: Int64

    /// 任一 ID 不是正数时为 nil。
    public init?(folderID: Int64, videoAID: Int64) {
        guard folderID > 0, videoAID > 0 else { return nil }
        self.folderID = folderID
        self.videoAID = videoAID
    }
}

/// 收藏的写入 port：改变一个视频在若干收藏夹里的归属，或从一个收藏夹移除一个视频条目。
///
/// 实现是 BiliAPI 的 `BiliFavoritesWriteRepository`，只经 `FavoritesWriteUseCase` 调用。`accountID` 是窗口账户的 mid，
/// 实现必须把它交给写授权器做账户绑定。失败统一抛出 `AccountWriteError`，取消原样传播；不重试、不排队。
public protocol FavoritesWriteRepository: Sendable {
    func update(_ change: FavoriteMembershipChange, accountID: Int64) async throws
    func remove(_ entry: FavoriteFolderEntry, accountID: Int64) async throws
}

/// 收藏到收藏夹与从收藏夹移除；校验账户后执行写入，成功时给出要分发的效果。
public struct FavoritesWriteUseCase: Sendable {
    private let repository: any FavoritesWriteRepository

    public init(repository: any FavoritesWriteRepository) {
        self.repository = repository
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func update(
        _ change: FavoriteMembershipChange,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.update(change, accountID: accountID)
        return AccountWriteEffect(accountID: accountID, change: .favoriteMembershipChanged(change))
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func remove(
        _ entry: FavoriteFolderEntry,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.remove(entry, accountID: accountID)
        return AccountWriteEffect(accountID: accountID, change: .removedFromFavoriteFolder(entry))
    }
}
