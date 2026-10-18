import AppKit
import BiliModels
import Observation

/// 评论图片预览的「保存图片」：先弹系统保存面板，选好位置后再取原图原样写入（GIF 仍是 GIF）。
///
/// 窗口级 owner：用户确认后的保存不随预览关闭而丢失，关窗时才取消。原图经图片管线同一套响应校验重新
/// 请求、不缓存，只写出 ImageIO 能识别的位图；写入在后台进行，失败时在发起保存的窗口上提示。
@MainActor
@Observable
public final class NativeCommentImageSaver {
    /// 图床文件名缺失时的默认文件名。
    private static let fallbackFileName = "bilikit-comment-image"

    /// 保存面板打开或原图下载、写入期间为 true；此时不再发起新的保存。
    private(set) var isBusy = false
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    /// 面板以 sheet 挂在 `window` 上；预览不在窗口里时不保存。
    func save(
        _ reference: CommentAssetReference,
        loader: NativePlaybackCommentPictureLoader,
        in window: NSWindow?
    ) {
        guard !isBusy, let window else { return }
        isBusy = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            loader.suggestedFileName(for: reference) ?? Self.fallbackFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                self.isBusy = false
                return
            }
            self.write(reference, loader: loader, to: destination, window: window)
        }
    }

    /// 关窗时取消在途保存。
    public func cancel() {
        task?.cancel()
        task = nil
        isBusy = false
    }

    private func write(
        _ reference: CommentAssetReference,
        loader: NativePlaybackCommentPictureLoader,
        to destination: URL,
        window: NSWindow?
    ) {
        task = Task { [weak self, weak window] in
            let data = await loader.originalData(for: reference)
            guard !Task.isCancelled else { return }
            let saved: Bool
            if let data {
                saved = await Task.detached(priority: .userInitiated) {
                    (try? data.write(to: destination, options: .atomic)) != nil
                }.value
            } else {
                saved = false
            }
            guard let self, !Task.isCancelled else { return }
            self.isBusy = false
            self.task = nil
            if !saved {
                Self.presentFailure(in: window)
            }
        }
    }

    private static func presentFailure(in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = VideoDetailFeatureStrings.localized("图片保存失败")
        alert.informativeText = VideoDetailFeatureStrings.localized("原图下载失败，或无法写入所选位置。")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
