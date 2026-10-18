import SwiftUI

/// 应用菜单里“检查更新”一组命令，按 `AppUpdater` 是否已配置、是否启动失败与当前能否检查来渲染。
///
/// 只读取并转交 updater 的开关，不拥有 updater（归进程级 `ProcessComposition`）；
/// “自动下载并安装更新”只在开启自动检查时可改。
struct AppUpdateCommands: Commands {
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if !updater.isConfigured {
                Button("检查更新（尚未配置）") {}
                    .disabled(true)
            } else if updater.failedToStart {
                Button("检查更新（暂不可用）") {}
                    .disabled(true)
            } else {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Toggle(
                    "自动检查更新",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                Toggle(
                    "自动下载并安装更新",
                    isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updater.automaticallyChecksForUpdates)
            }
        }
    }
}
