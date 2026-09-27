import SwiftUI

struct VideoDetailSkeleton: View {
    let loadingLabel: String

    var body: some View {
        PlaybackDetailLayout {
            Rectangle()
                .fill(.black)
                .overlay {
                    // macOS 的不确定进度转圈忽略 tint；在黑底上用深色外观才会画成浅色、看得见。
                    ProgressView()
                        .controlSize(.large)
                        .environment(\.colorScheme, .dark)
                }
        } related: {
            RelatedVideoShelf<EmptyView>(
                state: .loading,
                contentIdentity: "loading",
                onSelect: { _ in },
                onRetry: {},
                makeLoadedContent: { _, _, _ in EmptyView() }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }
}
