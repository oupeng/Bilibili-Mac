import AppKit
import BiliModels

struct NativePlaybackCommentPictureSlot: Equatable {
    let reference: CommentAssetReference?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

struct NativePlaybackCommentPictureSlots {
    static func slots(
        images: [CommentImage],
        count: Int
    ) -> [NativePlaybackCommentPictureSlot] {
        let displayedCount = min(max(count, 0), 9)
        var result = [NativePlaybackCommentPictureSlot](
            repeating: NativePlaybackCommentPictureSlot(
                reference: nil,
                pixelWidth: nil,
                pixelHeight: nil
            ),
            count: displayedCount
        )
        for (fallbackPosition, image) in images.enumerated() {
            let position = image.position ?? fallbackPosition
            guard result.indices.contains(position),
                result[position].reference == nil
            else { continue }
            result[position] = NativePlaybackCommentPictureSlot(
                reference: image.asset,
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight
            )
        }
        return result
    }
}

struct NativePlaybackCommentPictureLayout: Equatable {
    static let maximumContentWidth: CGFloat = 364
    static let maximumImageHeight: CGFloat = 180
    static let gap: CGFloat = 4
    static let fallbackExtent: CGFloat = 120
    static let sourcePixelScale: CGFloat = 2

    let frames: [CGRect]
    let size: CGSize

    static func make(
        images: [CommentImage],
        count: Int,
        availableWidth: CGFloat
    ) -> Self {
        make(
            slots: NativePlaybackCommentPictureSlots.slots(
                images: images,
                count: count
            ),
            availableWidth: availableWidth
        )
    }

    static func make(
        slots: [NativePlaybackCommentPictureSlot],
        availableWidth: CGFloat
    ) -> Self {
        let contentWidth = floor(
            min(max(0, availableWidth), maximumContentWidth)
        )
        guard !slots.isEmpty, contentWidth >= 1 else {
            return Self(frames: [], size: .zero)
        }

        var frames: [CGRect] = []
        frames.reserveCapacity(slots.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for slot in slots {
            let itemSize = displaySize(
                for: slot,
                availableWidth: contentWidth
            )
            if x > 0, x + itemSize.width > contentWidth {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: itemSize)
            frames.append(frame)
            x = frame.maxX + gap
            rowHeight = max(rowHeight, itemSize.height)
        }

        return Self(
            frames: frames,
            size: CGSize(width: contentWidth, height: ceil(y + rowHeight))
        )
    }

    private static func displaySize(
        for slot: NativePlaybackCommentPictureSlot,
        availableWidth: CGFloat
    ) -> CGSize {
        guard let pixelWidth = slot.pixelWidth,
            let pixelHeight = slot.pixelHeight,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            let extent = min(fallbackExtent, availableWidth)
            return CGSize(width: extent, height: extent)
        }

        let sourceWidth = CGFloat(pixelWidth) / sourcePixelScale
        let sourceHeight = CGFloat(pixelHeight) / sourcePixelScale
        let scale = min(
            1,
            min(
                availableWidth / sourceWidth,
                maximumImageHeight / sourceHeight
            )
        )
        return CGSize(
            width: max(1, floor(sourceWidth * scale)),
            height: max(1, floor(sourceHeight * scale))
        )
    }
}

@MainActor
struct NativePlaybackCommentPictureGallery {
    let references: [CommentAssetReference]
    let selectedIndex: Int
    let restoreFocus: () -> Void
}

@MainActor
final class NativePlaybackCommentPicturesView: NSView {
    nonisolated override var isFlipped: Bool { true }
    private let tiles = (0..<9).map { _ in NativePlaybackCommentPictureTileView() }
    private var slots: [NativePlaybackCommentPictureSlot] = []
    private var onOpen: ((NativePlaybackCommentPictureGallery) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for tile in tiles {
            tile.isHidden = true
            addSubview(tile)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        images: [CommentImage],
        count: Int,
        loader: NativePlaybackCommentPictureLoader,
        onOpen: @escaping (NativePlaybackCommentPictureGallery) -> Void
    ) {
        self.onOpen = onOpen
        slots = NativePlaybackCommentPictureSlots.slots(
            images: images,
            count: count
        )
        for (index, tile) in tiles.enumerated() {
            guard slots.indices.contains(index) else {
                tile.isHidden = true
                tile.reset()
                continue
            }
            tile.isHidden = false
            tile.configure(
                reference: slots[index].reference,
                position: index,
                loader: loader,
                onOpen: { [weak self] in self?.openPicture(at: index) }
            )
        }
        setAccessibilityElement(!slots.isEmpty)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppStrings.localized("评论图片，共 \(slots.count) 张"))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pictureLayout = NativePlaybackCommentPictureLayout.make(
            slots: slots,
            availableWidth: bounds.width
        )
        for (index, frame) in pictureLayout.frames.enumerated() {
            tiles[index].frame = frame
        }
    }

