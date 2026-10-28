<p align="center">
  <img
    src="Design/AppIcon/v1/Marketing/BiliKit-AppIcon-Default-256.png"
    width="136"
    height="136"
    alt="BiliKit App Icon Default"
  >
  &nbsp;&nbsp;
  <img
    src="Design/AppIcon/v1/Marketing/BiliKit-AppIcon-Dark-256.png"
    width="136"
    height="136"
    alt="BiliKit App Icon Dark"
  >
</p>

<h1 align="center">BiliKit</h1>

<p align="center"><strong>在 Mac 上，好好看 B 站。</strong></p>

<p align="center">第三方开源 B 站客户端，用 Mac 原生技术写成</p>

<p align="center">
  <img alt="平台 macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-195CFF?style=flat">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-195CFF?style=flat">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-FF607A?style=flat">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/shiinayane/BiliKit-Mac?label=%E7%89%88%E6%9C%AC&color=FF607A&style=flat"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/许可证-MIT-4A5568?style=flat"></a>
</p>

<p align="center">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><strong>下载 BiliKit</strong></a>
</p>

<p align="center">
  <strong>简体中文</strong> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Home-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Home-Light.png" alt="BiliKit 首页：侧栏的资料库与收藏夹，右侧是推荐视频网格">
  </picture>
</p>

## 为什么用 BiliKit

|  | 网页版 / 官方 Mac 客户端 | BiliKit |
| --- | --- | --- |
| 技术栈 | 官方客户端基于 Electron，本质是网页 | SwiftUI 构建界面，视频网格、评论、弹幕这些对性能敏感的地方用 AppKit，播放交给 AVPlayer |
| 安装包 | 官方客户端近 200 MB | 不到 10 MB |
| 运行内存 | 官方客户端常常上 GB | 百兆级 |
| 推荐流 | 夹着推广、直播和各种弹窗 | 只有视频，推广卡片和非视频条目被过滤 |
| 看完一个视频 | 新标签页越开越多，回不到刚才的列表 | 同一个窗口里返回，列表停在原来的位置 |
| 播放器 | 网页播放器 | 系统播放器：画中画、全屏、媒体键、控制中心 |
| 不登录时 | 清晰度受限 | 可以选 720P 和 1080P |

<sub>官方客户端的技术栈与安装包大小取自其官方下载地址（`pc_electron_mac/bili_mac.dmg`，2026 年 9 月）。</sub>

## 能做什么

- **浏览**：首页推荐、热门、搜索，每个入口记得自己的滚动位置；搜索页有本机搜索历史和 B 站热搜，输入时有联想。
- **资料库**（登录后）：侧栏「资料库」里有稍后再看和观看历史，「收藏夹」逐个列出自己创建的收藏夹。观看历史标出在哪种设备上看的；稍后再看可以按添加时间排序、按进度／添加时间／时长筛选和搜索；收藏夹点开直接按页看夹内视频，可以排序和在当前收藏夹里搜索。番剧、课程、合集、音频和已失效的条目会标出原因、不能点开。
- **卡片菜单**：视频卡片的右键菜单可以拷贝链接、在浏览器中打开；登录后还能添加到稍后再看、收藏到收藏夹，对首页推荐说「不感兴趣」（可以撤销），在稍后再看页和收藏夹页右键或按 ⌘⌫ 移除。
- **播放**：自动画质、倍速、画中画、全屏，系统字幕与音轨菜单，Now Playing 和媒体键。控制条的动作菜单可以添加到稍后再看、拷贝带当前时间的链接或 BV 号、在浏览器中打开，并设置「播放结束后」：不循环、单集循环、自动连播（按分 P 和合集，不播相关推荐）或列表循环。
- **弹幕**：和画面走同一条时间轴，拖动、暂停、倍速都不会错位，拖动进度条后弹幕直接出现在应有的位置；速度、显示区域、密度和透明度可以调，大会员彩色弹幕照样显示。重复弹幕合并成一条并显示条数，高赞弹幕带赞图标；评分、投票与关联视频等互动弹幕显示为卡片，关联视频点一下就在应用内打开。
- **视频页**：分 P、简介、只读评论（楼中楼按页码跳页、查看对话，图片与动图）和相关推荐，都在播放器旁边；简介和评论里的视频链接、@ 和时间戳在应用内直接打开或跳转。登录后可以在工具栏点赞、投币、收藏和三连；点开 UP 主，可以在侧栏按投稿连续观看，正在播放的视频不中断。
- **登录**：用 B 站 App 扫码登录，观看进度会同步到你的 B 站观看历史。
- **更新**：安装包经 Apple 签名和公证，新版本在应用内提示。
- **界面语言**：简体中文、繁体中文、英文和日文，跟随系统语言。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Video-Detail-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Video-Detail-Light.png" alt="BiliKit 视频页：播放器上的弹幕与字幕，侧栏的简介与评论，下方的相关推荐">
  </picture>
