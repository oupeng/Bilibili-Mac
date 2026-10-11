import AppKit
import BiliBrowseFeature

/// UP 主空间投稿列表的一行：左封面、右标题与数据。
///
/// 整行可点，悬停高亮，正在播放的行常亮。
@MainActor
final class UploaderSpaceVideoRowItem: NSCollectionViewItem, NativeHoverableCollectionItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("UploaderSpaceVideoRowItem")

    private let rowView = UploaderSpaceVideoRowView()
    private var imageTask: Task<Void, Never>?
    private var imageGeneration: UInt64 = 0
    private var loadedCoverURL: URL?
    /// 离屏时请求被取消，回到屏幕后需要按这个标记重新加载。
    private var hasCoverImage = false

    override func loadView() {
        view = rowView
    }

    func configure(
        row: UploaderVideoRowPresentation,
        isCurrent: Bool,
        imagePipeline: NativeVideoImagePipeline,
        onSelect: @escaping (String) -> Void,
        hoverChanged: @escaping (UploaderSpaceVideoRowItem, Bool) -> Void
    ) {
        rowView.configure(row: row, isCurrent: isCurrent)
        rowView.onActivate = { onSelect(row.bvid) }
        rowView.onHoverChange = { [weak self] isHovered in
            guard let self else { return }
            hoverChanged(self, isHovered)
        }
        // 请求进行中时不重启：列表会因为“正在播放”等变化频繁重配可见行。
        if loadedCoverURL != row.coverURL || (!hasCoverImage && imageTask == nil) {
            loadCover(row.coverURL, imagePipeline: imagePipeline)
        }
    }

    /// 只刷新“正在播放”外观，不重新加载封面。
    func setCurrent(_ isCurrent: Bool) {
        rowView.setCurrent(isCurrent)
    }

    func setHovered(_ hovered: Bool) {
        rowView.setHovered(hovered)
    }

    func clearHover() {
        rowView.setHovered(false)
    }

    func invalidateImageRequests() {
        imageGeneration &+= 1
        imageTask?.cancel()
        imageTask = nil
    }

    override func prepareForReuse() {
        invalidateImageRequests()
        loadedCoverURL = nil
        hasCoverImage = false
        rowView.reset()
        super.prepareForReuse()
    }

    private func loadCover(_ url: URL?, imagePipeline: NativeVideoImagePipeline) {
        invalidateImageRequests()
        loadedCoverURL = url
        hasCoverImage = false
        rowView.cover.setImage(nil, animated: false)
        guard let url else { return }
        if let cached = imagePipeline.cachedImage(for: url, variant: .cover) {
            rowView.cover.setImage(cached, animated: false)
            hasCoverImage = true
            return
        }
        let generation = imageGeneration
        imageTask = Task { [weak self] in
            let result = await imagePipeline.image(for: url, variant: .cover)
            guard let self, !Task.isCancelled, imageGeneration == generation, let result
            else { return }
            rowView.cover.setImage(result.image, animated: result.origin.shouldAnimate)
            hasCoverImage = true
            imageTask = nil
        }
    }
}

@MainActor
final class UploaderSpaceVideoRowView: NSView {
    override var isFlipped: Bool { true }

    let cover = NativeVideoLayerImageView(
        placeholderSystemSymbolName: "play.rectangle",
        placeholderTintColor: .tertiaryLabelColor
    )
    var onActivate: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private let durationBackground = NSView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let playingIcon = NSImageView()
    private let playingLabel = NSTextField(labelWithString: AppStrings.localized("正在播放"))
    private let collaborationLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private var row: UploaderVideoRowPresentation?
    private var isCurrent = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = UploaderSpaceGeometry.rowCornerRadius

        cover.layer?.cornerRadius = UploaderSpaceGeometry.coverCornerRadius
        cover.setAccessibilityElement(false)

