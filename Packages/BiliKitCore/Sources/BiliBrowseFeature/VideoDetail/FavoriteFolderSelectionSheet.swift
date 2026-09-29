import BiliModels
import SwiftUI

public struct FavoriteFolderSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folders: [FavFolder]
    let onSave: ([Int64], [Int64]) -> Void

    @State private var selectedIDs: Set<Int64>
    private let initialSelectedIDs: Set<Int64>

    public init(
        folders: [FavFolder],
        onSave: @escaping ([Int64], [Int64]) -> Void
    ) {
        self.folders = folders
        self.onSave = onSave
        let initial = Set(folders.filter { $0.isFavored == true }.map(\.mediaID))
        _selectedIDs = State(initialValue: initial)
        self.initialSelectedIDs = initial
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(BrowseFeatureStrings.localized("选择收藏夹"))
                .font(.headline)

            List(folders) { folder in
                HStack {
                    Text(folder.title)
                    Spacer()
                    Toggle("", isOn: binding(for: folder.mediaID))
                        .labelsHidden()
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 280, minHeight: 200)

            HStack {
                Button(BrowseFeatureStrings.localized("取消")) {
                    dismiss()
                }
                Spacer()
                Button(BrowseFeatureStrings.localized("确定")) {
                    let added = Array(selectedIDs.subtracting(initialSelectedIDs))
                    let deleted = Array(initialSelectedIDs.subtracting(selectedIDs))
                    onSave(added, deleted)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func binding(for mediaID: Int64) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(mediaID) },
            set: { isSelected in
                if isSelected {
                    selectedIDs.insert(mediaID)
                } else {
                    selectedIDs.remove(mediaID)
                }
            }
        )
    }
}