    func releaseImages() {
        for tile in tiles { tile.releaseImage() }
    }

    func reset() {
        slots = []
        onOpen = nil
        for tile in tiles {
            tile.isHidden = true
            tile.reset()
        }
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
    }

    private func openPicture(at slotIndex: Int) {
        let validSlots = slots.enumerated().compactMap { index, slot in
            slot.reference.map { (slotIndex: index, reference: $0) }
        }
        guard
            let selectedIndex = validSlots.firstIndex(where: {
                $0.slotIndex == slotIndex
            }), tiles.indices.contains(slotIndex)
        else { return }
        let sourceTile = tiles[slotIndex]
        let selectedReference = validSlots[selectedIndex].reference
        onOpen?(
            NativePlaybackCommentPictureGallery(
                references: validSlots.map(\.reference),
                selectedIndex: selectedIndex,
                restoreFocus: { [weak sourceTile] in
                    guard
                        let sourceTile,
                        sourceTile.represents(selectedReference),
                        let window = sourceTile.window
                    else { return }
                    window.makeFirstResponder(sourceTile)
                }
            )
        )
    }
}

@MainActor
private final class NativePlaybackCommentPictureTileView: NSButton {
    nonisolated override var isFlipped: Bool { true }
    private let imageView = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: AppStrings.localized("图片"))
    /// 动图角标：只是视觉提示，读屏从按钮标签得知是动图。“GIF”是通用写法，不做本地化。
    private let animationBadge = NSTextField(labelWithString: "GIF")
    private lazy var playback = NativeAnimatedImagePlayback(
        host: self,
        onFrame: { [weak self] frame in self?.show(frame) },
        onRestoreFirstFrame: { [weak self] in
            guard let self, let firstFrame = self.firstFrame else { return }
            self.show(firstFrame)
        }
    )
    /// 当前图片的第一帧；动图停下时换回它（「减少动态效果」只显示第一帧）。
    private var firstFrame: CGImage?
    private var reference: CommentAssetReference?
    private var position = 0
    private var imageGeneration: UInt64 = 0
    private var imageTask: Task<Void, Never>?
    private var isShowingPlaceholder = true
    private var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        focusRingType = .exterior
        target = self
        action = #selector(openPicture)
        wantsLayer = true
        layer?.cornerRadius = NativePlaybackCommentImageStyle.cornerRadius
        layer?.masksToBounds = true
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityElement(false)
        placeholderLabel.font = .preferredFont(forTextStyle: .caption2)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.setAccessibilityElement(false)
        animationBadge.font = .systemFont(
            ofSize: NativePlaybackCommentImageStyle.animationBadgeFontSize,
            weight: .semibold
        )
        animationBadge.textColor = .white
        animationBadge.alignment = .center
        animationBadge.wantsLayer = true
        animationBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        animationBadge.layer?.cornerRadius =
            NativePlaybackCommentImageStyle.animationBadgeCornerRadius
        animationBadge.isHidden = true
        animationBadge.setAccessibilityElement(false)
        addSubview(imageView)
        addSubview(placeholderLabel)
        addSubview(animationBadge)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor =
            isShowingPlaceholder
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = 0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        playback.hostVisibilityDidChange()
    }

    override func viewDidHide() {
        super.viewDidHide()
        playback.hostVisibilityDidChange()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        playback.hostVisibilityDidChange()
    }

    override func layout() {
        super.layout()
        // 尺寸确定后才有可见区域：首次布局或视口变大后重新判断能否播放动图。
        defer { playback.hostVisibilityDidChange() }
        imageView.frame = bounds
        let badgeSize = animationBadge.intrinsicContentSize
        let inset = NativePlaybackCommentImageStyle.animationBadgeInset
        let padding = NativePlaybackCommentImageStyle.animationBadgePadding
        let badgeWidth = ceil(badgeSize.width) + padding * 2
        animationBadge.frame = NSRect(
            x: max(0, bounds.maxX - inset - badgeWidth),
            y: inset,
            width: badgeWidth,
            height: ceil(badgeSize.height)
        )
        placeholderLabel.frame = NSRect(
            x: 4,
            y: max(0, bounds.midY - 9),
            width: max(0, bounds.width - 8),
            height: 18
        )
    }

    func configure(
        reference: CommentAssetReference?,
        position: Int,
        loader: NativePlaybackCommentPictureLoader,
        onOpen: @escaping () -> Void
    ) {
        cancelImageRequest()
        // 同一张图重新配置（展开回复、翻页重载）时动图继续播放，换图才停下。
        if self.reference != reference {
            stopAnimation()
        }
        self.reference = reference
        self.position = position
        self.onOpen = reference == nil ? nil : onOpen
        isEnabled = reference != nil
        setAccessibilityElement(reference != nil)
        setAccessibilityRole(.button)
        updateAccessibilityLabel(isAnimated: false)
        imageView.image = nil
        imageView.isHidden = true
        placeholderLabel.isHidden = false
        isShowingPlaceholder = true
        needsDisplay = true
        guard let reference else { return }
        if let cached = loader.cachedImage(for: reference) {
            apply(cached, animation: loader.cachedAnimation(for: reference), fadesIn: false)
            return
        }
        let generation = imageGeneration
        imageTask = Task { [weak self] in
            let result = await loader.image(for: reference)
            guard let self, !Task.isCancelled,
                self.imageGeneration == generation,
                self.reference == reference
            else { return }
            self.imageTask = nil
            guard let result else { return }
            self.apply(
                result.image,
                animation: result.animation,
                fadesIn: result.origin.shouldFadeIn
            )
        }
    }

    func releaseImage() {
        cancelImageRequest()
        stopAnimation()
        imageView.image = nil
        imageView.isHidden = true
        placeholderLabel.isHidden = false
        isShowingPlaceholder = true
        needsDisplay = true
    }

    func reset() {
        releaseImage()
        reference = nil
        onOpen = nil
        isEnabled = false
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
    }

    func represents(_ reference: CommentAssetReference) -> Bool {
        self.reference == reference && isEnabled && !isHidden
    }

    private func cancelImageRequest() {
        imageGeneration &+= 1
        imageTask?.cancel()
        imageTask = nil
        imageView.layer?.removeAnimation(
            forKey: "native-playback-comment-picture.fade"
        )
        imageView.layer?.opacity = 1
    }

    private func updateAccessibilityLabel(isAnimated: Bool) {
        guard reference != nil else {
            setAccessibilityLabel(nil)
            return
        }
        setAccessibilityLabel(
            isAnimated
                ? AppStrings.localized("查看第 \(position + 1) 张评论动图")
                : AppStrings.localized("查看第 \(position + 1) 张评论图片")
        )
    }

    private func stopAnimation() {
        playback.stop()
        firstFrame = nil
        animationBadge.isHidden = true
    }

    /// 动图播放中的一帧；尺寸与第一帧相同，只换内容。
    private func show(_ frame: CGImage) {
        imageView.image = NSImage(
            cgImage: frame,
            size: NSSize(width: frame.width, height: frame.height)
        )
    }

    private func apply(_ image: CGImage, animation: NativeAnimatedImage?, fadesIn: Bool) {
        let generation = imageGeneration
        firstFrame = image
        imageView.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        imageView.isHidden = false
        placeholderLabel.isHidden = true
        animationBadge.isHidden = animation == nil
        updateAccessibilityLabel(isAnimated: animation != nil)
        playback.play(animation)
        guard fadesIn,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let imageLayer = imageView.layer
        else {
            isShowingPlaceholder = false
            needsDisplay = true
            return
        }
        imageLayer.removeAnimation(
            forKey: "native-playback-comment-picture.fade"
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
            self.isShowingPlaceholder = false
            self.needsDisplay = true
        }
        imageLayer.add(
            animation,
            forKey: "native-playback-comment-picture.fade"
        )
        CATransaction.commit()
        needsDisplay = true
    }

    @objc private func openPicture() {
        onOpen?()
    }
}
