@preconcurrency import AVFoundation
import BiliModels
import Foundation

/// 响度均一化（macOS 27 起）的 item 级 owner：给 item 挂 audio mix，并随系统音轨选择换新 mix。
///
/// 拥有当前 item 的弱引用、音轨元数据、当前 gain、选择 observer 与在途更新 Task；不拥有 item 本身与
/// player（交给 `AVPlayerEngine`）。gain 只经 audio mix 施加，不写 `AVPlayer.volume` 或偏好
/// （见 SECURITY-MODEL §6）。`clear` 让在途的音轨选择更新全部失效；元数据缺失、音轨无法唯一映射或查询
/// 失败时 gain 为 unity。
@MainActor
final class LoudnessNormalizationController {
    private weak var item: AVPlayerItem?
    private var audioTracks: [PlaybackAudioTrack] = []
    /// 当前 mix 的音量（过渡的终点）；下一次 gain 变化从它开始过渡，相同则不换 mix。
    private var currentGain: Float = 1
    private var selectionObserver: (any NSObjectProtocol)?
    private var selectionTask: Task<Void, Never>?
    /// 每次 `activate` 与每次音轨选择变化时换新，`clear` 时置 nil。
    ///
    /// `updateGain` 在每个 await 之后与之比对（同时核对 item 仍是当前的），不一致即放弃换 mix。
    private var selectionOperationID: UUID?

    deinit {
        selectionTask?.cancel()
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }

    /// 在 item 交给 AVPlayer 前按默认音轨（原声）挂上 audio mix；系统版本、开关不满足，或没有任何音轨需要
    /// 压低时保持原样。
    func install(
        on item: AVPlayerItem,
        audioTracks: [SelectedPlaybackAudioTrack],
        enabled: Bool
    ) {
        let policy = LoudnessNormalizationPolicy()
        guard #available(macOS 27.0, *),
            enabled,
            policy.needsAttenuation(audioTracks.map(\.track)),
            let defaultTrack = audioTracks.first(where: { $0.track.isDefault })
        else { return }
        let gain = policy.linearGain(for: defaultTrack.track.loudnessMetadata)
        self.item = item
        self.audioTracks = audioTracks.map(\.track)
        currentGain = gain
        item.audioMix = LoudnessAudioMix.make(volume: gain)
    }

    /// item 就绪后开始跟随音轨选择，并按当前选择设定一次 gain。
    func activate() async {
        guard let item else { return }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.item === item else { return }
                self.selectionTask?.cancel()
                let operationID = UUID()
                self.selectionOperationID = operationID
                self.selectionTask = Task { @MainActor [weak self] in
                    await self?.updateGain(operationID: operationID)
                }
            }
        }
        let operationID = UUID()
        selectionOperationID = operationID
        await updateGain(operationID: operationID)
    }

    /// 由 `AVPlayerEngine` 在换掉或移除 item 之前调用：取消在途更新、注销选择 observer，并放下 item。
    func clear() {
        selectionTask?.cancel()
        selectionTask = nil
        selectionOperationID = nil
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        selectionObserver = nil
        audioTracks = []
        currentGain = 1
        item = nil
    }

    private func updateGain(operationID: UUID) async {
        guard let item, isCurrent(operationID, item: item) else { return }

        let group: AVMediaSelectionGroup?
        do {
            group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        } catch {
            guard isCurrent(operationID, item: item) else { return }
            apply(1, to: item)
            return
        }
        guard isCurrent(operationID, item: item) else { return }

        let metadata: PlaybackLoudnessMetadata?
        if let group,
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
        {
            let matches = audioTracks.filter {
                LoudnessAudioTrackMatching.matches(
                    $0,
                    optionLanguageTag: option.extendedLanguageTag ?? option.locale?.identifier,
                    optionHasCharacteristic: option.hasMediaCharacteristic
                )
            }
            metadata = matches.count == 1 ? matches[0].loudnessMetadata : nil
        } else {
            metadata = nil
        }
        apply(LoudnessNormalizationPolicy().linearGain(for: metadata), to: item)
    }

    /// gain 变化时换上从当前 item 时间起过渡到新 gain 的 mix；播放中换 mix 实测几十毫秒内生效、不断流。
    private func apply(_ gain: Float, to item: AVPlayerItem) {
        guard #available(macOS 27.0, *), gain != currentGain else { return }
        item.audioMix = LoudnessAudioMix.make(
            volume: gain,
            rampingFrom: currentGain,
            at: item.currentTime()
        )
        currentGain = gain
    }

    private func isCurrent(_ operationID: UUID, item: AVPlayerItem) -> Bool {
        !Task.isCancelled
            && selectionOperationID == operationID
            && self.item === item
    }
}
