import BiliUI
import SwiftUI

public struct LoadedWatchLaterContent: Sendable {
    public let items: [WatchLaterCardPresentation]
    public let select: @Sendable (String) -> Void

    public init(
        items: [WatchLaterCardPresentation],
        select: @escaping @Sendable (String) -> Void
    ) {
        self.items = items
        self.select = select
    }
}

public struct WatchLaterView<LoadedContent: View>: View {
    private let model: WatchLaterViewModel
    private let makeLoadedContent: (LoadedWatchLaterContent) -> LoadedContent
    private let onSelect: @Sendable (String) -> Void
    private let onAuthenticationRequired: () -> Void

    public init(
        model: WatchLaterViewModel,
        @ViewBuilder makeLoadedContent: @escaping (LoadedWatchLaterContent) -> LoadedContent,
        onSelect: @escaping @Sendable (String) -> Void,
        onAuthenticationRequired: @escaping () -> Void
    ) {
        self.model = model
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    public var body: some View {
        WatchLaterContentView(
            model: model,
            makeLoadedContent: makeLoadedContent,
            onSelect: onSelect
        )
        .task {
            model.loadIfNeeded()
            await model.waitForCurrentTask()
        }
        .onChange(of: model.requiresAuthentication) { _, required in
            if required {
                onAuthenticationRequired()
            }
        }
    }
}

struct WatchLaterContentView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let model: WatchLaterViewModel
    let makeLoadedContent: (LoadedWatchLaterContent) -> LoadedContent
    let onSelect: @Sendable (String) -> Void

    var body: some View {
        ZStack {
            content
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VideoCardGridSkeleton(
                loadingLabel: LibraryFeatureStrings.localized("正在加载稍后再看", locale: locale)
            )
        case .loaded(let items) where items.isEmpty:
            ContentUnavailableView {
                Label(
                    LibraryFeatureStrings.localized("稍后再看列表为空", locale: locale),
                    systemImage: "clock"
                )
            } description: {
                Text(LibraryFeatureStrings.localized("添加到稍后再看的视频会显示在这里。", locale: locale))
            }
        case .loaded(let items):
            makeLoadedContent(
                LoadedWatchLaterContent(
                    items: items.map { WatchLaterCardPresentation(item: $0, locale: locale) },
                    select: onSelect
                )
            )
        case .failed:
            ContentUnavailableView {
                Label(
                    LibraryFeatureStrings.localized("无法加载稍后再看", locale: locale),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(LibraryFeatureStrings.localized("请检查网络连接或登录状态。", locale: locale))
            } actions: {
                Button(LibraryFeatureStrings.localized("重试", locale: locale)) {
                    model.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var visualPhase: LoadingVisualPhase {
        switch model.state {
        case .idle, .loading:
            .loading
        case .loaded(let items) where items.isEmpty:
            .empty
        case .loaded:
            .content
        case .failed:
            .failure
        }
    }
}
