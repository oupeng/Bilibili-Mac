@preconcurrency import AVFoundation
import BiliApplication
import CoreFoundation
import Foundation

/// `UserDefaults` 中 Bool 与数字都以 `NSNumber` 存储；设置只接受类型严格匹配的值，
/// 损坏、类型错写或由其他版本写入的值一律视为缺失并回退默认。
extension UserDefaults {
    func strictBool(forKey key: String) -> Bool? {
        guard let number = object(forKey: key) as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    /// 非 Bool 的数字；调用方自行校验有限性与范围。
    func strictNumber(forKey key: String) -> NSNumber? {
        guard let number = object(forKey: key) as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }

    /// 非 Bool 且没有小数部分的整数。
    func strictInteger(forKey key: String) -> Int? {
        guard let number = strictNumber(forKey: key) else { return nil }
        let value = number.intValue
        return number.doubleValue == Double(value) ? value : nil
    }
}

/// 播放器原生控件的设备级偏好：音量、静音与首选倍速（`AVPlayer.defaultRate`）。
///
/// `defaults` 是没有存储值或存储值无效时的回退；持久化范围见 SECURITY-MODEL §6。
struct PlaybackPreferences: Equatable, Sendable {
    static let defaults = PlaybackPreferences(
        volume: 1,
        isMuted: false,
        preferredRate: 1
    )

