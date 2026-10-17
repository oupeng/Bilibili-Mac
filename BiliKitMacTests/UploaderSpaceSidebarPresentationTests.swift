import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliKit
@testable import BiliVideoDetailFeature

struct UploaderSpaceSidebarPresentationTests {
    @Test(
        arguments: [
            (UploaderSpaceState.closed, UploaderSpaceSidebarPresentation.Overlay.none),
            (.loading(page: 1), .loading),
            (.loaded(page(videos: 1)), .none),
            (.loaded(page(videos: 0)), .empty),
            // 未登录给出登录入口；其他失败带上原因，由视图分开说明风控、凭据与网络。
            (.failed(page: 1, error: .authenticationRequired), .signIn),
            (.failed(page: 2, error: .authenticationInvalid), .failure(.authenticationInvalid)),
            (.failed(page: 2, error: .requestRestricted), .failure(.requestRestricted)),
            (.failed(page: 2, error: .transportFailure), .failure(.transportFailure))
        ]
    )
    func overlayFollowsTheSpaceState(
        state: UploaderSpaceState,
        expected: UploaderSpaceSidebarPresentation.Overlay
    ) {
        let presentation = UploaderSpaceSidebarPresentation(
            state: state,
            pageCount: 3,
            totalCount: 61
        )
        #expect(presentation.overlay == expected)
    }

    @Test(
        arguments: [
            (UploaderSpaceState.loading(page: 2), 3, true),
            (.failed(page: 2, error: .transportFailure), 3, true),
            (.loaded(page(videos: 1)), 1, false),
            (.closed, 3, false)
        ]
    )
    func pagerShowsOnlyForMultiplePagesWhileOpen(
        state: UploaderSpaceState,
        pageCount: Int,
        expected: Bool
    ) {
        let presentation = UploaderSpaceSidebarPresentation(
            state: state,
            pageCount: pageCount,
            totalCount: 61
        )
        #expect(presentation.showsPager == expected)
    }

    @Test
    func headerHidesAnUnknownOrZeroTotal() {
        let loading = UploaderSpaceSidebarPresentation(
            state: .loading(page: 1),
            pageCount: 1,
            totalCount: 0
        )
        let loaded = UploaderSpaceSidebarPresentation(
            state: .loaded(page(videos: 1)),
            pageCount: 3,
            totalCount: 61
        )

        #expect(loading.headerTotalCount == nil)
        #expect(loaded.headerTotalCount == 61)
    }
}

private func page(videos count: Int) -> UploaderVideoPage {
    UploaderVideoPage(
        videos: (0..<count).map { index in
            UploaderVideo(
                bvid: "BV1Fixture\(index)",
                title: "投稿 \(index)",
                coverURL: nil,
                durationSeconds: 60,
                viewCount: 1,
                danmakuCount: 0,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isCollaboration: false
            )
        },
        pageNumber: 1,
        pageSize: 30,
        totalCount: count
    )
}
