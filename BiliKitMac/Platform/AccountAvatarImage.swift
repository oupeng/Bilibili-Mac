import BiliUI
import BiliVideoCollectionUI
import CoreGraphics
import SwiftUI

extension NativeVideoImagePipeline {
    /// 侧栏账号头像实际请求的地址，与卡片头像同一条规则：BiliUI `BiliImageThumbnail` 按头像尺寸追加缩略参数，
    /// 再过请求前的公开 HTTPS 基线（`acceptsRequestURL`）；不合规时为 nil，侧栏只显示占位、不进管线。
    ///
    /// 账号头像来自 nav 的 `face`，BiliAuth 映射时已升级为 HTTPS 并过同一基线；这里在缩略之后按管线自己的
    /// 规则再判一次，见 SECURITY-MODEL §4。
    nonisolated static func accountAvatarRequestURL(for avatarURL: URL?) -> URL? {
        guard let url = BiliImageThumbnail.url(avatarURL, size: .avatar),
            acceptsRequestURL(url)
        else { return nil }
        return url
    }
}

/// 侧栏账号行的头像：经窗口图片管线按 `.avatar` 用途加载（无凭据 session、响应校验、解码上限与有界内存
/// 缓存都在管线里，见 SECURITY-MODEL §4），不用 `AsyncImage`——它走系统共享 session、URLCache 落盘并跟随
/// 重定向。
///
/// 只显示当前地址已到达的图：换地址后 `loaded` 仍留着旧图，但按地址比对不再显示，直到新图到达覆盖它。
/// 不拥有管线（`WindowComposition` 持有、关窗时关闭）。缓存命中在当帧同步显示、不淡入；从网络到达的图按
/// 管线给出的来源经 `NativeImageFadeTransition` 淡入（与卡片、评论头像同一时长），系统开了「减少动态效果」
/// 时直接显示。`.task(id:)` 随地址变化取消旧加载，旧地址的结果按地址比对后丢弃。
struct AccountAvatarImage<Placeholder: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let requestURL: URL
    let imagePipeline: NativeVideoImagePipeline
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        ZStack {
            if let image = displayedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: requestURL) {
            // 命中时也记下：之后内存压力清空缓存，已显示的头像不会在下次重绘时退回占位。
            if let cached = imagePipeline.cachedImage(for: requestURL, variant: .avatar) {
                loaded = (requestURL, cached)
                return
            }
            guard let result = await imagePipeline.image(for: requestURL, variant: .avatar),
                !Task.isCancelled
            else { return }
            let animation = NativeImageFadeTransition.animation(
                fadesIn: result.origin.shouldFadeIn,
                reduceMotion: reduceMotion
            )
            withAnimation(animation) {
                loaded = (requestURL, result.image)
            }
        }
    }

    /// 当前地址已到达的图；没有时同步查管线缓存，让侧栏重建（例如退出播放页）时已缓存的头像当帧显示、
    /// 不闪占位。
    private var displayedImage: CGImage? {
        if let loaded, loaded.url == requestURL { return loaded.image }
        return imagePipeline.cachedImage(for: requestURL, variant: .avatar)
    }
}
