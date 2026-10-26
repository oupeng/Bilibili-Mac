@preconcurrency import AVFoundation

/// 响度均一化施加 gain 的 audio mix：在 item 全部音轨的混音（`mixID`）上设音量。
///
/// 由 `LoudnessNormalizationController` 在安装时与 gain 变化时调用，每次构造一个新 mix 交给
/// `AVPlayerItem.audioMix`；本身不持有状态。gain 不超过 unity，音量就能表达，不需要逐帧处理音频。
enum LoudnessAudioMix {
    /// gain 变化时音量过渡的时长（item 时间）。
    ///
    /// 切换音轨使 gain 改变时，过渡避免音量突变；实测播放中换上带过渡的新 mix 约 130–155 ms 落到新音量、
    /// 不断流。调长变化更慢，调短更接近突变。
    static let rampDuration = CMTime(value: 150, timescale: 1000)

    /// `previousVolume` 是当前 mix 的音量；与 `volume` 不同且 `itemTime` 在开头之后时，从 `itemTime` 起
    /// 过渡到新音量，否则整段都是新音量。
    ///
    /// 过渡之前的部分也设为新音量：音量曲线定义在 item 时间上，往回 seek 到锚点之前仍是新 gain。代价是
    /// 往回 seek 后再次播过锚点时会重放一次这段过渡。
    @available(macOS 27.0, *)
    static func make(
        volume: Float,
        rampingFrom previousVolume: Float? = nil,
        at itemTime: CMTime = .zero
    ) -> AVAudioMix {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = AVAudioMixInputParametersTrackID.mixID.rawValue
        parameters.setVolume(volume, at: .zero)
        if let previousVolume, previousVolume != volume,
            itemTime.isNumeric, itemTime > .zero
        {
            parameters.setVolumeRamp(
                fromStartVolume: previousVolume,
                toEndVolume: volume,
                timeRange: CMTimeRange(start: itemTime, duration: rampDuration)
            )
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
