"""按目录白名单检查 Swift import，固定 ARCHITECTURE「模块与依赖方向」里的边界。

在仓库根运行，由 run-quality-gates.sh 的 static 阶段调用。每个 Swift 文件按所在目录匹配
`SCOPES` 里最长的前缀，只能 import 该范围白名单里的模块；`EXTRA_ALLOWED` 给单个文件放行
额外模块，`SUBTREE_DENIED` 在范围内的子目录再收紧，`@_exported` 只允许 `EXPORTED_ALLOWED` 登记的
文件。文件清单来自 git（含尚未暂存的新文件），不在任何范围里的 Swift 文件直接失败，新增 target、
App 目录或源码根时必须先在这里写明它能依赖什么；登记的前缀或文件不存在同样失败，避免改名后
规则静默失效。注释与字符串内容先被遮蔽，不会被当成 import。

同一构建产物目录里的 module 彼此可见：没有在 Package.swift 声明依赖的 Bili 模块照样能 import，
SwiftPM 的 `--explicit-target-dependency-import-check` 在当前构建后端下也不拦截。因此 Bili 模块
之间的方向、系统框架，以及 App target 内各目录（同属一个 module，编译器不区分）都由这里检查。
"""

import os
import re
import sys

import swift_source

# 任何范围都可以使用的标准库与并发基础设施。
BASE = {"Foundation", "Synchronization", "os", "Darwin", "Dispatch"}
# Feature 经 BiliVideoCollectionUI 渲染共享的 AppKit 卡片与网格，自己不直接 import AppKit 等界面框架。
FEATURE_SHARED = {
    "BiliModels", "BiliApplication", "BiliUI", "BiliVideoCollectionUI", "SwiftUI", "Observation", "CoreGraphics",
}
FEATURES = {"BiliAuthFeature", "BiliBrowseFeature", "BiliLibraryFeature", "BiliVideoDetailFeature"}
# 只有渲染共享卡片网格的 Feature 才依赖 BiliVideoCollectionUI。
COLLECTION_FEATURES = {"BiliBrowseFeature", "BiliLibraryFeature"}
ADAPTERS = {"BiliAPI", "BiliAuth", "BiliNetworking", "BiliPlayback", "BiliDanmaku"}

SOURCES = "Packages/BiliKitCore/Sources"

# 范围 -> (允许的模块, 违反时的说明)；允许的模块为 None 表示不设白名单。
# 除 EXACT_SCOPES 外，允许的模块都再加上 BASE。
SCOPES = {
    f"{SOURCES}/BiliModels": (
        set(),
        "BiliModels 只依赖标准库",
    ),
    f"{SOURCES}/BiliApplication": (
        {"BiliModels"},
        "BiliApplication 只能依赖 BiliModels 与标准库",
    ),
    f"{SOURCES}/BiliNetworking": (
        set(),
        "BiliNetworking 只提供无业务语义、无秘密存储的传输边界",
    ),
    f"{SOURCES}/BiliAPI": (
        {"BiliModels", "BiliApplication", "BiliNetworking", "CryptoKit", "SwiftProtobuf"},
        "BiliAPI 只依赖 Application/Models/Networking；SwiftProtobuf 只允许出现在这里",
    ),
    f"{SOURCES}/BiliAuth": (
        {"BiliModels", "BiliApplication", "BiliNetworking", "Security", "CoreGraphics", "CoreImage"},
        "BiliAuth 不能依赖 API、Playback 或界面框架",
    ),
    f"{SOURCES}/BiliPlayback": (
        {
            "BiliModels", "BiliApplication", "BiliNetworking",
            "AVFoundation", "AudioToolbox", "MediaToolbox", "Network",
        },
        "BiliPlayback 不能依赖 API、Auth 或界面框架",
    ),
    f"{SOURCES}/BiliDanmaku": (
        {"BiliModels", "BiliApplication", "AppKit", "QuartzCore", "CoreText", "CoreGraphics", "Accelerate"},
        "BiliDanmaku 只能依赖 Application/Models 与必要的系统渲染框架",
    ),
    f"{SOURCES}/BiliUI": (
        {"Foundation", "SwiftUI", "BiliApplication"},
        "BiliUI 只能依赖 Foundation、SwiftUI 与 BiliApplication，不依赖 AppKit 或 Feature",
    ),
    f"{SOURCES}/BiliVideoCollectionUI": (
        {"BiliUI", "AppKit", "QuartzCore", "CoreText", "CoreGraphics", "SwiftUI"},
        "BiliVideoCollectionUI 是共享的 AppKit 卡片与网格，只依赖 BiliUI 与界面框架；图片经 port 注入，不依赖网络或 adapter",
    ),
    **{
        f"{SOURCES}/{feature}": (
            FEATURE_SHARED if feature in COLLECTION_FEATURES else FEATURE_SHARED - {"BiliVideoCollectionUI"},
            "Feature 不能依赖 adapter、其他 Feature、AppKit 或播放与网络框架；共享的 AppKit 卡片与网格只经 "
            "BiliVideoCollectionUI，且只有 COLLECTION_FEATURES 登记的 Feature 依赖它",
        )
        for feature in sorted(FEATURES)
    },
    "BiliKitMac/App": (
        FEATURES | {"SwiftUI", "Observation", "Combine"},
        "App 壳只组织 Feature 视图，不直接依赖 adapter 或平台框架；Application 只在 EXTRA_ALLOWED 登记的搜索条件或账户投影的使用点",
    ),
    "BiliKitMac/Composition": (
        FEATURES | ADAPTERS | {
            "BiliModels", "BiliApplication", "SwiftUI", "Observation", "AppKit", "AVFoundation", "CoreGraphics",
        },
        "Composition 是唯一组装具体 adapter 的目录",
    ),
    "BiliKitMac/Platform": (
        FEATURES | {
            "BiliModels", "BiliApplication", "BiliUI", "BiliVideoCollectionUI", "SwiftUI", "Observation",
            "Combine", "AppKit", "CoreFoundation", "CoreGraphics", "CoreText", "ImageIO", "QuartzCore",
        },
        "Platform 不能依赖 BiliAPI/BiliAuth；播放、弹幕、网络、系统媒体与更新框架只允许在 EXTRA_ALLOWED 登记的宿主文件里",
    ),
    "BiliKitMac/Settings": (
        {"BiliApplication", "BiliAPI", "BiliPlayback", "SwiftUI", "Observation"},
        "Settings 只依赖设置所需的 Application、API 与 Playback 类型",
    ),
    "BiliKitMac/Localization": (
        set(),
        "Localization 只依赖标准库",
    ),
    # 测试与包清单可以 import 被测 target 与任意系统框架，只受 SUBTREE_DENIED 约束。
    "Packages/BiliKitCore/Tests": (None, ""),
    "Packages/BiliKitCore/Package.swift": (None, ""),
    "BiliKitMacTests": (None, ""),
}

