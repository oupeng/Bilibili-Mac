import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct WatchLaterView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let model: WatchLaterViewModel
    private let makeLoadedContent: (LoadedWatchLaterContent) -> LoadedContent
    private let onSelect: (String) -> Void
    private let onAuthenticationRequired: () -> Void

    public init(
        model: WatchLaterViewModel,
        @ViewBuilder makeLoadedContent: @escaping (LoadedWatchLaterContent) -> LoadedContent,
        onSelect: @escaping (String) -> Void,
        onAuthenticationRequired: @escaping () -> Void
    ) {
        self.model = model
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
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
            model.loadIfNeeded()
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
        case .idle, .loading:
            VideoCardGridSkeleton(
                loadingLabel: LibraryFeatureStrings.localized("正在加载稍后再看", locale: locale)
            )
        case .loaded(let items, let count):
            if items.isEmpty {
                ContentUnavailableView {
                    Label(
                        LibraryFeatureStrings.localized("稍后再看列表为空", locale: locale),
                        systemImage: "clock"
                    )
                } description: {
                    Text(LibraryFeatureStrings.localized("在浏览或观看视频时添加到稍后再看的视频会显示在这里。", locale: locale))
                }
            } else {
                makeLoadedContent(
                    LoadedWatchLaterContent(
                        items: items.map { WatchLaterCardPresentation(item: $0, locale: locale) },
                        count: count,
                        select: onSelect,
                        remove: model.remove
                    )
                )
            }
        case .failed(let error):
            failure(error)
        }
    }

    private var visualPhase: LoadingVisualPhase {
        switch model.state {
        case .idle, .loading:
            .loading
        case .loaded(let items, _) where items.isEmpty:
            .empty
        case .loaded:
            .content
        case .failed:
            .failure
        }
    }

    private func failure(_ error: WatchLaterError) -> some View {
        ContentUnavailableView {
            Label(title(for: error), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message(for: error))
        } actions: {
            if error != .authenticationRequired {
                Button(LibraryFeatureStrings.localized("重试", locale: locale)) {
                    model.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func title(for error: WatchLaterError) -> String {
        switch error {
        case .authenticationRequired:
            LibraryFeatureStrings.localized("登录状态已失效", locale: locale)
        case .requestRestricted:
            LibraryFeatureStrings.localized("请求受到限制", locale: locale)
        default:
            LibraryFeatureStrings.localized("无法加载稍后再看", locale: locale)
        }
    }

    private func message(for error: WatchLaterError) -> String {
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
