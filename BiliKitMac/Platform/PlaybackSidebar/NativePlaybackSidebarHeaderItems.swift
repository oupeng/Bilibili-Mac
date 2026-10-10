import AppKit
import BiliBrowseFeature
import BiliModels
import BiliUI

@MainActor
final class NativePlaybackSidebarUploaderItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarUploaderItem"
    )

    private let contentView = NativePlaybackSidebarUploaderView()

    override func loadView() {
        view = contentView
    }

    func configure(
        content: VideoUploaderHeaderContent,
        imagePipeline: NativeVideoImagePipeline,
        onOpenSpace: (() -> Void)?
    ) {
        representedObject = content
        contentView.configure(
            content: content,
            imagePipeline: imagePipeline,
            onOpenSpace: onOpenSpace
        )
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }

    func releaseOffscreenResources() {
        contentView.releaseOffscreenResources()
    }
}

@MainActor
private final class NativePlaybackSidebarUploaderView: NSView {
    override var isFlipped: Bool { true }

    private let avatar = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// 签名只显示一行，超出省略；被截断时指针移上去由系统原地浮出完整文字（expansion tooltip）。
    private let signatureLabel = NativePlaybackUploaderGeometry.makeSignatureLabel()
    private let signatureLoadingBar = NSView()
    /// 头像与名字这一行可点进入 UP 主空间；右侧箭头同时是给键盘与 VoiceOver 的显式按钮。
    private let spaceButton = NSButton(
        image: NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: AppStrings.localized("查看 UP 主投稿")
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private var onOpenSpace: (() -> Void)?
    /// 上次登记给窗口的手形指针区域；只有区域变化时才让窗口重建 cursor rect。
    private var appliedSpaceHitRect: NSRect = .zero
    /// 只认头像与名字这一行：父视图的点击手势也会收到子视图的点击，不限定区域的话，
    /// 点签名也会误进空间。
    private lazy var spaceClickRecognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(openSpace)
    )
    private var imageTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var content: VideoUploaderHeaderContent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = NativePlaybackSidebarItemMeasurement.avatarSize / 2
        avatar.layer?.masksToBounds = true
        avatar.setAccessibilityElement(false)

        nameLabel.font = NativePlaybackUploaderGeometry.nameFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        // 名字这一行可点，名字不再可选中复制，否则文本框会吃掉点击。
        nameLabel.isSelectable = false

        spaceButton.isBordered = false
        spaceButton.imagePosition = .imageOnly
        spaceButton.contentTintColor = .tertiaryLabelColor
        spaceButton.target = self
        spaceButton.action = #selector(openSpace)
        spaceButton.toolTip = AppStrings.localized("查看 UP 主投稿")
        spaceButton.setAccessibilityLabel(AppStrings.localized("查看 UP 主投稿"))
        spaceButton.isHidden = true
        spaceClickRecognizer.delegate = self
        addGestureRecognizer(spaceClickRecognizer)

        signatureLoadingBar.wantsLayer = true
        signatureLoadingBar.layer?.cornerRadius = 3
        signatureLoadingBar.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        signatureLabel.setAccessibilityLabel(AppStrings.localized("UP 主签名"))

        for subview in [
            avatar,
            nameLabel,
            signatureLabel,
            signatureLoadingBar,
            spaceButton
        ] {
            addSubview(subview)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        content: VideoUploaderHeaderContent,
        imagePipeline: NativeVideoImagePipeline,
        onOpenSpace: (() -> Void)?
    ) {
        self.onOpenSpace = onOpenSpace
        spaceButton.isHidden = onOpenSpace == nil
        let avatarChanged = self.content?.avatarURL != content.avatarURL
        self.content = content
        nameLabel.stringValue = content.name
        nameLabel.setAccessibilityLabel(AppStrings.localized("UP 主，\(content.name)"))

        switch content.signature {
        case .loading:
            signatureLabel.isHidden = true
            signatureLoadingBar.isHidden = false
            signatureLoadingBar.setAccessibilityElement(true)
            signatureLoadingBar.setAccessibilityLabel(AppStrings.localized("签名正在加载"))
        case .hidden:
            signatureLabel.isHidden = true
            signatureLoadingBar.isHidden = true
        case .text(let signature):
            signatureLabel.stringValue = signature
            signatureLabel.isHidden = false
            signatureLoadingBar.isHidden = true
        }
        needsLayout = true
        refreshCursorRectsIfNeeded()
        if avatarChanged || avatar.image == nil {
            loadAvatar(content.avatarURL, imagePipeline: imagePipeline)
        }
    }

    override func layout() {
        super.layout()
        let avatarSize = NativePlaybackSidebarItemMeasurement.avatarSize
        avatar.frame = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
        guard let content else { return }
        let geometry = NativePlaybackUploaderGeometry(content: content, width: bounds.width)
        nameLabel.frame = geometry.nameFrame
        if !spaceButton.isHidden {
            let buttonSize = NativePlaybackUploaderGeometry.spaceButtonSize
            nameLabel.frame.size.width = max(
                0,
                geometry.nameFrame.width - buttonSize
                    - NativePlaybackUploaderGeometry.spaceButtonSpacing
            )
            spaceButton.frame = NSRect(
                x: bounds.width - buttonSize,
                y: geometry.nameFrame.midY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )
        }
        signatureLabel.frame = geometry.signatureTextFrame
        signatureLoadingBar.frame = geometry.loadingBarFrame
        refreshCursorRectsIfNeeded()
    }

