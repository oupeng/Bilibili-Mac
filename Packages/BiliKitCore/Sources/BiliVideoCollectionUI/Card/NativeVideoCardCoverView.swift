import AppKit
import BiliUI
import CoreGraphics
import QuartzCore

/// 栅格化后的 SF Symbol：位图与它的点尺寸。
struct NativeVideoCardSymbolRaster {
    let image: CGImage
    let size: NSSize
}

/// 封面指标图标的栅格化与缓存：按名字、字号、字重、缩放与外观画成 `CGImage`，直接作为 layer 内容。
@MainActor
enum NativeVideoCardSymbolRasterizer {
    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
        let scale: CGFloat
        let appearanceName: String
    }

    /// 只防止无界增长：实际用到的图标、缩放与外观组合远少于此，满了随意淘汰一项即可。
    private static let maximumRasterCount = 32
    private static var rasters: [Key: NativeVideoCardSymbolRaster] = [:]

    static func raster(
        named name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        scale requestedScale: CGFloat,
        appearance: NSAppearance
    ) -> NativeVideoCardSymbolRaster? {
        let scale = max(1, requestedScale)
        let key = Key(
            name: name,
            pointSize: pointSize,
            weight: weight.rawValue,
            scale: scale,
            appearanceName: appearance.name.rawValue
        )
        if let cached = rasters[key] { return cached }

        var raster: NativeVideoCardSymbolRaster?
        appearance.performAsCurrentDrawingAppearance {
            let pointConfiguration = NSImage.SymbolConfiguration(
                pointSize: pointSize,
                weight: weight
            )
            // 弹幕图标是多层符号，两层分别上色，文字线条才不会与气泡融成一块；其他图标单层白色。
            let paletteColors: [NSColor] =
                name == "text.bubble.fill" ? [.black, .white] : [.white]
            let colorConfiguration = NSImage.SymbolConfiguration(
                paletteColors: paletteColors
            )
            guard
                let image = NSImage(
                    systemSymbolName: name,
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(pointConfiguration.applying(colorConfiguration)),
                image.size.width > 0,
                image.size.height > 0
            else { return }

            let pixelWidth = max(1, Int(ceil(image.size.width * scale)))
            let pixelHeight = max(1, Int(ceil(image.size.height * scale)))
            guard
                let representation = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixelWidth,
                    pixelsHigh: pixelHeight,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            else { return }
            representation.size = image.size
            guard let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
                return
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            graphicsContext.cgContext.clear(
                NSRect(origin: .zero, size: image.size)
            )
            image.draw(
                in: NSRect(origin: .zero, size: image.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            graphicsContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let cgImage = representation.cgImage else { return }
            raster = NativeVideoCardSymbolRaster(image: cgImage, size: image.size)
        }
        guard let raster else { return nil }

        if rasters.count >= maximumRasterCount,
            let evictedKey = rasters.keys.first
        {
            rasters.removeValue(forKey: evictedKey)
        }
        rasters[key] = raster
        return raster
    }
}

/// 卡片封面：图片、占位、底部渐变与指标／时长文字都是同一视图里的持久 layer，不用子视图与 SwiftUI。
///
/// 不接收点击（`hitTest` 返回 nil），由卡片处理；图片由卡片经 `setImage` 设置。
@MainActor
final class NativeVideoMergedCoverView: NSView {
    private static let overlayHeight: CGFloat = 35
    private static let metricBottomOffset: CGFloat = 22
    private static let leadingInset: CGFloat = 9
    private static let symbolPointSize: CGFloat = 11
    private static let symbolWeight = NSFont.Weight.medium
    private static let iconTextSpacing: CGFloat = 4
    private static let metricSpacing: CGFloat = 10
    private static let trailingInset: CGFloat = 9
    private let placeholderLayer = CALayer()
    private let imageLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let metricIconLayers = [CALayer(), CALayer()]
    private let metricTextLayers = [
        NativeVideoMergedCoverView.makeTextLayer(
            font: .systemFont(ofSize: 12, weight: .medium)
        ),
        NativeVideoMergedCoverView.makeTextLayer(
            font: .systemFont(ofSize: 12, weight: .medium)
        )
    ]
    private let metricCells = [
        NativeVideoMergedCoverView.makeLabelCell(
            font: .systemFont(ofSize: 12, weight: .medium)
        ),
        NativeVideoMergedCoverView.makeLabelCell(
            font: .systemFont(ofSize: 12, weight: .medium)
        )
    ]
    private var metricIconNames: [String?] = [nil, nil]
    private var metricIconSizes: [NSSize] = [.zero, .zero]
    private var metricSizes: [NSSize] = [.zero, .zero]
    private var metricCount = 0
    private let trailingCell = NativeVideoMergedCoverView.makeLabelCell(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    )
    private let trailingTextLayer = NativeVideoMergedCoverView.makeTextLayer(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        alignmentMode: .right
    )
    private var trailingSize = NSSize.zero
    private lazy var imageFade = NativeVideoImageFade(
        imageLayer: imageLayer,
        placeholderLayer: placeholderLayer
    )

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = VideoCardGeometry.coverCornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = Self.backgroundColor.cgColor(for: effectiveAppearance)

        placeholderLayer.contentsGravity = .center
        placeholderLayer.actions = Self.imageLayerActions
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = Self.imageLayerActions
        gradientLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.78).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.actions = Self.disabledLayerActions
        layer?.addSublayer(placeholderLayer)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(gradientLayer)
        for index in metricIconLayers.indices {
            let iconLayer = metricIconLayers[index]
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.actions = Self.disabledLayerActions
            iconLayer.isHidden = true
            layer?.addSublayer(iconLayer)

            metricTextLayers[index].isHidden = true
            layer?.addSublayer(metricTextLayers[index])
        }
        trailingTextLayer.isHidden = true
        layer?.addSublayer(trailingTextLayer)
        refreshPlaceholderImage()
        setImage(nil, animated: false)
        updateContentsScale()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(metrics: [NativeVideoCardMetric], trailingText: String?) {
        metricCount = min(metrics.count, metricCells.count)
        for index in metricCells.indices {
            guard index < metricCount else {
                metricCells[index].stringValue = ""
                metricIconNames[index] = nil
                metricIconSizes[index] = .zero
                metricSizes[index] = .zero
                metricIconLayers[index].contents = nil
                metricIconLayers[index].isHidden = true
                metricTextLayers[index].string = nil
                metricTextLayers[index].isHidden = true
                continue
            }
            let metric = metrics[index]
            metricCells[index].stringValue = metric.text
            metricTextLayers[index].string = metric.text
            metricTextLayers[index].isHidden = false
            metricIconNames[index] = metric.systemImage
            metricSizes[index] = integralSize(metricCells[index].cellSize)
        }
        trailingCell.stringValue = trailingText ?? ""
        trailingTextLayer.string = trailingText ?? ""
        trailingTextLayer.isHidden = trailingText?.isEmpty ?? true
        trailingSize = integralSize(trailingCell.cellSize)
        refreshMetricIcons()
        needsLayout = true
    }

    func reset() {
        metricCount = 0
        for index in metricCells.indices {
            metricCells[index].stringValue = ""
            metricIconNames[index] = nil
            metricIconSizes[index] = .zero
            metricSizes[index] = .zero
            metricIconLayers[index].contents = nil
            metricIconLayers[index].isHidden = true
            metricTextLayers[index].string = nil
            metricTextLayers[index].isHidden = true
        }
        trailingCell.stringValue = ""
        trailingTextLayer.string = nil
        trailingTextLayer.isHidden = true
        trailingSize = .zero
        setImage(nil, animated: false)
        needsLayout = true
    }

    func setImage(_ image: CGImage?, animated: Bool) {
        imageFade.setImage(image, animated: animated)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        refreshMetricIcons()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
        refreshMetricIcons()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Self.backgroundColor.cgColor(for: effectiveAppearance)
        refreshPlaceholderImage()
        refreshMetricIcons()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let placeholderSize = NSSize(width: 32, height: 32)
        placeholderLayer.frame = NSRect(
            x: floor((bounds.width - placeholderSize.width) / 2),
            y: floor((bounds.height - placeholderSize.height) / 2),
            width: placeholderSize.width,
            height: placeholderSize.height
        )
        imageLayer.frame = bounds
        let overlayHeight = min(Self.overlayHeight, bounds.height)
        gradientLayer.frame = NSRect(
            x: 0,
            y: bounds.height - overlayHeight,
            width: bounds.width,
            height: overlayHeight
        )
        let metricY = bounds.height - Self.metricBottomOffset
        var nextX = Self.leadingInset
        for index in 0..<metricCount {
            let iconSize = metricIconSizes[index]
            let cellSize = metricSizes[index]
            let iconFrame = NSRect(
                x: nextX,
                y: metricY + floor((cellSize.height - iconSize.height) / 2),
                width: iconSize.width,
                height: iconSize.height
            )
            metricIconLayers[index].frame = iconFrame
            let cellFrame = NSRect(
                x: iconFrame.maxX + Self.iconTextSpacing,
                y: metricY,
                width: cellSize.width,
                height: cellSize.height
            )
            metricTextLayers[index].frame = cellFrame
            nextX = cellFrame.maxX + Self.metricSpacing
        }
        if !trailingCell.stringValue.isEmpty {
            trailingTextLayer.frame = NSRect(
                x: bounds.width - trailingSize.width - Self.trailingInset,
                y: metricY,
                width: trailingSize.width,
                height: trailingSize.height
            )
        }
        placeholderLayer.contentsScale = scale
        imageLayer.contentsScale = scale
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func integralSize(_ size: NSSize) -> NSSize {
        NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func refreshMetricIcons() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = effectiveAppearance
        for index in 0..<metricCount {
            guard let name = metricIconNames[index] else {
                metricIconLayers[index].contents = nil
                metricIconLayers[index].isHidden = true
                continue
            }
            let raster = NativeVideoCardSymbolRasterizer.raster(
                named: name,
                pointSize: Self.symbolPointSize,
                weight: Self.symbolWeight,
                scale: scale,
                appearance: appearance
            )
            metricIconLayers[index].contents = raster?.image
            metricIconLayers[index].contentsScale = scale
            metricIconLayers[index].isHidden = raster == nil
            metricIconSizes[index] = raster?.size ?? .zero
        }
        needsLayout = true
    }

    private func refreshPlaceholderImage() {
        let configuration = NSImage.SymbolConfiguration(
            paletteColors: [.tertiaryLabelColor]
        )
        placeholderLayer.contents = NSImage(
            systemSymbolName: "photo",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        placeholderLayer.contentsScale = scale
        imageLayer.contentsScale = scale
        for textLayer in metricTextLayers {
            textLayer.contentsScale = scale
        }
        trailingTextLayer.contentsScale = scale
    }

    private static func makeLabelCell(font: NSFont) -> NSTextFieldCell {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = font
        cell.textColor = .white
        cell.lineBreakMode = .byTruncatingTail
        cell.isBezeled = false
        cell.isBordered = false
        cell.drawsBackground = false
        cell.isEditable = false
        cell.isSelectable = false
        cell.usesSingleLineMode = true
        return cell
    }

    private static func makeTextLayer(
        font: NSFont,
        alignmentMode: CATextLayerAlignmentMode = .left
    ) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.font = NativeVideoCardTextLayout.ctFont(font)
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = alignmentMode
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        textLayer.actions = disabledLayerActions
        return textLayer
    }

    private static let disabledLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
        "string": NSNull()
    ]

    private static let imageLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
        "opacity": NSNull(),
        "position": NSNull()
    ]

    private static var backgroundColor: NSColor {
        NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    }
}

