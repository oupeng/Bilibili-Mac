import BiliUI
import SwiftUI

struct VideoDetailSkeleton: View {
    let loadingLabel: String

    var body: some View {
        PlaybackDetailLayout {
            Rectangle()
                .fill(.black)
                .overlay {
                    PlayerLoadingIndicator()
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
