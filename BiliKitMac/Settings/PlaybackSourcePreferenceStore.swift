import BiliPlayback
import Foundation

/// 设置里可选的新播放优先线路；`rawValue` 就是持久化的版本化 route identifier
/// （见 SECURITY-MODEL §6）。
///
/// 服务端默认、服务端原始 Akamai 与 bilivideo 之外的 case 与 `BilivideoRoute` 同名，是实验镜像。
/// 改名或删除 case 会让已存的值读成未知值，回退服务端默认。
enum PlaybackSourceSelection: String, Sendable, Equatable, CaseIterable, Identifiable {
    case serverDefault, serverAkamai, serverBilivideo
    case tencentOverseas, alibabaOverseas
    case alibabaMainland, alibabaMainlandB, alibabaMainlandO1
    case tencentMainland, tencentMainlandB, tencentMainlandO1
    case huaweiMainland, huaweiMainlandB, huaweiMainlandO1
    case huawei08C, huawei08H, huawei08CT, huaweiAll, tencentAll
    case baiduMainland, bda2Mainland

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serverDefault: AppStrings.localized("B 站服务端默认")
        case .serverAkamai: PlaybackRouteTarget.serverAkamai.appDisplayName
        case .serverBilivideo: AppStrings.localized("bilivideo（服务端原始）")
        default: route?.appDisplayName ?? rawValue
        }
    }

    var isExperimental: Bool { route != nil }

    var preference: PlaybackSourcePreference {
        switch self {
        case .serverDefault: .serverDefault
        case .serverAkamai: .category(.akamai)
        case .serverBilivideo: .category(.bilivideo)
        default:
            route.map(PlaybackSourcePreference.experimentalBilivideoRoute)
                ?? .serverDefault
        }
    }

    private var route: BilivideoRoute? {
        BilivideoRoute(rawValue: rawValue)
    }
}

extension PlaybackRouteTarget {
    var appDisplayName: String {
        switch self {
        case .serverAkamai: AppStrings.localized("Akamai（服务端原始）")
        case .bilivideo(let route): route.appDisplayName
        }
    }
}

extension BilivideoRoute {
    fileprivate var appDisplayName: String {
        switch self {
        case .tencentOverseas:
            "\(AppStrings.localized("腾讯海外")) COSOV"
        case .alibabaOverseas:
            "\(AppStrings.localized("阿里海外")) ALIOV"
        case .alibabaMainland:
            "\(AppStrings.localized("阿里")) ALI"
        case .alibabaMainlandB:
            "\(AppStrings.localized("阿里")) ALIB"
        case .alibabaMainlandO1:
            "\(AppStrings.localized("阿里")) ALIO1"
        case .tencentMainland:
            "\(AppStrings.localized("腾讯")) COS"
        case .tencentMainlandB:
            "\(AppStrings.localized("腾讯")) COSB"
        case .tencentMainlandO1:
            "\(AppStrings.localized("腾讯")) COSO1"
        case .huaweiMainland:
            "\(AppStrings.localized("华为")) HW"
        case .huaweiMainlandB:
            "\(AppStrings.localized("华为")) HWB"
        case .huaweiMainlandO1:
            "\(AppStrings.localized("华为")) HWO1"
        case .huawei08C:
            "\(AppStrings.localized("华为")) 08C"
        case .huawei08H:
            "\(AppStrings.localized("华为")) 08H"
        case .huawei08CT:
            "\(AppStrings.localized("华为")) 08CT"
        case .huaweiAll:
            AppStrings.localized("华为 TF 全域")
        case .tencentAll:
            AppStrings.localized("腾讯 TX 全域")
        case .baiduMainland:
            "\(AppStrings.localized("百度")) BOS"
        case .bda2Mainland:
            AppStrings.localized("UPCDN BDA2（大陆）")
        }
    }
}

/// 一次读写的播放偏好整体：线路选择与响度均一化开关；`defaults` 是没有存过或读到损坏值时的回退。
struct PlaybackSourcePreferenceRecord: Sendable, Equatable {
    static let defaults = Self(selection: .serverDefault, loudnessNormalizationEnabled: false)
    let selection: PlaybackSourceSelection
    let loudnessNormalizationEnabled: Bool

    init(
        selection: PlaybackSourceSelection,
        loudnessNormalizationEnabled: Bool = false
    ) {
        self.selection = selection
        self.loudnessNormalizationEnabled = loudnessNormalizationEnabled
    }
}

/// 播放偏好的持久化 port：`load` 不抛错，读不到或值损坏时返回
/// `PlaybackSourcePreferenceRecord.defaults`，`save` 整体覆盖。
///
/// `AppSettingsModel` 构造时读取一次，每次改选写入一次。
protocol PlaybackSourcePreferenceStoring: AnyObject, Sendable {
    func load() -> PlaybackSourcePreferenceRecord
    func save(_ record: PlaybackSourcePreferenceRecord)
}

/// 播放偏好的 UserDefaults 实现：schema 版本、线路选择与响度均一化开关三个键
/// （见 SECURITY-MODEL §6）。
///
/// schema 不符或线路选择是未知值时整体回退默认（响度开关也回到关闭）；
/// 响度开关类型不对时按关闭处理。每次读取都删除另一个含义不同的响度偏好键
/// （`legacyLoudnessNormalizationEnabled`），不读取它的值。
///
/// `@unchecked Sendable`：只持有不可变的 `let defaults`，`UserDefaults` 本身可以跨线程读写；
/// 三个键不是原子写入，生产调用方只有 MainActor 上的 `AppSettingsModel`。
final class UserDefaultsPlaybackSourcePreferenceStore:
    PlaybackSourcePreferenceStoring, @unchecked Sendable
{
    private enum Key {
        static let schema = "playbackSourcePreference.schema"
        static let selection = "playbackSourcePreference.selection"
        /// “只压低到统一响度”的开关。
        static let loudnessNormalizationEnabled = "playback.loudnessAttenuation.enabled"
        /// 旧版实验开关（可放大、仅 macOS 26）；含义不同，不沿用，读取时清掉残留。
        static let legacyLoudnessNormalizationEnabled = "playback.loudnessNormalization.enabled"
    }
    private static let schemaVersion = 1
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PlaybackSourcePreferenceRecord {
        defaults.removeObject(forKey: Key.legacyLoudnessNormalizationEnabled)
        guard defaults.integer(forKey: Key.schema) == Self.schemaVersion,
            let raw = defaults.string(forKey: Key.selection),
            let selection = PlaybackSourceSelection(rawValue: raw)
        else { return .defaults }
        return PlaybackSourcePreferenceRecord(
            selection: selection,
            loudnessNormalizationEnabled: defaults.strictBool(
                forKey: Key.loudnessNormalizationEnabled
            ) ?? false
        )
    }

    func save(_ record: PlaybackSourcePreferenceRecord) {
        defaults.set(Self.schemaVersion, forKey: Key.schema)
        defaults.set(record.selection.rawValue, forKey: Key.selection)
        defaults.set(
            record.loudnessNormalizationEnabled,
            forKey: Key.loudnessNormalizationEnabled
        )
    }
}
