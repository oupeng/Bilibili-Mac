import BiliApplication
import BiliAuthFeature
import SwiftUI

/// 使用系统 Sidebar List 表达窗口内当前可用的平级来源；行按 `AppSources` 的顺序与描述渲染。
///
/// 底部账号行的头像经窗口图片管线加载（`AccountAvatarImage`），不拥有管线。
struct AppNavigationSidebar: View {
    let sources: [AppSourceDescriptor]
    @Binding var selection: AppTab
    let accountState: AccountPresentationState
    let imagePipeline: NativeVideoImagePipeline
    let onPresentAuthentication: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navigationList
            accountBar
        }
    }

    private var navigationList: some View {
        List(selection: selectionBinding) {
            ForEach(sources) { source in
                Label {
                    Text(source.title)
                } icon: {
                    Image(systemName: source.systemImage)
                }
                .tag(source.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var accountBar: some View {
        accountButton
    }

    private var selectionBinding: Binding<AppTab?> {
        Binding(
            get: { selection },
            set: { newValue in
                guard let newValue else { return }
                selection = newValue
            }
        )
    }

    private var accountButton: some View {
        Button(action: onPresentAuthentication) {
            HStack(spacing: 12) {
                accountAvatar

                Text(accountTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityHint(accountAccessibilityHint)
    }

    private var accountTitle: String {
        switch accountState {
        case .resolving, .unavailable:
            AppStrings.localized("账号")
        case .signedOut:
            AppStrings.localized("登录")
        case .signedIn:
            accountState.displayName ?? AppStrings.localized("账号")
        }
    }

    private var accountAccessibilityHint: String {
        switch accountState {
        case .resolving:
            AppStrings.localized("正在检查本机登录状态")
        case .unavailable:
            AppStrings.localized("打开账号以重试恢复")
        case .signedOut:
            AppStrings.localized("打开扫码登录")
        case .signedIn:
            AppStrings.localized("打开账号管理")
        }
    }

    private var accountAvatar: some View {
        Group {
            if let requestURL = NativeVideoImagePipeline.accountAvatarRequestURL(
                for: accountState.avatarURL
            ) {
                AccountAvatarImage(requestURL: requestURL, imagePipeline: imagePipeline) {
                    fallbackAvatar
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var fallbackAvatar: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
    }
}
