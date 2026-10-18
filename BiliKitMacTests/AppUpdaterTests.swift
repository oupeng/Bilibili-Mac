import Foundation
import Testing

@testable import BiliKit

/// 更新器只在 Info.plist 的更新配置完整且符合 SECURITY-MODEL §7 时启动，任一安全项缺失或放宽都不启动。
@MainActor
struct AppUpdaterTests {
    private var configuredInfo: [String: Any] {
        [
            "BiliKitUpdaterEnabled": true,
            "SUFeedURL": "https://updates.example.org/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUEnableInstallerLauncherService": true,
            "SUEnableDownloaderService": false,
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUEnableSystemProfiling": false,
            "SUSignedFeedFailureExpirationInterval": 0
        ]
    }

    @Test
    func incompleteConfigurationLeavesUpdaterUnavailable() {
        let updater = AppUpdater(info: [:])
        #expect(!updater.isConfigured)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.failedToStart)
        updater.checkForUpdates()
        var info = configuredInfo
        info["BiliKitUpdaterEnabled"] = false
        #expect(!AppUpdater.hasValidConfiguration(info))
        info = configuredInfo
        info["SUPublicEDKey"] = ""
        #expect(!AppUpdater.hasValidConfiguration(info))
        info["SUPublicEDKey"] = Data(repeating: 1, count: 31).base64EncodedString()
        #expect(!AppUpdater.hasValidConfiguration(info))
    }

    @Test(
        arguments: [
            "http://updates.example.org/appcast.xml",
            "https://user@updates.example.org/appcast.xml",
            "https://updates.example.org/appcast.xml?key=placeholder",
            "https://updates.example.org/appcast.xml#fragment",
            "https://updates.example.org:8080/appcast.xml",
            "https://updates.example.org/"
        ]
    )
    func feedMustBeCredentialFreeHTTPS(feed: String) {
        var info = configuredInfo
        info["SUFeedURL"] = feed
        #expect(!AppUpdater.hasValidConfiguration(info))
    }

    @Test(
        arguments: [
            "SUEnableInstallerLauncherService", "SUVerifyUpdateBeforeExtraction",
            "SURequireSignedFeed"
        ]
    )
    func signingSafeguardMustStayEnabled(key: String) {
        var info = configuredInfo
        info[key] = false
        #expect(!AppUpdater.hasValidConfiguration(info))
    }

    @Test
    func signedFeedFailuresAndDownloaderServiceStayDisabled() {
        #expect(AppUpdater.hasValidConfiguration(configuredInfo))
        var info = configuredInfo
        info["SUSignedFeedFailureExpirationInterval"] = 1
        #expect(!AppUpdater.hasValidConfiguration(info))
        info = configuredInfo
        info["SUEnableDownloaderService"] = true
        #expect(!AppUpdater.hasValidConfiguration(info))
    }

    @Test
    func bundledInfoPlistPassesTheSparkleSafetyChecks() {
        // 只核对 Sparkle 安全键：是否启用更新器按构建配置决定（Debug 可以关闭），这里视为启用。
        var info = Bundle.main.infoDictionary ?? [:]
        info["BiliKitUpdaterEnabled"] = true
        #expect(AppUpdater.hasValidConfiguration(info))
    }

    @Test
    func systemProfilingMustBeExplicitlyDisabled() {
        var info = configuredInfo
        info["SUEnableSystemProfiling"] = true
        #expect(!AppUpdater.hasValidConfiguration(info))
        info["SUEnableSystemProfiling"] = nil
        #expect(!AppUpdater.hasValidConfiguration(info))
    }
}
