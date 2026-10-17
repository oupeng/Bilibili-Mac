//
//  BiliKitMacApp.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import SwiftUI

@main
struct BiliKitMacApp: App {
    /// 进程级组装只构造一次；每个窗口由 `AppRootView` 从它组装自己的对象图。
    @State private var process = ProcessComposition.live()

    var body: some Scene {
        WindowGroup {
            AppRootView(process: process)
        }
        .defaultSize(width: 1_320, height: 820)
        .commands {
            AppUpdateCommands(updater: process.updater)
        }

        Settings {
            PlaybackSourceSettingsView(model: process.settings)
        }
    }
}
