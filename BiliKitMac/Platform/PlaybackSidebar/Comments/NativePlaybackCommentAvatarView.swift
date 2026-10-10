import AppKit
import BiliModels

/// 评论头像右下角的身份角标：认证为黄／蓝底白色闪电，大会员为粉底白色“大”字。
///
/// 认证优先于大会员，只显示一个；普通用户没有角标。
enum NativeCommentAvatarMark: Equatable {
    case personalVerification
    case organizationVerification
    case vip

    init?(author: CommentAuthor) {
        switch author.verification {
        case .personal: self = .personalVerification
        case .organization: self = .organizationVerification
        case nil:
            guard author.isVIP else { return nil }
            self = .vip
        }
    }

    var background: NSColor {
        switch self {
        case .personalVerification: .systemYellow
        case .organizationVerification: .systemBlue
        case .vip: .systemPink
        }
    }
}

@MainActor
final class NativePlaybackCommentAvatarView: NSView {
    override var isFlipped: Bool { true }
    private let avatarImage = NSImageView()
    /// 没有头像、加载中或加载失败时显示的剪影，与其他头像占位一致。
    private let placeholderImage = NSImageView()
    private let mark = NativePlaybackCommentAvatarMarkView()
    /// 头像与占位各自的形状遮罩：圆形，有角标时在角标周围抠出一圈透明缝隙。
    private let avatarMask = CAShapeLayer()
    private let placeholderMask = CAShapeLayer()
    private var author: CommentAuthor?
    private var isReply = false
    private var imageGeneration: UInt64 = 0
    private var imageTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        avatarImage.wantsLayer = true
        avatarImage.imageScaling = .scaleAxesIndependently
        avatarImage.setAccessibilityElement(false)
        placeholderImage.image = NSImage(
            systemSymbolName: NativeAvatarPlaceholder.systemSymbolName,
            accessibilityDescription: nil
        )
        placeholderImage.imageScaling = .scaleProportionallyUpOrDown
        placeholderImage.contentTintColor = NativeAvatarPlaceholder.tintColor
        placeholderImage.wantsLayer = true
        placeholderImage.setAccessibilityElement(false)
        addSubview(placeholderImage)
        addSubview(avatarImage)
        addSubview(mark)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        author: CommentAuthor,
        isReply: Bool,
        loader: NativePlaybackCommentAvatarLoader
    ) {
        cancelImageRequest()
        self.author = author
        self.isReply = isReply
        avatarImage.image = nil
        avatarImage.isHidden = true
        placeholderImage.isHidden = false
        mark.kind = NativeCommentAvatarMark(author: author)
        mark.isReply = isReply
        if let reference = author.avatar {
            if let cached = loader.cachedImage(for: reference) {
                apply(cached, animated: false)
            } else {
                let generation = imageGeneration
                imageTask = Task { [weak self] in
                    let result = await loader.image(for: reference)
                    guard let self, !Task.isCancelled,
                        self.imageGeneration == generation,
                        self.author?.avatar == reference
                    else { return }
                    self.imageTask = nil
                    guard let result else { return }
                    self.apply(
                        result.image,
                        animated: result.origin.shouldAnimate
                    )
                }
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        avatarImage.frame = bounds
        placeholderImage.frame = bounds
        let markSize = NativePlaybackCommentAvatarMarkView.size(isReply: isReply)
        mark.frame = NSRect(
            x: bounds.maxX - markSize,
            y: bounds.maxY - markSize,
            width: markSize,
            height: markSize
        )
        let cutout =
            mark.kind == nil
            ? nil
            : mark.frame.insetBy(
                dx: -NativePlaybackCommentAvatarMarkView.gap(isReply: isReply),
                dy: -NativePlaybackCommentAvatarMarkView.gap(isReply: isReply)
            )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMask(avatarMask, to: avatarImage, cutout: cutout)
        applyMask(placeholderMask, to: placeholderImage, cutout: cutout)
        CATransaction.commit()
    }

    func releaseImage() {
        cancelImageRequest()
        avatarImage.image = nil
        avatarImage.isHidden = true
        placeholderImage.isHidden = false
    }

    func reset() {
        releaseImage()
        author = nil
        mark.kind = nil
        needsLayout = true
    }

    /// 遮罩路径用子视图自己的坐标；角标所在区域经坐标转换，与子视图是否翻转无关。
    private func applyMask(_ mask: CAShapeLayer, to view: NSView, cutout: NSRect?) {
        guard let layer = view.layer else { return }
        var shape = CGPath(ellipseIn: view.bounds, transform: nil)
        if let cutout {
            shape = shape.subtracting(
                CGPath(ellipseIn: view.convert(cutout, from: self), transform: nil)
            )
        }
        mask.frame = view.bounds
        mask.path = shape
        layer.mask = mask
    }

    private func cancelImageRequest() {
        imageGeneration &+= 1
        imageTask?.cancel()
        imageTask = nil
        avatarImage.layer?.removeAnimation(
            forKey: "native-playback-comment-avatar.fade"
        )
        avatarImage.layer?.opacity = 1
    }

    private func apply(_ image: CGImage, animated: Bool) {
        let generation = imageGeneration
        avatarImage.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        avatarImage.isHidden = false
        guard animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let imageLayer = avatarImage.layer
        else {
            placeholderImage.isHidden = true
            return
        }
        imageLayer.removeAnimation(
            forKey: "native-playback-comment-avatar.fade"
        )
        imageLayer.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = NativePlaybackCommentImageTransition.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.imageGeneration == generation else { return }
            self.placeholderImage.isHidden = true
        }
        imageLayer.add(
            animation,
            forKey: "native-playback-comment-avatar.fade"
        )
        CATransaction.commit()
    }
}

/// 画出 `NativeCommentAvatarMark`：彩色圆底加白色字形；与头像之间的缝隙由头像遮罩抠出。
@MainActor
private final class NativePlaybackCommentAvatarMarkView: NSView {
    private static let rootSize: CGFloat = 13
    private static let replySize: CGFloat = 10
    private static let rootGap: CGFloat = 1.5
    private static let replyGap: CGFloat = 1
    private static let rootGlyphPointSize: CGFloat = 8
    private static let replyGlyphPointSize: CGFloat = 6
    /// 大会员标志字形，不随语言变化。
    private static let vipGlyph = "大"

    static func size(isReply: Bool) -> CGFloat {
        isReply ? replySize : rootSize
    }

    static func gap(isReply: Bool) -> CGFloat {
        isReply ? replyGap : rootGap
    }

    override var isFlipped: Bool { true }

    var kind: NativeCommentAvatarMark? {
        didSet {
            guard kind != oldValue else { return }
            isHidden = kind == nil
            needsDisplay = true
        }
    }

    var isReply = false {
        didSet {
            guard isReply != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let kind else { return }
        kind.background.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let glyphPointSize = isReply ? Self.replyGlyphPointSize : Self.rootGlyphPointSize
        switch kind {
        case .personalVerification, .organizationVerification:
            let configuration = NSImage.SymbolConfiguration(
                pointSize: glyphPointSize,
                weight: .bold
            ).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard
                let symbol = NSImage(
                    systemSymbolName: "bolt.fill",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(configuration)
            else { return }
            symbol.draw(in: centered(symbol.size))
        case .vip:
            let text = NSAttributedString(
                string: Self.vipGlyph,
                attributes: [
                    .font: NSFont.systemFont(ofSize: glyphPointSize, weight: .heavy),
                    .foregroundColor: NSColor.white
                ]
            )
            text.draw(in: centered(text.size()))
        }
    }

    private func centered(_ size: NSSize) -> NSRect {
        NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
