import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import SwiftUI

/// 稍后再看来源的根视图：给资料库列表的共用根视图（`LibraryVideoListView`）提供稍后再看的文案与卡片映射；登录
/// 门槛、加载、刷新、近尾自动加载与网格的语义都在共用视图。不可用条目由卡片映射标出，网格拒绝激活。
public struct WatchLaterView: View {
    @Environment(\.locale) private var locale
    private let model: WatchLaterViewModel
    private let accountState: AccountPresentationState
    private let gridHost: NativeVideoGridHostContext
    private let onSelect: (String) -> Void
    private let onPresentAuthentication: () -> Void

    public init(
        model: WatchLaterViewModel,
        accountState: AccountPresentationState,
        gridHost: NativeVideoGridHostContext,
        onSelect: @escaping (String) -> Void,
        onPresentAuthentication: @escaping () -> Void
    ) {
        self.model = model
        self.accountState = accountState
        self.gridHost = gridHost
        self.onSelect = onSelect
        self.onPresentAuthentication = onPresentAuthentication
    }

    public var body: some View {
        LibraryVideoListView(
            model: model,
            text: text,
            card: { WatchLaterCardPresentation(item: $0, locale: $1).nativeCard },
            accountState: accountState,
            gridHost: gridHost,
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication
        )
    }

    private var text: LibraryVideoListText {
        LibraryVideoListText(
            signInTitle: LibraryFeatureStrings.localized("登录后查看稍后再看", locale: locale),
            signInDescription: LibraryFeatureStrings.localized(
                "稍后再看只在登录期间加载，不会保存到本机。",
                locale: locale
            ),
            loading: LibraryFeatureStrings.localized("正在加载稍后再看", locale: locale),
            emptyTitle: LibraryFeatureStrings.localized("稍后再看里还没有视频", locale: locale),
            emptySymbol: "play.square.stack",
            emptyDescription: LibraryFeatureStrings.localized(
                "在哔哩哔哩加入稍后再看的视频会显示在这里。",
                locale: locale
            ),
            failureTitle: LibraryFeatureStrings.localized("无法加载稍后再看", locale: locale),
            refreshing: LibraryFeatureStrings.localized("正在刷新稍后再看", locale: locale),
            loadingMore: LibraryFeatureStrings.localized("正在加载更多…", locale: locale),
            gridAccessibilityLabel: LibraryFeatureStrings.localized("稍后再看视频", locale: locale),
            manualContinue: nil
        )
    }
}
