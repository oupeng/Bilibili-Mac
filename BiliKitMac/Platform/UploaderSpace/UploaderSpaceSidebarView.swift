import AppKit
import BiliBrowseFeature
import BiliModels
import SwiftUI

/// 压在侧栏上的 UP 主空间层。
///
/// 原生列表只画头部与已加载的行；加载骨架、空、失败与登录提示由本视图按 ViewModel 状态叠在头部下方，
/// 返回按钮始终可点。页码条悬浮在底部，列表为它留出底部空间。
struct UploaderSpaceSidebarView: View {
    let model: UploaderSpaceViewModel
    let currentBVID: String?
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void
    let onLogin: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        ZStack(alignment: .top) {
            if let content = listContent {
                UploaderSpaceListRepresentable(
                    content: content,
                    imagePipeline: imagePipeline,
                    actions: UploaderSpaceListActions(
                        close: model.close,
                        selectOrder: model.setOrder,
                        selectVideo: onSelect
                    )
                )
                .ignoresSafeArea(.container, edges: .top)
            }
            stateOverlay
                .padding(.top, UploaderSpaceGeometry.stateContentTop)
        }
        .overlay(alignment: .bottom) {
            if showsPager {
                UploaderSpacePager(
                    currentPage: model.currentPage,
                    pageCount: model.pageCount,
                    onShowPage: model.showPage
                )
            }
        }
    }

    private var showsPager: Bool {
        model.pageCount > 1 && model.state != .closed
    }

    private var listContent: UploaderSpaceListContent? {
        guard let owner = model.owner else { return nil }
        let rows: [UploaderVideoRowPresentation]
        if case .loaded(let page) = model.state {
            rows = page.videos.map { UploaderVideoRowPresentation(video: $0, locale: locale) }
        } else {
            rows = []
        }
        return UploaderSpaceListContent(
            header: UploaderSpaceHeaderContent(
                name: owner.name,
                avatarURL: owner.avatarURL,
                totalCount: model.totalCount > 0 ? model.totalCount : nil,
                order: model.order
            ),
            rows: rows,
            currentBVID: currentBVID,
            pageIdentity: UploaderSpaceListContent.PageIdentity(
                ownerID: owner.id,
                order: model.order,
                page: model.currentPage
            ),
            reservesPagerSpace: showsPager
        )
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch model.state {
        case .closed:
            EmptyView()
        case .loading:
            UploaderSpaceSkeleton()
        case .loaded(let page):
            if page.videos.isEmpty {
                message(AppStrings.localized("还没有投稿"))
            }
        case .failed(_, .authenticationRequired):
            message(
                AppStrings.localized("登录后可浏览 UP 主投稿"),
                actionTitle: AppStrings.localized("登录"),
                action: onLogin
            )
        case .failed:
            message(
                AppStrings.localized("投稿加载失败"),
                actionTitle: AppStrings.localized("重试"),
                action: model.reload
            )
        }
    }

    private func message(
        _ text: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

/// 加载中的占位行，几何与真实行一致，切换时不跳动。
private struct UploaderSpaceSkeleton: View {
    private static let rowCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: UploaderSpaceGeometry.rowSpacing) {
            ForEach(0..<Self.rowCount, id: \.self) { _ in
                HStack(alignment: .top, spacing: UploaderSpaceGeometry.coverTextSpacing) {
                    RoundedRectangle(cornerRadius: UploaderSpaceGeometry.coverCornerRadius)
                        .frame(
                            width: UploaderSpaceGeometry.coverWidth,
                            height: UploaderSpaceGeometry.coverHeight
                        )
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).frame(height: 12)
                        RoundedRectangle(cornerRadius: 3).frame(width: 120, height: 12)
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3).frame(width: 160, height: 10)
                    }
                    .frame(height: UploaderSpaceGeometry.coverHeight)
                }
                .padding(UploaderSpaceGeometry.rowPadding)
            }
        }
        .foregroundStyle(.quaternary)
        .padding(.horizontal, UploaderSpaceGeometry.listHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel(AppStrings.localized("正在加载投稿"))
    }
}

private struct UploaderSpaceListRepresentable: NSViewRepresentable {
    let content: UploaderSpaceListContent
    let imagePipeline: NativeVideoImagePipeline
    let actions: UploaderSpaceListActions

    func makeCoordinator() -> UploaderSpaceListController {
        UploaderSpaceListController(imagePipeline: imagePipeline)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(content: content, actions: actions)
        return context.coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(content: content, actions: actions)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: UploaderSpaceListController) {
        coordinator.tearDown()
    }
}