        durationBackground.wantsLayer = true
        durationBackground.layer?.cornerRadius = UploaderSpaceGeometry.badgeCornerRadius
        durationBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        durationLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .medium
        )
        durationLabel.textColor = .white

        titleLabel.font = .preferredFont(forTextStyle: .callout)
        // 整行可点，标题不可选中：否则指针在标题上变成文本选择形状，点击也会被文本框吃掉。
        titleLabel.isSelectable = false
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true

        playingIcon.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playingIcon.contentTintColor = .controlAccentColor
        playingIcon.symbolConfiguration = .init(textStyle: .caption1, scale: .small)
        playingLabel.font = NSFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        playingLabel.textColor = .controlAccentColor

        collaborationLabel.font = .preferredFont(forTextStyle: .caption2)
        collaborationLabel.textColor = .secondaryLabelColor
        collaborationLabel.wantsLayer = true
        collaborationLabel.layer?.cornerRadius = UploaderSpaceGeometry.badgeCornerRadius
        collaborationLabel.layer?.borderWidth = UploaderSpaceGeometry.collaborationBorderWidth

        metadataLabel.font = .preferredFont(forTextStyle: .caption1)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail

        for subview in [
            cover, durationBackground, durationLabel, titleLabel, playingIcon, playingLabel,
            collaborationLabel, metadataLabel
        ] {
            addSubview(subview)
        }
        for label in [durationLabel, titleLabel, playingLabel, collaborationLabel, metadataLabel] {
            label.setAccessibilityElement(false)
        }
        playingIcon.setAccessibilityElement(false)

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(activate)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refreshBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(row: UploaderVideoRowPresentation, isCurrent: Bool) {
        self.row = row
        titleLabel.stringValue = row.title
        durationLabel.stringValue = row.durationText ?? ""
        durationLabel.isHidden = row.durationText == nil
        durationBackground.isHidden = row.durationText == nil
        collaborationLabel.stringValue = " \(row.collaborationText) "
        collaborationLabel.isHidden = !row.isCollaboration
        metadataLabel.stringValue = row.metadataText
        setCurrent(isCurrent)
        needsLayout = true
    }

    func setCurrent(_ isCurrent: Bool) {
        self.isCurrent = isCurrent
        playingIcon.isHidden = !isCurrent
        playingLabel.isHidden = !isCurrent
        if let row {
            setAccessibilityLabel(
                isCurrent
                    ? ListFormatter.localizedString(
                        byJoining: [row.accessibilityLabel, AppStrings.localized("正在播放")]
                    )
                    : row.accessibilityLabel
            )
        }
        refreshBackground()
        needsLayout = true
    }

    func setHovered(_ isHovered: Bool) {
        guard self.isHovered != isHovered else { return }
        self.isHovered = isHovered
        refreshBackground()
    }

    func reset() {
        row = nil
        onActivate = nil
        onHoverChange = nil
        isHovered = false
        isCurrent = false
        titleLabel.stringValue = ""
        metadataLabel.stringValue = ""
        cover.setImage(nil, animated: false)
        refreshBackground()
    }

    override func layout() {
        super.layout()
        let padding = UploaderSpaceGeometry.rowPadding
        let coverFrame = NSRect(
            x: padding,
            y: padding,
            width: UploaderSpaceGeometry.coverWidth,
            height: UploaderSpaceGeometry.coverHeight
        )
        cover.frame = coverFrame

        let durationSize = durationLabel.fittingSize
        durationLabel.frame = NSRect(
            x: coverFrame.maxX - durationSize.width
                - UploaderSpaceGeometry.durationBadgeTrailingInset,
            y: coverFrame.maxY - durationSize.height
                - UploaderSpaceGeometry.durationBadgeBottomInset,
            width: durationSize.width,
            height: durationSize.height
        )
        durationBackground.frame = durationLabel.frame.insetBy(
            dx: -UploaderSpaceGeometry.durationBadgePadding.width,
            dy: -UploaderSpaceGeometry.durationBadgePadding.height
        )

        let textX = coverFrame.maxX + UploaderSpaceGeometry.coverTextSpacing
        let textWidth = max(0, bounds.width - textX - padding)
        let titleHeight = min(
            titleLabel.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
                .height,
            ceil((titleLabel.font?.boundingRectForFont.height ?? 16) * 2)
        )
        titleLabel.frame = NSRect(
            x: textX,
            y: coverFrame.minY,
            width: textWidth,
            height: titleHeight
        )

        let metadataHeight = metadataLabel.fittingSize.height
        metadataLabel.frame = NSRect(
            x: textX,
            y: coverFrame.maxY - metadataHeight,
            width: textWidth,
            height: metadataHeight
        )

        var badgeX = textX
        let badgeBottom = metadataLabel.frame.minY - UploaderSpaceGeometry.badgeToMetadataSpacing
        if !playingLabel.isHidden {
            let iconSize = playingIcon.fittingSize
            let labelSize = playingLabel.fittingSize
            playingIcon.frame = NSRect(
                x: badgeX,
                y: badgeBottom - (labelSize.height + iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            playingLabel.frame = NSRect(
                x: playingIcon.frame.maxX + UploaderSpaceGeometry.playingIconSpacing,
                y: badgeBottom - labelSize.height,
                width: labelSize.width,
                height: labelSize.height
            )
            badgeX = playingLabel.frame.maxX + UploaderSpaceGeometry.badgeSpacing
        }
        if !collaborationLabel.isHidden {
            let size = collaborationLabel.fittingSize
            collaborationLabel.frame = NSRect(
                x: badgeX,
                y: badgeBottom - size.height,
                width: size.width,
                height: size.height
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        onHoverChange?(false)
    }

    /// 与视频卡片一致：整行显示手形指针。
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    @objc private func activate() {
        onActivate?()
    }

    private func refreshBackground() {
        let fill: NSColor =
            isCurrent
            ? .controlAccentColor.withAlphaComponent(0.15)
            : isHovered ? .labelColor.withAlphaComponent(0.06) : .clear
        layer?.backgroundColor = fill.cgColor(for: effectiveAppearance)
        collaborationLabel.layer?.borderColor =
            NSColor.secondaryLabelColor.cgColor(for: effectiveAppearance)
    }
}

extension NSFont {
    fileprivate func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
