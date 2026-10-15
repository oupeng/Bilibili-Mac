import AppKit
import BiliModels
import SwiftUI

@MainActor
struct NativeCommentImagePreviewRequest: Identifiable {
    let id = UUID()
    let bvid: String
    let references: [CommentAssetReference]
    let selectedIndex: Int
    let restoreFocus: () -> Void
}

/// 预览所在宿主视图的弱引用：保存面板以 sheet 挂在预览自己的窗口上，不取当时的 key window。
@MainActor
final class NativeCommentImagePreviewAnchor {
    weak var view: NSView?
}

struct NativeCommentImagePreviewView: View {
    let request: NativeCommentImagePreviewRequest
    let imagePipeline: NativeVideoImagePipeline
    let resolveURL: CommentAssetURLResolver
    /// 窗口级的保存 owner：预览关闭后已确认的保存照常完成。
    let imageSaver: NativeCommentImageSaver
    let onDismiss: () -> Void

    @State private var anchor = NativeCommentImagePreviewAnchor()

    var body: some View {
        NativeCommentImagePreviewHost(
            anchor: anchor,
            content: NativeCommentImagePreviewContent(
                request: request,
                loader: NativePlaybackCommentPictureLoader(
                    imagePipeline: imagePipeline,
                    resolveURL: resolveURL,
                    variant: .commentPicturePreview
                ),
                placeholderLoader: NativePlaybackCommentPictureLoader(
                    imagePipeline: imagePipeline,
                    resolveURL: resolveURL,
                    variant: .commentPicture
                ),
                saver: imageSaver,
                anchor: anchor,
                onDismiss: onDismiss
            )
        )
        .id(request.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

struct NativeCommentImagePreviewSelection: Equatable {
    let count: Int
    private(set) var index: Int

    init(count: Int, requestedIndex: Int) {
        self.count = max(0, count)
        index =
            self.count > 0
            ? min(max(0, requestedIndex), self.count - 1)
            : 0
    }

    var canSelectPrevious: Bool { index > 0 }
    var canSelectNext: Bool { index + 1 < count }

    mutating func selectPrevious() -> Bool {
        guard canSelectPrevious else { return false }
        index -= 1
        return true
    }

    mutating func selectNext() -> Bool {
        guard canSelectNext else { return false }
        index += 1
        return true
    }
}

/// 预览打开时独占键盘：播放器的按键监视看到第一响应者在它之内，就把方向键与 Esc 留给预览。
@MainActor
final class NativeCommentImagePreviewHostingView<Content: View>: NSHostingView<Content>,
    PlayerKeyboardFocusOwner
{
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 与原 AppKit 实现一样延后一轮：等 SwiftUI 建好焦点树后再接管第一响应者。
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

private struct NativeCommentImagePreviewHost<Content: View>: NSViewRepresentable {
    let anchor: NativeCommentImagePreviewAnchor
    let content: Content

    func makeNSView(context: Context) -> NativeCommentImagePreviewHostingView<Content> {
        let view = NativeCommentImagePreviewHostingView(rootView: content)
        anchor.view = view
        view.sizingOptions = []
        // 预览铺满整个窗口（含隐藏工具栏后的标题栏区域），不按窗口安全区缩进背景与布局。
        view.safeAreaRegions = []
        // Tab 走完预览内的控件后回到预览自身，不落到被遮住的侧栏或推荐列表上。
        view.nextKeyView = view
        return view
    }

    func updateNSView(
        _ view: NativeCommentImagePreviewHostingView<Content>,
        context: Context
    ) {
        view.rootView = content
    }
}

private struct NativeCommentImagePreviewContent: View {
    private enum Focus: Hashable {
        case surface
        case close
    }

    private enum Phase {
        case loading
        /// 原图到达前显示列表里已缓存的缩小图；`originalFailed` 表示原图加载失败，可重试。
        case placeholder(CGImage, originalFailed: Bool)
        /// 原图；动图另带编码数据，由缩放视图播放。缩小图占位不播放。
        case loaded(CGImage, NativeAnimatedImage?)
        case failed

        var image: CGImage? {
            switch self {
            case .placeholder(let image, _), .loaded(let image, _): image
            case .loading, .failed: nil
            }
        }

        var animation: NativeAnimatedImage? {
            guard case .loaded(_, let animation) = self else { return nil }
            return animation
        }

        /// 占位时原图是否失败；不是占位时为 nil。
        var originalFailed: Bool? {
            guard case .placeholder(_, let failed) = self else { return nil }
            return failed
        }
    }

    private struct LoadKey: Equatable {
        let index: Int
        let attempt: Int
    }

    private static let buttonInset: CGFloat = 18
    private static let buttonSpacing: CGFloat = 10
    private static let counterBottomInset: CGFloat = 18
    private static let originalStatusInset: CGFloat = 12

    let request: NativeCommentImagePreviewRequest
    let loader: NativePlaybackCommentPictureLoader
    /// 列表格子用的缩小图；只读缓存，用作原图到达前的占位，不为预览另发请求。
    let placeholderLoader: NativePlaybackCommentPictureLoader
    let saver: NativeCommentImageSaver
    let anchor: NativeCommentImagePreviewAnchor
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @State private var selection: NativeCommentImagePreviewSelection
    @State private var phase = Phase.loading
    @State private var loadAttempt = 0
    /// 本次预览持有的原图；视图随 `request.id` 重建时一起释放。
    @State private var originals = NativeCommentImagePreviewOriginals()

    init(
        request: NativeCommentImagePreviewRequest,
        loader: NativePlaybackCommentPictureLoader,
        placeholderLoader: NativePlaybackCommentPictureLoader,
        saver: NativeCommentImageSaver,
        anchor: NativeCommentImagePreviewAnchor,
        onDismiss: @escaping () -> Void
    ) {
        self.request = request
        self.loader = loader
        self.placeholderLoader = placeholderLoader
        self.saver = saver
        self.anchor = anchor
        self.onDismiss = onDismiss
        _selection = State(
            initialValue: NativeCommentImagePreviewSelection(
                count: request.references.count,
                requestedIndex: request.selectedIndex
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 关闭手势只挂在背景上：图片盖在背景之上，点图片交给缩放视图（单击缩放，图片四周空白
                // 关闭）。挂在外层容器上会让点图片同时缩放和关闭。导航按钮不在该手势内。
                Color.black.opacity(0.82)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                phaseContent
                    .padding(.horizontal, min(96, max(56, geometry.size.width * 0.08)))
                    .padding(.vertical, min(86, max(54, geometry.size.height * 0.08)))
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: Self.buttonSpacing) {
                    iconButton(
                        "square.and.arrow.down",
                        label: AppStrings.localized("保存图片"),
                        action: saveCurrentImage
                    )
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(phase.image == nil || saver.isBusy)
                    iconButton(
                        "xmark",
                        label: AppStrings.localized("关闭图片预览"),
                        action: onDismiss
                    )
                    .focused($focus, equals: .close)
                }
                .padding(Self.buttonInset)
            }
            .overlay { navigation }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .surface)
        .defaultFocus($focus, .close)
        .task {
            // 未开启全键盘访问时关闭按钮不可聚焦，默认焦点落空；退到预览表面，保证 ←／→／Esc 可用。
            await Task.yield()
            if focus == nil { focus = .surface }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option, .shift])
            else { return .ignored }
            if press.key == .leftArrow { selectPrevious() } else { selectNext() }
            return .handled
        }
        .onExitCommand(perform: onDismiss)
        .task(id: LoadKey(index: selection.index, attempt: loadAttempt)) {
            await loadCurrentImage()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppStrings.localized("评论图片预览"))
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var phaseContent: some View {
        if let image = phase.image {
            imageView(image, animation: phase.animation, originalFailed: phase.originalFailed)
        } else if case .failed = phase {
            VStack(spacing: 10) {
                Text(AppStrings.localized("图片加载失败"))
                    .foregroundStyle(.white)
                Button(AppStrings.localized("重试")) { retry() }
                    .accessibilityLabel(AppStrings.localized("重新加载评论图片"))
            }
        } else {
            ProgressView()
                .accessibilityLabel(AppStrings.localized("评论图片加载中"))
        }
    }

    /// 缩小图与原图共用同一个缩放视图。
    ///
    /// 按序号重建（换图回到适配），同一张换成原图时只替换图片、保留缩放位置；原图状态贴在图片适配区域
    /// 的底边。
    private func imageView(
        _ image: CGImage,
        animation: NativeAnimatedImage?,
        originalFailed: Bool?
    ) -> some View {
        GeometryReader { proxy in
            let fitted = NativeCommentImageZoomGeometry.fittedSize(
                imageSize: CGSize(width: image.width, height: image.height),
                in: proxy.size
            )
            NativeCommentImageZoomView(
                image: image,
                animation: animation,
                accessibilityLabel: imageAccessibilityLabel,
                onDismissArea: onDismiss
            )
            .overlay {
                if let originalFailed {
                    originalStatus(failed: originalFailed)
                        .padding(Self.originalStatusInset)
                        .frame(width: fitted.width, height: fitted.height, alignment: .bottom)
                }
            }
        }
        .id(selection.index)
        .transition(.opacity)
    }

    /// 缩小图占位上的原图状态：加载中显示转圈，失败时提供重试，不让用户误以为原图就是这样。
    ///
    /// 保持自身宽度：窄长图的图片宽度不足时允许超出图片两侧，文字与按钮不被压成省略号。
    @ViewBuilder
    private func originalStatus(failed: Bool) -> some View {
        Group {
            if failed {
                HStack(spacing: 8) {
                    Text(AppStrings.localized("原图加载失败"))
                    Button(AppStrings.localized("重试")) { retry() }
                        .accessibilityLabel(AppStrings.localized("重新加载原图"))
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(AppStrings.localized("正在加载原图"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    @ViewBuilder
    private var navigation: some View {
        if selection.count > 1 {
            HStack {
                iconButton(
                    "chevron.left",
                    label: AppStrings.localized("上一张图片"),
                    action: selectPrevious
                )
                .disabled(!selection.canSelectPrevious)
                Spacer()
                iconButton(
                    "chevron.right",
                    label: AppStrings.localized("下一张图片"),
                    action: selectNext
                )
                .disabled(!selection.canSelectNext)
            }
            .padding(.horizontal, Self.buttonInset)
        }
        if selection.count > 0 {
            Text(verbatim: "\(selection.index + 1) / \(selection.count)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, Self.counterBottomInset)
        }
    }

    private var imageAccessibilityLabel: String {
        selection.count > 0
            ? AppStrings.localized("评论图片，第 \(selection.index + 1) 张，共 \(selection.count) 张")
            : AppStrings.localized("评论图片")
    }

    private func iconButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 24, height: 24)
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel(label)
        return Group {
            if #available(macOS 26.0, *) {
                button.buttonStyle(.glass)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    /// 保存当前这张的原图，保存面板挂在预览自己的窗口上。
    private func saveCurrentImage() {
        guard request.references.indices.contains(selection.index) else { return }
        saver.save(
            request.references[selection.index],
            loader: loader,
            in: anchor.view?.window
        )
    }

    private func selectPrevious() {
        guard selection.selectPrevious() else { return }
        phase = .loading
    }

    private func selectNext() {
        guard selection.selectNext() else { return }
        phase = .loading
    }

    private func retry() {
        phase = .loading
        loadAttempt += 1
    }

    /// 由 `.task(id:)` 驱动：切换图片、重试或关闭都会取消上一次加载。
    ///
    /// 列表里已缓存的缩小图先显示并标出原图加载中，原图到达后原位替换（显示尺寸相同）；原图失败时
    /// 保留缩小图并提供重试，只有连占位都没有时才整页显示失败。共享缓存放不下的大原图由本次预览的
    /// `originals` 持有当前与前后各一张。
    private func loadCurrentImage() async {
        guard request.references.indices.contains(selection.index) else {
            phase = .failed
            return
        }
        let reference = request.references[selection.index]
        if let cached = loader.cachedImage(for: reference) {
            phase = .loaded(cached, loader.cachedAnimation(for: reference))
            return
        }
        let placeholder = placeholderLoader.cachedImage(for: reference)
        phase = placeholder.map { .placeholder($0, originalFailed: false) } ?? .loading
        let result = await originals.image(at: selection.index) { [loader] in
            await loader.image(for: reference)
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            phase = placeholder.map { .placeholder($0, originalFailed: true) } ?? .failed
            return
        }
        let animation: Animation? =
            placeholder == nil && result.origin.shouldFadeIn && !reduceMotion
            ? .easeOut(duration: NativePlaybackCommentImageTransition.duration)
            : nil
        withAnimation(animation) {
            phase = .loaded(result.image, result.animation)
        }
    }
}
