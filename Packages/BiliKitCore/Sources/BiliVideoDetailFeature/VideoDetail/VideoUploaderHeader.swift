import BiliApplication
import BiliModels
import Foundation

/// UP 主名片的读取状态；失败按空名片处理，只隐藏增强信息。
public enum VideoUploaderProfileState: Equatable, Sendable {
    case loading
    case loaded(UploaderProfile)
}

/// UP 主签名行的展示形态：加载中占位、没有签名时隐藏，或单行文字。
public enum VideoUploaderSignatureContent: Equatable, Sendable {
    case loading
    case hidden
    case text(String)
}

/// 把 UP 主字段规范化为平台 renderer 可直接消费的稳定展示值。
public struct VideoUploaderHeaderContent: Equatable, Sendable {
    public let name: String
    public let avatarURL: URL?
    public let signature: VideoUploaderSignatureContent
    /// 名片加载完成前按非大会员显示。
    public let isVIP: Bool
    /// 名片仍在加载；平台据此在结果到达时把变化做成过渡。
    public let isProfileLoading: Bool

    public init(
        owner: VideoOwner,
        profileState: VideoUploaderProfileState? = nil
    ) {
        let normalizedName = UploaderProfileUseCase.singleLine(owner.name)
        name = normalizedName ?? VideoDetailFeatureStrings.localized("未知 UP 主")
        avatarURL = owner.avatarURL
        switch profileState ?? .loaded(UploaderProfile()) {
        case .loading:
            signature = .loading
            isVIP = false
            isProfileLoading = true
        case .loaded(let profile):
            isProfileLoading = false
            signature =
                UploaderProfileUseCase.singleLine(profile.signature).map {
                    .text($0)
                } ?? .hidden
            isVIP = profile.isVIP
        }
    }
}