# 单个文件额外允许的模块：每一项都是有明确理由的宿主或适配点。
EXTRA_ALLOWED = {
    # App 壳里搜索条件或账户投影（会话 scope、账户呈现状态）的使用点：搜索工具栏与搜索路由
    # （AppRootView、AppShellView、AppSourceRootViews、SearchToolbarControls），侧栏账号行
    # （AppSidebarViews）与窗口 owner（AppWindowOwner；AppRootView、AppShellView 也读取账户 scope）。
    # MemberImportVisibility 下成员只对直接 import 定义模块的文件可见，经 Feature 转出类型名不够用，
    # 在 Feature 镜像一份又违反“同一逻辑只写一处”。
    # AppShellView 持有各来源网格的滚动位置与回顶请求，并与图片管线一起构造 BiliVideoCollectionUI 的
    # `NativeVideoGridHostContext`，AppSourceRootViews 把它转交给 Feature；网格本身在 Feature 里，
    # App 壳其余文件不接触 AppKit 集合视图。
    "BiliKitMac/App/AppRootView.swift": {"BiliApplication"},
    "BiliKitMac/App/AppShellView.swift": {"BiliApplication", "BiliVideoCollectionUI"},
    "BiliKitMac/App/AppSidebarViews.swift": {"BiliApplication"},
    "BiliKitMac/App/AppSourceRootViews.swift": {"BiliApplication", "BiliVideoCollectionUI"},
    "BiliKitMac/App/AppWindowOwner.swift": {"BiliApplication"},
    "BiliKitMac/App/SearchToolbarControls.swift": {"BiliApplication"},
    # 观看进度连接与网格、侧栏共用同一份通知观察集合（NativeVideoNotificationObservers）。
    "BiliKitMac/Composition/WatchProgressWindowConnection.swift": {"BiliVideoCollectionUI"},
    "BiliKitMac/Platform/AppUpdater.swift": {"Sparkle"},
    "BiliKitMac/Platform/DanmakuOverlayHostView.swift": {"BiliDanmaku"},
    "BiliKitMac/Platform/NativeVideoImagePipeline.swift": {"BiliNetworking"},
    "BiliKitMac/Platform/PlaybackPreferencesController.swift": {"AVFoundation"},
    "BiliKitMac/Platform/PlayerHostView.swift": {"AVKit", "BiliDanmaku", "BiliPlayback"},
    "BiliKitMac/Platform/PlayerKeyboardShortcutController.swift": {"BiliPlayback"},
    "BiliKitMac/Platform/PlayerOverlay.swift": {"AVFoundation", "BiliPlayback"},
    "BiliKitMac/Platform/SystemNowPlayingController.swift": {"MediaPlayer"},
}