    let volume: Float
    let isMuted: Bool
    let preferredRate: Float
}

/// 播放偏好的持久化 port：`PlaybackPreferencesController` 初始化时读取一次，
/// 之后播放器每次变化写回一项。
///
/// `load` 不失败，无效值回退默认；写入在 KVO 回调所在的线程调用。
protocol PlaybackPreferencesStoring: AnyObject, Sendable {
    func load() -> PlaybackPreferences
    func saveVolume(_ volume: Float)
    func saveMuted(_ isMuted: Bool)
    func savePreferredRate(_ rate: Float)
}

/// 播放偏好的 `UserDefaults` 实现：读取只接受类型严格匹配且在范围内的值，写入丢弃越界值。
///
/// `@unchecked Sendable`：只有一个不可变的 `let defaults`，`UserDefaults` 官方保证线程安全，只是
/// SDK 尚未声明其为 `Sendable`。
final class UserDefaultsPlaybackPreferencesStore:
    PlaybackPreferencesStoring, @unchecked Sendable
{
    private enum Key {
        static let volume = "player.volume"
        static let isMuted = "player.isMuted"
        static let preferredRate = "player.preferredRate"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PlaybackPreferences {
        PlaybackPreferences(
            volume: validNumber(forKey: Key.volume, in: 0...1)
                ?? PlaybackPreferences.defaults.volume,
            isMuted: defaults.strictBool(forKey: Key.isMuted)
                ?? PlaybackPreferences.defaults.isMuted,
            preferredRate: validNumber(
                forKey: Key.preferredRate,
                in: Float(
                    PlaybackRate.supported.lowerBound
                )...Float(PlaybackRate.supported.upperBound)
            )
                ?? PlaybackPreferences.defaults.preferredRate
        )
    }

    func saveVolume(_ volume: Float) {
        guard volume.isFinite, (0...1).contains(volume) else { return }
        defaults.set(volume, forKey: Key.volume)
    }

    func saveMuted(_ isMuted: Bool) {
        defaults.set(isMuted, forKey: Key.isMuted)
    }

    func savePreferredRate(_ rate: Float) {
        guard PlaybackRate.isSupported(rate) else { return }
        defaults.set(rate, forKey: Key.preferredRate)
    }

    private func validNumber(
        forKey key: String,
        in range: ClosedRange<Float>
    ) -> Float? {
        guard let value = defaults.strictNumber(forKey: key)?.floatValue else {
            return nil
        }
        guard value.isFinite, range.contains(value) else { return nil }
        return value
    }
}

/// 弹幕显示的设备级偏好：速度档位、透明度、显示区域、密度与是否合并重复弹幕。
///
/// `defaults` 是没有存储值或存储值无效时的回退；持久化范围见 SECURITY-MODEL §6。
struct DanmakuPreferences: Equatable, Sendable {
    static let defaults = DanmakuPreferences(
        speedLevel: .default,
        opacity: .fullyOpaque,
        displayArea: .default,
        density: .default,
        mergesDuplicates: DanmakuDuplicateMerging.defaultIsEnabled
    )

    let speedLevel: DanmakuSpeedLevel
    let opacity: DanmakuOpacity
    let displayArea: DanmakuDisplayArea
    let density: DanmakuDensity
    let mergesDuplicates: Bool
}

/// 弹幕偏好的持久化 port：窗口组装弹幕控制模型时读取一次初值，用户每次调整写回一项。
protocol DanmakuPreferencesStoring: AnyObject, Sendable {
    func load() -> DanmakuPreferences
    func saveSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func saveOpacity(_ opacity: DanmakuOpacity)
    func saveDisplayArea(_ displayArea: DanmakuDisplayArea)
    func saveDensity(_ density: DanmakuDensity)
    func saveMergesDuplicates(_ merges: Bool)
}

/// 弹幕偏好的 `UserDefaults` 实现：只保存设备级弹幕显示意图，不保存视频 identity、正文或播放位置。
///
/// 读取只接受类型严格匹配的数字，再由各值类型的构造器校验取值，无效值回退默认。
/// `@unchecked Sendable`：只有一个不可变的 `let defaults`，`UserDefaults` 官方保证线程安全，只是
/// SDK 尚未声明其为 `Sendable`。
final class UserDefaultsDanmakuPreferencesStore:
    DanmakuPreferencesStoring, @unchecked Sendable
{
    private enum Key {
        static let speedLevel = "danmaku.speedLevel"
        static let opacity = "danmaku.opacity"
        static let displayArea = "danmaku.displayArea"
        static let density = "danmaku.density"
        static let mergesDuplicates = "danmaku.mergesDuplicates"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DanmakuPreferences {
        DanmakuPreferences(
            speedLevel: loadSpeedLevel(),
            opacity: loadOpacity(),
            displayArea: loadDisplayArea(),
            density: loadDensity(),
            mergesDuplicates: defaults.strictBool(forKey: Key.mergesDuplicates)
                ?? DanmakuPreferences.defaults.mergesDuplicates
        )
    }

    func saveSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        defaults.set(speedLevel.rawValue, forKey: Key.speedLevel)
    }

    func saveOpacity(_ opacity: DanmakuOpacity) {
        defaults.set(opacity.value, forKey: Key.opacity)
    }

    func saveDisplayArea(_ displayArea: DanmakuDisplayArea) {
        defaults.set(displayArea.rawValue, forKey: Key.displayArea)
    }

    func saveDensity(_ density: DanmakuDensity) {
        defaults.set(density.rawValue, forKey: Key.density)
    }

    func saveMergesDuplicates(_ merges: Bool) {
        defaults.set(merges, forKey: Key.mergesDuplicates)
    }

    private func loadSpeedLevel() -> DanmakuSpeedLevel {
        guard let rawValue = defaults.strictInteger(forKey: Key.speedLevel),
            let speedLevel = DanmakuSpeedLevel(rawValue: rawValue)
        else {
            return DanmakuPreferences.defaults.speedLevel
        }
        return speedLevel
    }

    private func loadOpacity() -> DanmakuOpacity {
        guard let number = defaults.strictNumber(forKey: Key.opacity),
            let opacity = DanmakuOpacity(number.doubleValue)
        else {
            return DanmakuPreferences.defaults.opacity
        }
        return opacity
    }

    private func loadDisplayArea() -> DanmakuDisplayArea {
        guard let rawValue = defaults.strictInteger(forKey: Key.displayArea),
            let displayArea = DanmakuDisplayArea(rawValue: rawValue)
        else {
            return DanmakuPreferences.defaults.displayArea
        }
        return displayArea
    }

    private func loadDensity() -> DanmakuDensity {
        guard let rawValue = defaults.strictInteger(forKey: Key.density),
            let density = DanmakuDensity(rawValue: rawValue)
        else {
            return DanmakuPreferences.defaults.density
        }
        return density
    }
}

/// 恢复并观察 AVPlayerView 原生控件的非内容偏好；不接触播放 identity、进度或字幕选择。
///
/// 每个窗口一个，由窗口 adapter（`WindowAdapters.live`）创建：初始化时把存储的音量、
/// 静音与首选倍速写入 player，再用三个 KVO 观察把之后的变化写回存储。观察由本类型持有，关窗时
/// adapter 调用 `invalidate()` 取消。
@MainActor
final class PlaybackPreferencesController {
    private let player: AVPlayer
    private let store: any PlaybackPreferencesStoring
    private var volumeObservation: NSKeyValueObservation?
    private var mutedObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?

    init(
        player: AVPlayer,
        store: any PlaybackPreferencesStoring = UserDefaultsPlaybackPreferencesStore()
    ) {
        self.player = player
        self.store = store

        let preferences = store.load()
        player.volume = preferences.volume
        player.isMuted = preferences.isMuted
        player.defaultRate = preferences.preferredRate

        volumeObservation = player.observe(\.volume, options: [.new]) {
            [store] _, change in
            guard let volume = change.newValue else { return }
            store.saveVolume(volume)
        }
        mutedObservation = player.observe(\.isMuted, options: [.new]) {
            [store] _, change in
            guard let isMuted = change.newValue else { return }
            store.saveMuted(isMuted)
        }
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) {
            [store] _, change in
            guard let preferredRate = change.newValue else { return }
            store.savePreferredRate(preferredRate)
        }
    }

    /// 停止观察，之后播放器的音量、静音与倍速变化不再写入存储；由窗口 adapter 在关窗时调用，可重复调用。
    func invalidate() {
        volumeObservation?.invalidate()
        mutedObservation?.invalidate()
        defaultRateObservation?.invalidate()
        volumeObservation = nil
        mutedObservation = nil
        defaultRateObservation = nil
    }

    /// 键盘音量步进：先取消静音，再按偏移调整并夹在 0...1，返回调整后的音量；新值随后经 KVO
    /// 写回存储。
    @discardableResult
    func adjustVolume(by offset: Float) -> Float {
        guard offset.isFinite else { return player.volume }
        player.isMuted = false
        player.volume = min(max(player.volume + offset, 0), 1)
        return player.volume
    }
}