    /// 头像加上名字所在整行；没有签名时整块都可点；没有空间入口时为空。
    private var spaceHitRect: NSRect {
        guard onOpenSpace != nil, let content else { return .zero }
        if content.signature == .hidden {
            return bounds
        }
        let nameRow = NSRect(x: 0, y: 0, width: bounds.width, height: nameLabel.frame.maxY)
        return nameRow.union(avatar.frame)
    }

    private func refreshCursorRectsIfNeeded() {
        let rect = spaceHitRect
        guard rect != appliedSpaceHitRect else { return }
        appliedSpaceHitRect = rect
        window?.invalidateCursorRects(for: self)
    }

    /// 与视频卡片一致：可点进入的区域显示手形指针。
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = spaceHitRect
        guard !rect.isEmpty else { return }
        addCursorRect(rect, cursor: .pointingHand)
    }

    func cancelImageRequest() {
        generation &+= 1
        imageTask?.cancel()
        imageTask = nil
    }

    func releaseOffscreenResources() {
        cancelImageRequest()
        avatar.image = nil
    }

    func reset() {
        cancelImageRequest()
        content = nil
        onOpenSpace = nil
        spaceButton.isHidden = true
        refreshCursorRectsIfNeeded()
        avatar.image = nil
        nameLabel.stringValue = ""
        signatureLabel.stringValue = ""
        signatureLoadingBar.isHidden = true
    }

    private func loadAvatar(
        _ url: URL?,
        imagePipeline: NativeVideoImagePipeline
    ) {
        cancelImageRequest()
        avatar.image = NSImage(
            systemSymbolName: "person.crop.circle.fill",
            accessibilityDescription: nil
        )
        guard let url else { return }
        generation &+= 1
        let requestGeneration = generation
        if let cached = imagePipeline.cachedImage(for: url, variant: .avatar) {
            avatar.image = NSImage(cgImage: cached, size: .zero)
            return
        }
        imageTask = Task { [weak self] in
            let result = await imagePipeline.image(for: url, variant: .avatar)
            guard let self, !Task.isCancelled,
                self.generation == requestGeneration,
                self.content?.avatarURL == url,
                let result
            else { return }
            avatar.image = NSImage(cgImage: result.image, size: .zero)
            imageTask = nil
        }
    }

    @objc private func openSpace() {
        onOpenSpace?()
    }
}

extension NativePlaybackSidebarUploaderView: NSGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard gestureRecognizer === spaceClickRecognizer else { return true }
        return spaceHitRect.contains(gestureRecognizer.location(in: self))
    }
}

@MainActor
final class NativePlaybackSidebarSummaryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarSummaryItem"
    )

    private let contentView = NativePlaybackSidebarSummaryView()

    override func loadView() {
        view = contentView
    }

    func configure(
        summary: String,
        expanded: Bool,
        onToggle: @escaping () -> Void
    ) {
        representedObject = summary
        contentView.configure(summary: summary, expanded: expanded, onToggle: onToggle)
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

@MainActor
private final class NativePlaybackSidebarSummaryView: NSView {
    override var isFlipped: Bool { true }

    private let titleLabel = NSTextField(labelWithString: AppStrings.localized("简介"))
    private let separator = NSBox()
    private let textView = NativePlaybackSidebarReadOnlyTextView(
        font: .preferredFont(forTextStyle: .callout),
        color: .secondaryLabelColor
    )
    private let toggleButton = NSButton()
    private var summary = ""
    private var expanded = false
    private var onToggle: (() -> Void)?
    private var configuredSummary: String?
    private var configuredMaximumLines: Int?
    private var hasConfiguredText = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
            weight: .semibold
        )
        toggleButton.isBordered = false
        toggleButton.font = .preferredFont(forTextStyle: .caption1)
        toggleButton.contentTintColor = .linkColor
        toggleButton.alignment = .left
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        separator.boxType = .separator
        addSubview(separator)
        addSubview(titleLabel)
        addSubview(textView)
        addSubview(toggleButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(summary: String, expanded: Bool, onToggle: @escaping () -> Void) {
        self.summary = summary
        self.expanded = expanded
        self.onToggle = onToggle
        needsLayout = true
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let geometry = NativePlaybackSummaryGeometry(
            summary: summary,
            width: bounds.width,
            expanded: expanded
        )
        titleLabel.frame = geometry.titleFrame
        let maximumLines = geometry.maximumLines
        if !hasConfiguredText
            || configuredSummary != summary
            || configuredMaximumLines != maximumLines
        {
            hasConfiguredText = true
            configuredSummary = summary
            configuredMaximumLines = maximumLines
            textView.setText(
                summary,
                font: NativePlaybackSummaryGeometry.textFont,
                color: .secondaryLabelColor,
                maximumLines: maximumLines
            )
        }
        textView.frame = geometry.textFrame
        toggleButton.isHidden = !geometry.overflows
        toggleButton.title =
            expanded
            ? AppStrings.localized("收起") : AppStrings.localized("展开")
        toggleButton.setAccessibilityLabel(
            expanded ? AppStrings.localized("收起简介") : AppStrings.localized("展开简介")
        )
        toggleButton.setAccessibilityValue(
            expanded ? AppStrings.localized("已展开") : AppStrings.localized("已折叠为五行")
        )
        toggleButton.frame = geometry.toggleFrame
    }

    func reset() {
        onToggle = nil
        summary = ""
        expanded = false
        textView.string = ""
        toggleButton.title = ""
        configuredSummary = nil
        configuredMaximumLines = nil
        hasConfiguredText = false
    }

    @objc private func toggle() {
        onToggle?()
    }
}