# 范围内子目录再禁止的模块：纯逻辑部分不得碰播放或渲染框架。
SUBTREE_DENIED = {
    "Packages/BiliKitCore/Tests": (
        {"Sparkle"},
        "Sparkle 只属于 App target，Package 测试不链接它",
    ),
    f"{SOURCES}/BiliPlayback/Bridge": (
        {"AVFoundation", "AudioToolbox", "MediaToolbox"},
        "DASH→HLS bridge 与 loopback 是不可信输入与本地服务器边界，不依赖 AVFoundation",
    ),
    f"{SOURCES}/BiliPlayback/MediaIndex": (
        {"AVFoundation", "AudioToolbox", "MediaToolbox"},
        "媒体索引解析是纯逻辑，不依赖 AVFoundation",
    ),
    f"{SOURCES}/BiliPlayback/CDN": (
        {"AVFoundation", "AudioToolbox", "MediaToolbox"},
        "线路偏好与测速是纯逻辑，不依赖 AVFoundation",
    ),
    f"{SOURCES}/BiliDanmaku/Session": (
        {"AppKit", "QuartzCore", "CoreText", "Accelerate"},
        "弹幕会话是纯逻辑，渲染框架只在 Rendering/",
    ),
    f"{SOURCES}/BiliDanmaku/Scheduling": (
        {"AppKit", "QuartzCore", "CoreText", "Accelerate"},
        "弹幕调度是纯逻辑，渲染框架只在 Rendering/",
    ),
}

# 白名单不叠加 BASE 的范围。
EXACT_SCOPES = {f"{SOURCES}/BiliUI"}

# 允许 `@_exported import` 的文件与模块：转出的模块会出现在所有 import 该 target 的文件里，
# 绕过它们自己的白名单，所以每一处都要登记。
EXPORTED_ALLOWED: dict[str, set[str]] = {}

# 任意属性（含带括号参数的 `@_spi(X)`）、访问级别、kind import（`import class M.T`）、
# clang 子模块（`import M.Sub`）与反引号模块名都归到第一段模块名。
IMPORT = re.compile(
    r"^\s*((?:@[A-Za-z_]\w*(?:\((?:[^()]|\([^()]*\))*\))?\s*)*)"
    r"(?:(?:public|package|internal|fileprivate|private)\s+)?"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func|actor)\s+)?"
    r"`?([A-Za-z_]\w*)"
)


def scope_for(path):
    matches = [prefix for prefix in SCOPES if path == prefix or path.startswith(prefix + "/")]
    return max(matches, key=len) if matches else None


def imports(path):
    """逐个 import 语句产出 (行号, 模块, 是否 @_exported)；同一行用分号分隔的语句分别计入。"""
    masked, _ = swift_source.mask(swift_source.read(path), keep_strings=False)
    for number, line in enumerate(masked.split("\n"), start=1):
        for statement in line.split(";"):
            match = IMPORT.match(statement)
            if match is not None:
                yield number, match.group(2), "@_exported" in match.group(1)


def registration_failures():
    for prefix in list(SCOPES) + list(SUBTREE_DENIED):
        if not os.path.exists(prefix):
            yield f"{prefix}: 登记的范围不存在，改名后同步更新或删除这一项"
    for path in list(EXTRA_ALLOWED) + list(EXPORTED_ALLOWED):
        if not os.path.isfile(path):
            yield f"{path}: 登记的文件不存在，删除这一项"


def failures():
    yield from registration_failures()
    for path in swift_source.swift_files():
        scope = scope_for(path)
        if scope is None:
            yield f"{path}: 所在目录没有登记依赖白名单（Scripts/check-architecture.py 的 SCOPES）"
            continue
        allowed, reason = SCOPES[scope]
        if allowed is not None:
            base = set() if scope in EXACT_SCOPES else BASE
            allowed = base | allowed | EXTRA_ALLOWED.get(path, set())
        denied = [
            (modules, why)
            for prefix, (modules, why) in SUBTREE_DENIED.items()
            if path.startswith(prefix + "/")
        ]
        for number, module, exported in imports(path):
            if allowed is not None and module not in allowed:
                yield f"{path}:{number}: import {module} — {reason}"
            for modules, why in denied:
                if module in modules:
                    yield f"{path}:{number}: import {module} — {why}"
            if exported and module not in EXPORTED_ALLOWED.get(path, set()):
                yield f"{path}:{number}: @_exported import {module} 未在 EXPORTED_ALLOWED 登记"


def main():
    found = list(failures())
    for failure in found:
        print(f"架构边界失败：{failure}", file=sys.stderr)
    if found:
        return 1
    print("架构依赖边界检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