/// 卡片头像，以及 UP 主空间的头像与投稿封面：占位 SF Symbol 与图片两层，图片到达时可淡入。
@MainActor
package final class NativeVideoLayerImageView: NSView {
    private let placeholderSystemSymbolName: String
    private let placeholderTintColor: NSColor
    private let placeholderLayer = CALayer()
    private let imageLayer = CALayer()
    private lazy var imageFade = NativeVideoImageFade(
        imageLayer: imageLayer,
        placeholderLayer: placeholderLayer
    )

    package init(
        placeholderSystemSymbolName: String,
        placeholderTintColor: NSColor
    ) {
        self.placeholderSystemSymbolName = placeholderSystemSymbolName
        self.placeholderTintColor = placeholderTintColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        placeholderLayer.contentsGravity = .center
        placeholderLayer.actions = [
            "contents": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = [
            "contents": NSNull(),
            "opacity": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        layer?.addSublayer(placeholderLayer)
        layer?.addSublayer(imageLayer)
        refreshPlaceholderImage()
        setImage(nil, animated: false)
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override func layout() {
        super.layout()
        let size = bounds.size
        placeholderLayer.frame = NSRect(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
        imageLayer.frame = bounds
        placeholderLayer.contentsScale = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshPlaceholderImage()
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    package func setImage(_ image: CGImage?, animated: Bool) {
        imageFade.setImage(image, animated: animated)
    }

    private func refreshPlaceholderImage() {
        let colorConfiguration = NSImage.SymbolConfiguration(
            paletteColors: [placeholderTintColor]
        )
        placeholderLayer.contents = NSImage(
            systemSymbolName: placeholderSystemSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(colorConfiguration)
    }
}

/// 占位层与图片层之间的淡入，封面（`NativeVideoMergedCoverView`）与头像（`NativeVideoLayerImageView`）各持有
/// 一个；不拥有这两个 layer，只改图片层的内容与占位显隐，透明度动画交给 `NativeImageFadeAnimation`。
///
/// 清空图片时立即显示占位；新图淡入期间占位留在下面，淡入结束（且其间没有新的设置）才隐藏，不淡入时立即隐藏。
@MainActor
final class NativeVideoImageFade {
    private let imageLayer: CALayer
    private let placeholderLayer: CALayer
    private let fade = NativeImageFadeAnimation(key: "native-video-image.fade")

    init(imageLayer: CALayer, placeholderLayer: CALayer) {
        self.imageLayer = imageLayer
        self.placeholderLayer = placeholderLayer
    }

    func setImage(_ image: CGImage?, animated: Bool) {
        imageLayer.contents = image
        guard image != nil else {
            fade.cancel(on: imageLayer)
            placeholderLayer.isHidden = false
            return
        }
        let fades = fade.fadeIn(imageLayer, animated: animated) { [placeholderLayer] in
            placeholderLayer.isHidden = true
        }
        if fades {
            placeholderLayer.isHidden = false
        }
    }
}
