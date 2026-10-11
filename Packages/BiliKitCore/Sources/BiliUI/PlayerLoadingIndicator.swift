import SwiftUI

/// 黑色视频框中央的加载转圈；播放页加载骨架与播放器准备浮层共用。
public struct PlayerLoadingIndicator: View {
    public init() {}

    public var body: some View {
        // macOS 的不确定进度转圈忽略 tint；在黑底上用深色外观才会画成浅色、看得见。
        ProgressView()
            .controlSize(.large)
            .environment(\.colorScheme, .dark)
    }
}
