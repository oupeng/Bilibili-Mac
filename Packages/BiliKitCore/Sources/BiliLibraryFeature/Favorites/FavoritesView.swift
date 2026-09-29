import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct FavoritesView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let model: FavoritesViewModel
    private let upMID: Int64
    private let makeLoadedContent: (LoadedFavoritesContent) -> LoadedContent
    private let onSelectVideo: (String) -> Void
    private let onAuthenticationRequired: () -> Void

    public init(
        model: FavoritesViewModel,
        upMID: Int64,
        @ViewBuilder makeLoadedContent: @escaping (LoadedFavoritesContent) -> LoadedContent,
        onSelectVideo: @escaping (String) -> Void,
        onAuthenticationRequired: @escaping () -> Void
    ) {
        self.model = model
        self.upMID = upMID
        self.makeLoadedContent = makeLoadedContent
        self.onSelectVideo = onSelectVideo
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    public var body: some View {
        ZStack {
            content
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
        .task {
            model.loadIfNeeded(upMID: upMID)
            await model.waitForCurrentTask()
        }
        .onChange(of: model.requiresAuthentication) { _, required in
            if required {
                onAuthenticationRequired()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loadingFolders:
            VideoCardGridSkeleton(
                loadingLabel: LibraryFeatureStrings.localized("正在加载收藏夹", locale: locale)
            )
        case .loadedFolders(let folders, let selectedFolderID, let items, _, let hasMore, let isLoadingItems, let itemsError):
            if folders.isEmpty {
                ContentUnavailableView {
                    Label(
                        LibraryFeatureStrings.localized("暂无收藏夹", locale: locale),
                        systemImage: "star"
                    )
                } description: {
                    Text(LibraryFeatureStrings.localized("登录账号后在哔哩哔哩创建的收藏夹会显示在这里。", locale: locale))
                }
            } else {
                VStack(spacing: 0) {
                    folderPicker(folders: folders, selectedFolderID: selectedFolderID)

                    if items.isEmpty && !isLoadingItems {
                        if let itemsError {
                            itemsFailure(itemsError, folderID: selectedFolderID)
                        } else {
                            ContentUnavailableView {
                                Label(
                                    LibraryFeatureStrings.localized("收藏夹为空", locale: locale),
                                    systemImage: "star"
                                )
                            } description: {
                                Text(LibraryFeatureStrings.localized("此收藏夹中暂无视频。", locale: locale))
                            }
                        }
                    } else {
                        makeLoadedContent(
                            LoadedFavoritesContent(
                                folders: folders,
                                selectedFolderID: selectedFolderID,
                                items: items.map { FavoritesCardPresentation(item: $0, locale: locale) },
                                hasMore: hasMore,
                                isLoadingMore: isLoadingItems,
                                selectFolder: model.selectFolder,
                                loadMore: model.loadMore,
                                selectVideo: onSelectVideo
                            )
                        )
                    }
                }
            }
        case .failed(let error):
            failure(error)
        }
    }

    private func folderPicker(folders: [FavFolder], selectedFolderID: Int64) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(folders) { folder in
                    let isSelected = folder.mediaID == selectedFolderID
                    Button {
                        model.selectFolder(mediaID: folder.mediaID)
                    } label: {
                        HStack(spacing: 4) {
                            Text(folder.title)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            if folder.mediaCount > 0 {
                                Text("(\(folder.mediaCount))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05), in: Capsule())
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var visualPhase: LoadingVisualPhase {
        switch model.state {
        case .idle, .loadingFolders:
            .loading
        case .loadedFolders(let folders, _, _, _, _, _, _) where folders.isEmpty:
            .empty
        case .loadedFolders:
            .content
        case .failed:
            .failure
        }
    }

    private func itemsFailure(_ error: FavoritesError, folderID: Int64) -> some View {
        ContentUnavailableView {
            Label(title(for: error), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message(for: error))
        } actions: {
            Button(LibraryFeatureStrings.localized("重试", locale: locale)) {
                model.selectFolder(mediaID: folderID)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func failure(_ error: FavoritesError) -> some View {
        ContentUnavailableView {
            Label(title(for: error), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message(for: error))
        } actions: {
            if error != .authenticationRequired {
                Button(LibraryFeatureStrings.localized("重试", locale: locale)) {
                    model.reload(upMID: upMID)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func title(for error: FavoritesError) -> String {
        switch error {
        case .authenticationRequired:
            LibraryFeatureStrings.localized("登录状态已失效", locale: locale)
        case .requestRestricted:
            LibraryFeatureStrings.localized("请求受到限制", locale: locale)
        default:
            LibraryFeatureStrings.localized("无法加载收藏", locale: locale)
        }
    }

    private func message(for error: FavoritesError) -> String {
        switch error {
        case .authenticationRequired:
            LibraryFeatureStrings.localized("请重新扫码登录后再试。", locale: locale)
        case .requestRestricted:
            LibraryFeatureStrings.localized("服务暂时拒绝了请求，请降低频率后重试。", locale: locale)
        case .serviceRejected(let code):
            LibraryFeatureStrings.localized("服务暂时无法完成请求（代码 \(code)）。", locale: locale)
        case .transportFailure:
            LibraryFeatureStrings.localized("请检查网络连接后重试。", locale: locale)
        case .invalidResponse:
            LibraryFeatureStrings.localized("接口数据与当前客户端预期不一致。", locale: locale)
        }
    }
}
