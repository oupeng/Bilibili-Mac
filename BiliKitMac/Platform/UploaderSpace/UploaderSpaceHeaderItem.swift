import AppKit
import BiliModels
import BiliVideoCollectionUI

/// 空间层头部的展示值。
struct UploaderSpaceHeaderContent: Equatable {
    let name: String
    let avatarURL: URL?
    /// 投稿总数未知（首页加载中）时为 nil，不显示。
    let totalCount: Int?
    let order: UploaderVideoOrder
}

/// 空间层头部：返回、头像、名字与投稿数，右侧三段排序。
///
/// 随列表一起滚动，滚到工具栏下由系统做边缘模糊。
@MainActor
final class UploaderSpaceHeaderItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("UploaderSpaceHeaderItem")
    static let orders: [UploaderVideoOrder] = [.newest, .mostPlayed, .mostFavorited]

    private let headerView = UploaderSpaceHeaderView()

    override func loadView() {
        view = headerView
    }

    func configure(
        content: UploaderSpaceHeaderContent,
        imagePipeline: NativeVideoImagePipeline,
        onClose: @escaping () -> Void,
        onSelectOrder: @escaping (UploaderVideoOrder) -> Void
    ) {
        headerView.configure(content: content, imagePipeline: imagePipeline)
        headerView.onClose = onClose
        headerView.onSelectOrder = onSelectOrder
    }

    func invalidateImageRequests() {
        headerView.cancelAvatarRequest()
    }
}

@MainActor
private final class UploaderSpaceHeaderView: NSView {
    override var isFlipped: Bool { true }

    var onClose: (() -> Void)?
    var onSelectOrder: ((UploaderVideoOrder) -> Void)?

    private let backButton = NSButton(
        image: NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: AppStrings.localized("返回详情")
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let avatar = NativeVideoLayerImageView(
        placeholderSystemSymbolName: NativeAvatarPlaceholder.systemSymbolName,
        placeholderTintColor: NativeAvatarPlaceholder.tintColor
    )
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let orderControl = NSSegmentedControl(
        labels: [
            AppStrings.localized("最新发布"),
            AppStrings.localized("最多播放"),
            AppStrings.localized("最多收藏")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var avatarURL: URL?
    private var avatarTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backButton.isBordered = false
        backButton.imagePosition = .imageOnly
        backButton.symbolConfiguration = .init(textStyle: .title3, scale: .medium)
        backButton.target = self
        backButton.action = #selector(close)
        backButton.toolTip = AppStrings.localized("返回详情")
        backButton.setAccessibilityLabel(AppStrings.localized("返回详情"))

        avatar.layer?.cornerRadius = UploaderSpaceGeometry.avatarSize / 2
        avatar.setAccessibilityElement(false)

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail

        orderControl.target = self
        orderControl.action = #selector(selectOrder)
        orderControl.setAccessibilityLabel(AppStrings.localized("排序"))

        for subview in [backButton, avatar, nameLabel, countLabel, orderControl] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(content: UploaderSpaceHeaderContent, imagePipeline: NativeVideoImagePipeline) {
        nameLabel.stringValue = content.name
        nameLabel.setAccessibilityLabel(AppStrings.localized("UP 主，\(content.name)"))
        if let totalCount = content.totalCount {
            countLabel.stringValue = AppStrings.localized("\(totalCount) 个投稿")
            countLabel.isHidden = false
        } else {
            countLabel.isHidden = true
        }
        orderControl.selectedSegment =
            UploaderSpaceHeaderItem.orders.firstIndex(of: content.order) ?? 0
        if avatarURL != content.avatarURL {
            loadAvatar(content.avatarURL, imagePipeline: imagePipeline)
        }
        needsLayout = true
    }

    func cancelAvatarRequest() {
        avatarTask?.cancel()
        avatarTask = nil
        // 下次配置时重新加载。
        avatarURL = nil
    }

    override func layout() {
        super.layout()
        let padding = UploaderSpaceGeometry.headerHorizontalPadding
        let spacing = UploaderSpaceGeometry.headerSpacing
        let midY = bounds.midY
        let backSize = UploaderSpaceGeometry.backButtonSize
        backButton.frame = NSRect(
            x: padding,
            y: midY - backSize / 2,
            width: backSize,
            height: backSize
        )

        let avatarSize = UploaderSpaceGeometry.avatarSize
        avatar.frame = NSRect(
            x: backButton.frame.maxX + spacing,
            y: midY - avatarSize / 2,
            width: avatarSize,
            height: avatarSize
        )

        let controlSize = orderControl.fittingSize
        orderControl.frame = NSRect(
            x: bounds.width - padding - controlSize.width,
            y: midY - controlSize.height / 2,
            width: controlSize.width,
            height: controlSize.height
        )

        let textX = avatar.frame.maxX + spacing
        let textWidth = max(0, orderControl.frame.minX - spacing - textX)
        let nameHeight = nameLabel.fittingSize.height
        let countHeight = countLabel.isHidden ? 0 : countLabel.fittingSize.height
        let textTop = midY - (nameHeight + countHeight) / 2
        nameLabel.frame = NSRect(x: textX, y: textTop, width: textWidth, height: nameHeight)
        countLabel.frame = NSRect(
            x: textX,
            y: nameLabel.frame.maxY,
            width: textWidth,
            height: countHeight
        )
    }

    @objc private func close() {
        onClose?()
    }

    @objc private func selectOrder() {
        let index = orderControl.selectedSegment
        guard UploaderSpaceHeaderItem.orders.indices.contains(index) else { return }
        onSelectOrder?(UploaderSpaceHeaderItem.orders[index])
    }

    private func loadAvatar(_ url: URL?, imagePipeline: NativeVideoImagePipeline) {
        avatarTask?.cancel()
        avatarURL = url
        avatar.setImage(nil, animated: false)
        guard let url else { return }
        if let cached = imagePipeline.cachedImage(for: url, variant: .avatar) {
            avatar.setImage(cached, animated: false)
            return
        }
        avatarTask = Task { [weak self] in
            let result = await imagePipeline.image(for: url, variant: .avatar)
            guard let self, !Task.isCancelled, avatarURL == url, let result else { return }
            avatar.setImage(result.image, animated: result.origin.shouldFadeIn)
        }
    }
}
