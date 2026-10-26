import BiliApplication
import BiliModels
import Foundation
import Observation

@testable import BiliLibraryFeature

/// 本 target 唯一的收藏夹仓库替身：列表与夹内的页按可替换的结果返回并记录请求，可让指定页的请求挂起到测试放行。
actor FavoritesRepositoryStub: FavoritesRepository {
    private(set) var ownerIDs: [Int64] = []
    private(set) var requests: [FavoriteFolderRequest] = []
    private var folderResult: Result<[FavoriteFolder], ContentApplicationError>
    /// 归属读取时视频所在的收藏夹。
    private var containingFolderIDs: Set<Int64> = []
    private var pageResult:
        @Sendable (FavoriteFolderRequest) -> Result<FavoriteFolderPage, ContentApplicationError>
    private var heldFolderIDs: Set<Int64>
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private let folderCalls = TestEventCounter()
    private let pageCalls = TestEventCounter()
    private let heldCancellations = TestEventCounter()

    init(
        folders: Result<[FavoriteFolder], ContentApplicationError> = .success(standardFolders),
        heldFolderIDs: Set<Int64> = [],
        page:
            @escaping @Sendable (FavoriteFolderRequest) -> Result<
                FavoriteFolderPage, ContentApplicationError
            > = { .success(favoritePage($0, total: 90)) }
    ) {
        folderResult = folders
        pageResult = page
        self.heldFolderIDs = heldFolderIDs
    }

    func setFolders(_ result: Result<[FavoriteFolder], ContentApplicationError>) {
        folderResult = result
    }

    func setContainingFolderIDs(_ folderIDs: Set<Int64>) {
        containingFolderIDs = folderIDs
    }

    func setPage(
        _ result:
            @escaping @Sendable (FavoriteFolderRequest) -> Result<
                FavoriteFolderPage, ContentApplicationError
            >
    ) {
        pageResult = result
    }

    /// 放行所有挂起的夹内请求，之后不再挂起。
    func releaseHeldPages() {
        heldFolderIDs = []
        let waiters = heldWaiters
        heldWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func waitForFolderCalls(_ count: Int) async throws {
        try await folderCalls.wait(until: count)
    }

    func waitForPageCalls(_ count: Int) async throws {
        try await pageCalls.wait(until: count)
    }

    /// 等到挂起中的夹内请求被取消 `count` 次（挂起期间忽略取消以模拟迟到结果，只记录取消事件）。
    func waitForHeldCancellations(_ count: Int) async throws {
        try await heldCancellations.wait(until: count)
    }

    func favoriteFolders(ownerID: Int64) async throws -> [FavoriteFolder] {
        ownerIDs.append(ownerID)
        await folderCalls.signal()
        return try folderResult.get()
    }

    func favoriteFolderMemberships(
        ownerID: Int64,
        video: VideoWriteTarget
    ) async throws -> [FavoriteFolderMembership] {
        try await favoriteFolders(ownerID: ownerID).map {
            FavoriteFolderMembership(folder: $0, containsVideo: containingFolderIDs.contains($0.id))
        }
    }

    func favoriteFolderPage(request: FavoriteFolderRequest) async throws -> FavoriteFolderPage {
        requests.append(request)
        await pageCalls.signal()
        if heldFolderIDs.contains(request.folderID) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { heldWaiters.append($0) }
            } onCancel: {
                Task { await self.heldCancellations.signal() }
            }
        }
        return try pageResult(request).get()
    }
}

/// 默认收藏夹不在第一位：回落规则按标记识别默认夹，不靠位置。
let standardFolders = [
    FavoriteFolder(id: 30, title: "公开收藏", mediaCount: 3, isPrivate: false, isDefault: false),
    FavoriteFolder(id: 10, title: "默认收藏夹", mediaCount: 90, isPrivate: false, isDefault: true),
    FavoriteFolder(id: 20, title: "私密收藏", mediaCount: 1, isPrivate: true, isDefault: false)
]

/// 按请求给出一页：每页一条，ID 写明收藏夹、排序之外的页码与关键词，便于断言内容来自哪个请求。
func favoritePage(
    _ request: FavoriteFolderRequest,
    total: Int?,
    hasMore: Bool = false
) -> FavoriteFolderPage {
    FavoriteFolderPage(
        items: [favoriteItem("BV1F\(request.folderID)P\(request.page)\(request.keyword)")],
        pageNumber: request.page,
        pageSize: 40,
        totalCount: total,
        hasMore: hasMore
    )
}

func favoriteItem(
    _ id: String,
    unavailability: LibraryItemUnavailability? = nil,
    videoAID: Int64? = nil
) -> FavoriteItem {
    FavoriteItem(
        id: id,
        title: "手写收藏条目",
        coverURL: nil,
        owner: VideoOwner(id: 1, name: "测试作者"),
        durationSeconds: 100,
        favoritedAt: Date(timeIntervalSince1970: 1_700_000_000),
        unavailability: unavailability,
        videoAID: videoAID
    )
}

/// 等待 `@Observable` 状态满足条件：每次被追踪属性变化后才重新判断，超时由测试的 time limit 兜底。
@MainActor
func waitForObservedState(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

/// 收藏夹列表的读取已结束（不在加载中，也不在后台重读）。
@MainActor
func waitUntilSettled(_ model: FavoriteFolderListModel) async {
    await waitForObservedState { model.state != .loading && !model.isRefreshing }
}