</p>

## 快捷键

| 按键 | 作用 |
| --- | --- |
| 空格 | 播放 / 暂停 |
| ← / → | 后退 / 前进 5 秒 |
| 按住 ← / → | 临时 0.5 倍 / 2 倍速，松开恢复 |
| ↑ / ↓ | 音量 |
| D | 弹幕开关 |
| C | 字幕开关 |
| F | 进入 / 退出全屏 |
| Q | 点赞 / 取消点赞（登录后） |
| 按住 Q | 三连（登录后） |
| W | 投币（登录后） |
| E | 收藏到…（登录后） |

## 接下来

暂无已排期的下一项。

详细计划见[路线图](docs/ROADMAP.md)。

## 安装

1. 下载[最新版 DMG](https://github.com/shiinayane/BiliKit-Mac/releases/latest)。
2. 把 BiliKit 拖进“应用程序”，打开即可。

需要 Apple Silicon Mac（M 系列芯片）和 macOS 15 或更高版本。Intel Mac 请使用
[1.0.0](https://github.com/shiinayane/BiliKit-Mac/releases/tag/v1.0.0)，这是最后一个支持 Intel 的版本。
安装、卸载和更新的细节见[分发说明](DISTRIBUTION.md)。

## 常见问题

<details>
<summary>这是官方客户端吗？</summary>

不是。BiliKit 是第三方开源项目，和哔哩哔哩没有隶属、认可或赞助关系。
</details>

<details>
<summary>登录安全吗？</summary>

登录用 B 站官方的二维码。登录信息只保存在这台 Mac 的钥匙串里，不同步到 iCloud。
除了检查更新用的更新源，BiliKit 没有自己的服务器，也没有统计或广告 SDK，点赞、投币和收藏只在你自己操作时发出，不会替你关注或做别的操作。详见[隐私说明](PRIVACY.md)。
</details>

<details>
<summary>会支持下载、直播或多账号吗？</summary>

不会。这些都不在计划里，BiliKit 只想把看视频这件事做好。
</details>

<details>
<summary>从源码构建</summary>

用 Xcode 打开 `BiliKitMac.xcodeproj`，选择 `BiliKitMac` scheme 和 “My Mac” 运行。完整检查：

```sh
sh Scripts/run-quality-gates.sh app
```

[架构](docs/ARCHITECTURE.md) · [安全模型](docs/SECURITY-MODEL.md) · [发布流程](docs/release/README.md) ·
[安全问题报告](SECURITY.md) · [App Icon 源文件](Design/AppIcon/v1/) · [宣传截图](Design/Marketing/v2/)
</details>

## 许可证与声明

源代码使用 [MIT License](LICENSE)。BiliKit 名称、图标和宣传素材不在 MIT 授权范围内，见
[品牌资产权利声明](BRAND-ASSETS.md)；第三方依赖见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
哔哩哔哩相关名称与商标归其权利人所有。
