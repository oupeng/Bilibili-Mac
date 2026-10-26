import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

/// 「收藏到…」面板（App 以 sheet 呈现）：自己的收藏夹逐个一行，顺序、名称与私密锁同侧栏，另显示条数；勾选表示视频在
/// 这个夹里，确认后一次提交勾选与初始归属的差异。
///
/// 不拥有读取与写入：归属与勾选在 `FavoritePickerModel`，取消与确认交回调用方（App 的写入协调者关闭面板、发出写入）。
/// 没有改动时确认禁用；第一版不提供新建收藏夹。Esc 取消，Return 确认。
public struct FavoritePickerView: View {
    @Environment(\.locale) private var locale
    private let model: FavoritePickerModel
    private let onCancel: () -> Void
    private let onConfirm: () -> Void

    public init(
        model: FavoritePickerModel,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LibraryFeatureStrings.localized("收藏到", locale: locale))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], FavoritePickerGeometry.padding)
                .padding(.bottom, FavoritePickerGeometry.headerSpacing)
            content
                .frame(
                    width: FavoritePickerGeometry.width,
                    height: FavoritePickerGeometry.listHeight
                )
            Divider()
            HStack {
                Spacer()
                Button(LibraryFeatureStrings.localized("取消", locale: locale), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(LibraryFeatureStrings.localized("完成", locale: locale), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.change == nil)
            }
            .padding(FavoritePickerGeometry.padding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView(LibraryFeatureStrings.localized("正在加载收藏夹…", locale: locale))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            LibraryContentFailure(isAwaitingRevalidation: false, locale: locale)
                .view(
                    error,
                    fallbackTitle: LibraryFeatureStrings.localized("无法加载收藏夹", locale: locale),
                    retry: model.load
                )
        case .loaded(let memberships):
            List(memberships) { membership in
                Toggle(isOn: selection(membership.id)) {
                    HStack {
                        FavoriteFolderTitle(folder: membership.folder)
                        Spacer(minLength: FavoritePickerGeometry.countSpacing)
                        Text(
                            membership.folder.mediaCount,
                            format: .number.locale(InterfaceLocale.current)
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityValue(
                    membership.folder.isPrivate
                        ? LibraryFeatureStrings.localized("私密", locale: locale) : ""
                )
            }
        }
    }

    private func selection(_ folderID: Int64) -> Binding<Bool> {
        Binding(
            get: { model.selectedFolderIDs.contains(folderID) },
            set: { model.setSelected($0, folderID: folderID) }
        )
    }
}

/// 「收藏到…」面板的几何。
private enum FavoritePickerGeometry {
    static let width: CGFloat = 360
    /// 列表区固定高度：约十行，夹再多就在列表内滚动，面板尺寸不随读取状态跳动。
    static let listHeight: CGFloat = 320
    static let padding: CGFloat = 16
    static let headerSpacing: CGFloat = 8
    static let countSpacing: CGFloat = 12
}
