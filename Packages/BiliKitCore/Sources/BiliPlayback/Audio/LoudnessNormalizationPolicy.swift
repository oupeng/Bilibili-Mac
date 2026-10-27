import BiliModels
import Foundation

/// 把一条完整语义音轨的静态响度元数据转换为线性音量增益。
///
/// 只压低、不放大：比目标响的音轨压到目标响度，比目标安静的保持原样。增益不超过 unity，输出
/// 不会高于原始峰值，因此不需要峰值余量或限幅器。
public struct LoudnessNormalizationPolicy: Sendable {
    /// 目标响度。
    ///
    /// B 站热门视频的 integrated loudness 中位数约 −12.6 LUFS；−18 让约 86% 的视频被拉到同一响度，
    /// 同时多数视频只压低约 5 dB。
    public static let targetIntegratedLUFS = -18.0
    /// 增益下限，最多压低 12 dB。
    ///
    /// 放宽会让极响的视频被压得更低，收紧则这类视频播放时仍比目标响。
    public static let maximumAttenuationDB = -12.0

    /// macOS 27 起 HLS item 的全部音轨混音才能经 `AVAudioMixInputParametersTrackID.mixID` 设音量，
    /// 更早的系统不提供这项功能。
    public static var isSupported: Bool {
        if #available(macOS 27.0, *) { true } else { false }
    }

    public init() {}

    /// 至少一条音轨需要压低时才给 item 挂 audio mix 并跟随音轨选择；全都不需要压低时 item 保持原样。
    func needsAttenuation(_ tracks: [PlaybackAudioTrack]) -> Bool {
        tracks.contains { linearGain(for: $0.loudnessMetadata) < 1 }
    }

    /// 元数据在 API 解码边界已完整校验；这里只防住用到的那个值。
    public func linearGain(for metadata: PlaybackLoudnessMetadata?) -> Float {
        guard let measured = metadata?.measuredIntegratedLUFS, measured.isFinite else {
            return 1
        }
        let gainDB = max(
            min(Self.targetIntegratedLUFS - measured, 0),
            Self.maximumAttenuationDB
        )
        return Float(pow(10, gainDB / 20))
    }
}
