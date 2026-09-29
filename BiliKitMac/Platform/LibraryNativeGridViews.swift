import BiliLibraryFeature
import BiliModels
import SwiftUI

struct WatchLaterNativeGridView: View {
    let content: LoadedWatchLaterContent
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline

    var body: some View {
        NativeVideoGridView(
            items: content.items.map(Self.makePresentation),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: AppStrings.localized("稍后再看视频"),
            scrollReset: $scrollReset,
            imagePipeline: imagePipeline,
            onSelect: content.select
        )
    }

    static func makePresentation(
        _ presentation: WatchLaterCardPresentation
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: presentation.bvid,
            title: presentation.title,
            coverURL: presentation.coverURL,
            avatarURL: presentation.avatarURL,
            showsAvatar: presentation.showsAvatar,
            coverTrailingText: presentation.durationText,
            footerLeadingText: presentation.footerLeadingText,
            footerTrailingText: "",
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}

struct FavoritesNativeGridView: View {
    let content: LoadedFavoritesContent
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline

    var body: some View {
        VStack(spacing: 0) {
            if !content.folders.isEmpty {
                foldersBar
            }
            NativeVideoGridView(
                items: content.items.map(Self.makePresentation),
                scrollOffsetY: $scrollOffsetY,
                accessibilityLabel: AppStrings.localized("收藏视频"),
                tailState: NativeVideoGridTailState(
                    canLoadMore: content.hasMore,
                    isLoading: content.isLoadingMore
                ),
                scrollReset: $scrollReset,
                imagePipeline: imagePipeline,
                onNearEnd: content.loadMore,
                onSelect: content.selectItem
            )
        }
    }

    private var foldersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(content.folders) { folder in
                    let isSelected = folder.id == content.selectedFolderID
                    Button {
                        content.selectFolder(folder.id)
                    } label: {
                        HStack(spacing: 4) {
                            Text(folder.title)
                            Text("(\(folder.mediaCount))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            isSelected
                                ? Color.accentColor.opacity(0.2)
                                : Color.secondary.opacity(0.1),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    static func makePresentation(
        _ presentation: FavoriteCardPresentation
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: presentation.bvid,
            title: presentation.title,
            coverURL: presentation.coverURL,
            avatarURL: presentation.avatarURL,
            showsAvatar: presentation.showsAvatar,
            coverTrailingText: presentation.durationText,
            footerLeadingText: presentation.footerLeadingText,
            footerTrailingText: "",
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}
