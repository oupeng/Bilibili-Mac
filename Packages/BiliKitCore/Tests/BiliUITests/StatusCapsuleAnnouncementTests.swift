import BiliUI
import Testing

/// 刷新与分页胶囊只把失败原因通告给读屏；转圈、手动继续与空闲不通告，刷新中不重报旧的失败原因。
struct StatusCapsuleAnnouncementTests {
    @Test
    @MainActor
    func refreshAnnouncesOnlyASettledFailure() {
        let failed = RefreshStatusCapsule(
            isRefreshing: false,
            refreshingLabel: "refreshing",
            errorMessage: "failed"
        )
        let retrying = RefreshStatusCapsule(
            isRefreshing: true,
            refreshingLabel: "refreshing",
            errorMessage: "failed"
        )
        let idle = RefreshStatusCapsule(
            isRefreshing: false,
            refreshingLabel: "refreshing",
            errorMessage: nil
        )

        #expect(failed.announcement == "failed")
        #expect(retrying.announcement == nil)
        #expect(idle.announcement == nil)
    }

    @Test
    @MainActor
    func paginationAnnouncesOnlyFailures() {
        #expect(
            PaginationStatusOverlay.Status.failed(message: "failed", retry: nil).announcement
                == "failed"
        )
        #expect(
            PaginationStatusOverlay.Status.failed(message: "failed", retry: {}).announcement
                == "failed"
        )
        #expect(PaginationStatusOverlay.Status.loadingMore(label: "loading").announcement == nil)
        #expect(
            PaginationStatusOverlay.Status.manualLoadMore(title: "more", action: {}).announcement
                == nil
        )
        #expect(PaginationStatusOverlay.Status.idle.announcement == nil)
    }
}
