import SwiftUI

/// 视频卡片菜单里账户写操作的入口：此刻是否满足写入门槛，以及按卡片 ID（BVID）发出写入意图。
///
/// 实现是 App 窗口的写入协调者（`AccountWriteCoordinator`），由 `AppShellView` 经 SwiftUI 环境
/// `videoCardAccountWriting` 注入；各来源的网格、横排与菜单描述只读取它，不持有 Task、不判断账户。没有注入（预览、测试）
/// 时为 nil，写操作项不出现。闭包只转发意图：门槛、卡片是否仍是同一个视频与请求的 owner 都在协调者里，并在执行时
/// 重新核对。`isAvailable` 在菜单与读屏操作每次构造时求值，不满足时菜单项显示为禁用。
public struct VideoCardAccountWriting: Sendable {
    public let isAvailable: @MainActor @Sendable () -> Bool
    public let addToWatchLater: @MainActor @Sendable (_ bvid: String) -> Void
    public let removeFromWatchLater: @MainActor @Sendable (_ bvid: String) -> Void

    public init(
        isAvailable: @escaping @MainActor @Sendable () -> Bool,
        addToWatchLater: @escaping @MainActor @Sendable (_ bvid: String) -> Void,
        removeFromWatchLater: @escaping @MainActor @Sendable (_ bvid: String) -> Void
    ) {
        self.isAvailable = isAvailable
        self.addToWatchLater = addToWatchLater
        self.removeFromWatchLater = removeFromWatchLater
    }
}

extension EnvironmentValues {
    /// 卡片菜单的账户写入口；App 在窗口外壳上注入一次，见 `VideoCardAccountWriting`。
    @Entry public var videoCardAccountWriting: VideoCardAccountWriting? = nil
}
