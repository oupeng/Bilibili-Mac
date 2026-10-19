# BiliKit 架构

本文只记录当前模块边界和仍约束代码的决策。事实以 `Packages/BiliKitCore/Package.swift`、
`Scripts/check-architecture.py` 和 Xcode 工程为准；安全规则见 [`SECURITY-MODEL.md`](SECURITY-MODEL.md)。

## 平台与命名

- Swift 6、SwiftUI + AppKit、AVPlayer；App、测试 target 与 Package 最低 macOS 15。
- App、App 测试与 Package 用同一组并发语义：Swift 6 语言模式、默认 `nonisolated` 隔离，加
  `InferIsolatedConformances` 与 `MemberImportVisibility`；不开 Approachable Concurrency 的
  `NonisolatedNonsendingByDefault`（`Scripts/check-project-contract.sh` 固定）。因此 `nonisolated async`
  不继承调用方 actor：bridge 解析、授权器读 Keychain、Range 流、图片解码这类工作在 `@MainActor`
  调用时仍离开主线程。代码在 App 与 Package 之间移动时不改变执行位置。
- 用户可见 App、构建产品与 Swift app module 为 `BiliKit`；仓库、Xcode 工程、内部 App target
  和 `BiliKitMacTests` 保留 `BiliKitMac`，与原 BiliKit userscript 仓库区分。
- Bundle ID `com.shiinayane.BiliKit`；Debug／Release 相同。Keychain access group 固定为
  `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`，更换 Team 或 Bundle ID 等于换一个
  Keychain 范围，旧登录态不迁移，也不得扩大 access group 去读取。
- 强调色是资源目录的 `AccentColor`：B 站粉调深，浅色 `#E84B85`、深色 `#F25D8E`，让上面的白字仍可读。
  界面只通过系统强调色（`controlAccentColor`／`Color.accentColor`）取用；用户在系统设置里选了具体
  主题颜色时以系统为准。

## 模块与依赖方向

仓库只有一个本地 Package `Packages/BiliKitCore`，以 target 作编译边界：

```text
BiliKit App（Composition Root、AppKit/AVKit 宿主、Sparkle）
 ├─ BiliBrowseFeature ──────┐
 ├─ BiliVideoDetailFeature ─┤
 ├─ BiliLibraryFeature ─────┼─> BiliApplication ─> BiliModels
 ├─ BiliAuthFeature ────────┘         ^ ports
 │    (Browse/VideoDetail/Library ─> BiliUI ─> BiliApplication / SwiftUI)
 │    (Browse/VideoDetail/Library ─> BiliVideoCollectionUI)
 ├─ BiliVideoCollectionUI ─> BiliUI / AppKit
 ├─ BiliAPI ──────┐
 ├─ BiliAuth ─────┼─> BiliApplication / BiliModels / BiliNetworking
 ├─ BiliPlayback ─┘
 └─ BiliDanmaku ─────> BiliApplication / BiliModels
BiliNetworking 不依赖任何 Bili 模块
```

| target | 拥有 | 不得依赖 |
| --- | --- | --- |
| `BiliModels` | 跨层稳定实体与值类型（视频、播放清单、字幕、弹幕、评论、账户投影） | 任何 Bili 模块、SwiftUI、AppKit、AVFoundation、Network |
| `BiliApplication` | Use Case、port（Feed、视频详情与播放地址、相关推荐、热搜、搜索联想、UP 主资料与投稿、播放控制与时间轴、字幕、弹幕分段与呈现、评论、认证与会话失效、观看历史、稍后再看、收藏夹、观看进度）、窗口账户复核的参与者契约 `AccountRevalidationParticipant`（由 Feature ViewModel 实现、App 窗口汇总，不是 adapter 实现的 port）、应用级错误、界面可用的账户投影（`AccountSessionScope`、`AccountPresentationState`，由窗口的账户会话状态得出），以及 `package` 并发原语（Feature 共用的 `LatestTask`、时间线与播放失败事件共用的多订阅广播 `AsyncBroadcast`）与列表来源共用的分页状态机 `PagedVideoList`，按页码整体替换的列表共用的翻页状态 `PageReplacementPaging`（总页数只由 BiliModels 的 `PageNumbering` 计算）；设置界面、样本发现与测速共用的线路测速样本数（`PlaybackRouteBenchmarkPolicy`） | 除 `BiliModels` 外的 Bili 模块、UI/播放/网络框架、DTO、Keychain、Cookie |
| `BiliNetworking` | 无业务语义的 HTTP client、Range client、`HTTPRequestAuthorizing`、URL 形状策略（含 BiliAPI 与 BiliAuth 共用的远端图片地址 HTTPS 升级 `WebImageURL`）与 JSON 响应判定 | Bili 模块、`Security`、UI/播放框架 |
| `BiliAPI` | endpoint DTO、WBI、解码、protobuf wire、远端错误映射，并实现 Application 仓库 port | `BiliAuth`（只接受注入的授权器） |
| `BiliAuth` | Web QR 状态机、Cookie envelope、Keychain store、请求授权器，实现 `AuthenticationServicing` | `BiliAPI`、`BiliPlayback`、`BiliDanmaku`、Feature、UI 框架 |
| `BiliPlayback` | DASH→HLS bridge、loopback server、SIDX、`AVPlayerEngine`、线路偏好与测速、响度 tap | `BiliAPI`、`BiliAuth` |
| `BiliDanmaku` | 弹幕会话与分段缓存、确定性车道布局、按媒体时间的 materializer、Core Animation renderer | `BiliAPI`、`BiliAuth`、`BiliNetworking`、`BiliPlayback`、Feature、SwiftUI |
| `Bili*Feature` | SwiftUI View 与 `@MainActor` ViewModel；Browse（Feed/Search，含推荐、热门、搜索的原生网格、热搜图标的取图 port `TrendingSearchIconLoading`、搜索会话 `VideoSearchSession`（草稿、排序与筛选、提交，以及来源到工作集的激活 `BrowseActivation`））、Library（观看历史、稍后再看与收藏夹：三者共用登录门槛、工具栏控件与刷新的外壳 `LibrarySourceShell`、账户复核进度 `LibraryAccountRevalidation` 与不可用原因的文字 `LibraryUnavailabilityFormatting`；观看历史与稍后再看共用资料库列表 ViewModel `LibraryVideoListModel` 与原生网格，各来源只给出读取、翻页策略、文案与卡片映射；稍后再看与收藏夹的不可用条目映射为不可用卡片；稍后再看的排序、筛选与关键词在每个窗口一份的会话 `WatchLaterSession`；收藏夹按页整体替换，不走 `PagedVideoList`：侧栏的收藏夹列表 `FavoriteFolderListModel` 与夹内页面 `FavoriteFolderViewModel`（选中的收藏夹、排序与关键词），以及侧栏分段视图 `FavoriteFolderSidebarSection`）、Auth（扫码登录、登出与账户投影的来源），播放页见下一行。共享的 AppKit 卡片与网格经 `BiliVideoCollectionUI` 渲染 | adapter target、其他 Feature、直接 import AppKit/AVKit/AVFoundation（播放页的例外见下一行） |
| `BiliVideoDetailFeature` | 播放页（VideoDetail）与侧栏上下文层 UP 主空间（UploaderSpace）：视频与分 P 意图、续播与链接起播、相关推荐与 UP 主名片（`VideoViewModel`；导航给出的 `PlaybackSelectionIntent` 怎样落到当前视频——就地换分 P、链接 `t=` 原地跳转或重新加载——以及失败后由模型重试还是交回导航，也只在这里），合集选集的分 P（`CollectionEpisodePagesController`），评论（`PlaybackCommentsViewModel`），弹幕设置，空间投稿列表（`UploaderSpaceViewModel`），以及主区布局、骨架、相关推荐横排与选集、评论、投稿行的呈现投影；播放页失败（`VideoLoadFailure`）的标题、说明与是否可重试只在这里。这些页面的 AppKit 视图也在这里：播放侧栏（`NativePlaybackSidebarView`，含评论原生 item）、评论图片预览与保存（`NativeCommentImagePreviewView`、`NativeCommentImageSaver`、动图播放）、相关推荐横排（`RelatedNativeShelfView`）与空间列表（`UploaderSpaceSidebarView`）。取图 port `VideoDetailImageLoading`（头像、封面、表情、评论图片与预览；结果含图、可选的动图数据 `NativeAnimatedImage` 与是否淡入，评论图片另可取原图数据；相关推荐横排是共享卡片，仍走卡片 port `NativeVideoImageLoading`，不为本 Feature 的其他用途放宽它），App 构造的评论资源地址闭包`CommentAssetURLResolver`，以及 App 键盘控制器检查的 `PlayerKeyboardFocusOwner`。拥有自己的字符串目录；App 用到的类型为 `public`，有 library product | 同其他 Feature，但可直接 import AppKit、CoreText（评论正文排版）与 ImageIO（动图逐帧解码）；横排卡片与集合视图支撑经 `BiliVideoCollectionUI`；不依赖 AVKit/AVFoundation、网络与 adapter；下载、来源与响应校验、首帧解码、动图播放门槛和缓存只在 App 管线，本 target 只对管线按门槛放行的 `NativeAnimatedImage` 数据逐帧解码播放 |
| `BiliUI` | Feature 共享的 SwiftUI 呈现层：卡片几何、网格、骨架、加载过渡、刷新与分页状态胶囊、按页整体替换的列表底部悬浮的页码条（`PageNumberPager`，几何与列表为它留出的高度在 `PageNumberPagerGeometry`）、整页失败视图，只按账户读取的来源共用的登录门槛（`AccountGateView`，形态映射为 `AccountGatePhase`），`ContentApplicationError` 的失败文案（`ContentFailureText`），计数、时长与日期格式化，视频卡片的 B 站图片缩略地址；拥有自己的字符串目录。默认 `package` 访问级别，App 直接使用的卡片几何、时长格式化、播放器加载转圈、单行失败说明（`ContentFailureText.message`）、头像图片的像素边长（`BiliAvatarImageSize`：卡片、评论与侧栏账号头像的请求框、图片管线的头像解码上限都取它）与头像缩略地址（`BiliImageThumbnail` 的头像尺寸，侧栏账号头像请求前经它改写）为 `public`；AppKit target `BiliVideoCollectionUI` 也经 `package` 接口取用它的文案（卡片选中与不可播放的读屏值 `VideoCardAccessibilityText`）。无 library product | 除 Foundation、SwiftUI、BiliApplication 外的任何模块（含 BiliModels、AppKit 与其他 Feature） |
| `BiliVideoCollectionUI` | 浏览网格与横排共用的 AppKit 卡片（`NativeVideoCollectionItem`、封面与文字层；调用方可把卡片标为不可用 `NativeVideoCardAvailability.unavailable`：变暗、封面角标写调用方给的原因、不画悬停与按下，网格拒绝鼠标选中，点击、回车、空格与读屏按下都不激活，键盘选择仍可停留，读屏呈现为不可用的按钮）、原生网格 `NativeVideoGridView` 及其状态（回顶握手、锚点、预备区域），集合视图的悬停、键盘与通知观察，卡片与评论图片共用的淡入动画 `NativeImageFadeAnimation`，近尾部分页 `NearEndPagination`，滚动坐标换算，取图 port `NativeVideoImageLoading`（只分封面与头像，结果只含图与是否淡入），来源网格从 App 窗口拿到的依赖 `NativeVideoGridHostContext`（滚动位置、回顶请求、取图 port），以及网格与横排共用的内容差异 `NativeVideoGridUpdatePlan`。App 用到的类型为 `public`（取图 port 及其结果类型、网格依赖 `NativeVideoGridHostContext` 与回顶请求、通知观察集合，以及 SwiftUI 一侧的新图淡入 `NativeImageFadeTransition`：评论图片预览与侧栏账号头像共用，时长与 `NativeImageFadeAnimation` 相同），只有 Package 内 Feature 用到的为 `package`（除上述 `public` 类型外，凡是 Feature 用到的都是），其余为 `internal`，有 library product | 除 BiliUI 外的 Bili 模块（含 BiliNetworking、adapter 与 Feature）；图片下载与缓存只经 port 注入 |
| App `BiliKitMac` | composition root、导航协调、来源描述、复核汇总与评论链接执行（`Navigation/`）、进程级与窗口级组装（`Composition/` 的 `ProcessComposition`、`WindowComposition`）、`AVPlayerView` 宿主、各来源网格的滚动位置与回顶请求、图片管线（实现卡片、热搜图标与播放页三个取图 port；侧栏账号头像 `AccountAvatarImage` 与管线同在 App，直接按头像用途取图，不另设 port）、Settings、Now Playing、Sparkle | `App/` 与 `Navigation/` 目录不直接 import adapter 或平台框架（`Navigation/` 只依赖 Feature、Application 与 Models），具体实现只在 `Composition/`、`Platform/`、`Settings/` 出现；Application 只在搜索、稍后再看与收藏夹条件或账户投影的使用点 import（`AppRootView`、`AppShellView`、`AppSidebarViews`、`AppSourceRootViews`、`SearchToolbarControls`、`WatchLaterToolbarControls`、`FavoritesToolbarControls`；三者共用的菜单、按钮与弹窗外壳 `ToolbarFilterControls` 不依赖 Application；成员可见性要求直接 import 定义模块，Feature 不转出 Application）；BiliVideoCollectionUI 在 `Platform/` 只由播放器宿主（通知观察集合）、图片管线（实现卡片取图 port）与侧栏账号头像（SwiftUI 淡入）import，`Composition/` 只有 `WatchProgressWindowConnection`，`App/` 只有构造并转交 `NativeVideoGridHostContext` 的 `AppShellView`、`AppSourceRootViews`；只按账户读取的来源由 Feature 渲染登录门槛，App 只注入账户呈现状态与打开登录页的动作；例外是稍后再看另注入排序菜单与筛选按钮（`WatchLaterToolbarControls`）、收藏夹另注入排序菜单（`FavoritesToolbarControls`），由 Feature 放进自己 `.toolbar` 的 primaryAction 组、排在刷新之前，保证同组顺序；侧栏「收藏夹」组的行由 Library 的分段视图渲染，App 只给出带 ID 的选择值与折叠状态 |

补充规则：

- SwiftProtobuf 只允许 `BiliAPI` import；Sparkle 只允许 App target。
- Feature 之间不互相 import，跨域跳转由 App 层协调。
- ViewModel 拥有用户意图的 Task、取消与 generation；只有最新意图能写回 UI State，单一最新
  意图统一用 `LatestTask` 隔离，不各自手写。View 的 `.task(id:)` 只把生命周期意图交给 ViewModel。
- adapter 必须传播 `CancellationError`，不把取消折叠成网络失败。
- adapter 只经 `BiliAPIError.Failure`（`domainError`）分类远端错误，各域只把分类对应到自己的 Application
  错误。内容类读取（Feed、视频、UP 主空间、观看历史、稍后再看、收藏夹）共用
  `BiliAPIError.contentApplicationError(for:)` 映射到 `ContentApplicationError`：认证分无凭据、凭据失效、
  本地凭据读不到、风控四态，业务码 -404／62002／62004 归为“内容不存在或不可见”。收藏夹 adapter 另有两处专属映射：夹内读取的
  `data`／`info` 为 null 与业务码 11010 是“内容不存在”（收藏夹已不存在），-403 是凭据失效（访问自己的收藏夹不应被拒）。是否复核账户、是否给
  重试只由 `ContentApplicationError` 的 `requiresAccountRevalidation`／`isRetryable` 决定，Feature 不各自判断。
  评论、字幕与弹幕的 Application 错误不并入内容域，但同样各自提供 `requiresAccountRevalidation`（评论另有
  `isRetryable`，评论列表、分页与楼中楼的失败界面据此决定是否给重试），调用方只读这些属性。
- 新 target 需同时具备稳定独立领域、独立状态或安全／性能边界、真实调用方与测试；默认在现有
  target 内加子目录。不建立 `Common`／`Shared`／`Utils`，不建立空占位 target。
- 两个以上 Feature（或 Feature 与 App）共用的呈现放进 `BiliUI`，只有一个调用方的留在拥有它的 Feature。
  BiliUI 的组件只负责排版与措辞，标签、动作与“是否可重试”由调用方给出；文案用 BiliUI 自己的字符串目录，
  调用方传入的标题（如失败标题的兜底）由调用方本地化。内容失败的标题与说明只有 `ContentFailureText`
  一份：凭据类失败的说明按页面所知的账户复核进度（不跟踪／进行中／已结束）区分，没有专属标题的失败用来源
  自己的标题。视频卡片封面与头像的缩略参数只由 `BiliImageThumbnail` 追加；评论资源是不透明引用，其图片
  地址与缩略参数只由 BiliAPI 的 resolver 生成。
- 网格与横排共用的 AppKit 卡片、网格与集合视图支撑放在 `BiliVideoCollectionUI`。各来源把条目映射为卡片的
  网格包装放在拥有该来源的 Feature（推荐、热门、搜索在 Browse，观看历史、稍后再看与收藏夹在 Library），Feature 视图直接渲染它们，
  不经 App 填充的泛型内容插槽；相关推荐横排、播放侧栏、评论图片预览与 UP 主空间的 AppKit 视图与它们读取的
  ViewModel、呈现投影都在 `BiliVideoDetailFeature`，横排同样由播放页视图直接渲染、不经插槽；App 只注入窗口级依赖
  （图片管线经卡片与播放页两个取图 port、评论资源地址闭包、保存图片的窗口级 owner）。Browse 与播放页之间的跳转（选卡片进入播放、返回来源）由 App 协调。
  Feature 视图拥有 loading／empty／failure 与网格的呈现，App 只注入窗口级依赖：每个来源一个
  `NativeVideoGridHostContext`（图片管线经取图 port，以及 `AppShellView` 持有的滚动位置与回顶请求，回顶在刷新
  成功与账户变化时由它发出），Feature 原样交给网格。除 `BiliVideoDetailFeature` 外，Feature 不直接 import AppKit。卡片与网格只经 `NativeVideoImageLoading` 取图：先同步查缓存（复用的卡片在配置当帧显示已缓存的图，
  不闪占位），未命中再异步加载；实现是 App 的 `NativeVideoImagePipeline`，无凭据 session、来源与响应校验、
  缓存上界都只在那里（见 `SECURITY-MODEL.md` §4、§6）。port 只分封面与头像、结果只带图与是否淡入；某个
  Feature 自己的图片用途另设该 Feature 的窄 port（搜索起始页的热搜图标是 Browse 的
  `TrendingSearchIconLoading`，播放页的头像、封面、表情与评论图片是 VideoDetail 的 `VideoDetailImageLoading`），不放宽
  卡片 port。管线完整的用途枚举、解码与动图播放门槛、来源类型留在 App，实现 port 时映射；动图数据的包装
  `NativeAnimatedImage` 在 VideoDetail，由管线构造。

## 关键决策

### 组装分层

- 进程级 `ProcessComposition`（`Composition/`，`BiliKitMacApp` 持有唯一一份，随进程存活、不关闭）：账户会话
  协调器、进程唯一的观看进度 writer（构造时就登记进账户会话，与它的 transport 一起随登出、换号与凭据失效
  失效）、设置与线路测速（测速用自己的 API client，同样登记进账户会话）、系统 Now Playing、本机搜索历史与更新器。
  生产 `BiliAPIClient` 只由 `LiveAPIClients` 构造，账户读取 allowlist 也只在那里声明。
- 窗口级 `WindowComposition`（`Composition/`，每个窗口一份，由 `AppRootView` 在视图身份首次出现时经
  `ProcessComposition.makeWindow()` 构造一次）：全部模型（浏览、视频、评论、弹幕、认证、稍后再看、观看历史、收藏夹列表与夹内页面、UP 主空间、
  热搜与联想、搜索会话、稍后再看会话）、导航协调、来源描述与复核参与者、播放器视图、窗口图片管线、评论短链解析与图片保存、Now
  Playing 与观看进度的连接。它只引用进程级对象，不替它们创建或关闭。具体实现只经 `WindowAdapters`（仓库、
  认证服务、播放控制与播放器视图、弹幕呈现与偏好、Now Playing 与观看进度连接、窗口打开与关闭时 adapter 自己
  的登记与清理）进入；生产由 `WindowAdapters.live(process:)` 一处构造（窗口自己的 API client、`AVPlayerEngine`、
  弹幕 renderer、会话与内存压力监听），测试换成替身后走同一条组装路径。
- 窗口出现时，`AppRootView` 先把当前账户范围同步为观看进度的上报权限，再 `open()`：登记窗口 API 的会话失效，
  开始观看进度与 Now Playing。窗口消失时 `close()`（不可逆）按序：从进程级测速注销本窗口 → 关闭播放并恢复新窗口
  的来源 → 各来源丢弃内容（Browse 工作集整体一次）→ 取消认证临时任务与评论 → 取消短链解析与图片保存 → 停止观看
  进度与 Now Playing → 关闭图片管线 → adapter 取消弹幕内存压力监听、停止播放偏好的持久化、注销会话并失效短链
  session。adapter 的这一步只在窗口打开过之后执行，没打开过的窗口不注销从未登记的会话。

### 播放：DASH→HLS loopback bridge

`AVAssetResourceLoaderDelegate` 可以提供 playlist，但由它返回 fMP4 媒体分段时 `AVPlayerItem` 以
`CoreMediaErrorDomain -12881` 失败；AVFoundation 需要自己加载分段来执行自适应逻辑。因此
`BiliPlayback` 在进程内起一个最小 HTTP/1.1 server，只绑定 `127.0.0.1`、系统分配端口、随机
session path，提供内存中生成的 master／media playlist，并把 AVPlayer 的 Range 转发到 CDN。

- SIDX 成功的候选成为该 representation 的唯一远端来源，后续 init、media 与 Range 不跨来源拼字节；
  分段正文与 progressive 共用同一流式转发，逐 chunk 写入 loopback，不整段缓存；SIDX 与音频 init
  也经同一流式 client 先验证响应头再收正文。同一 bridge 的 SIDX／init 读取与各播放会话共用一个
  Range 会话以复用 CDN 连接，server 停止只取消自己的在途请求。
- 上游响应必须通过状态码、`Content-Range`、长度校验；取消不触发备用线路，AVPlayer 断开连接或
  下游写入失败都按取消处理并立即取消上游请求。
- 只有全部 SIDX reference 从 type-1 SAP 开始且 `SAP_delta_time` 为 0 时才发布 I-frame rendition，
  它复用同一 route 的完整 fragment Range，不预读、不缓存。
- 各档视频 SIDX 并行读取。某一档在读取阶段失败时只丢弃该档：全部候选失败（含响应头校验失败与 SIDX
  解析失败）、`Content-Range` 缺少完整长度、索引区间超过 1 MiB 或非法。master 只发布成功的档，至少一档
  可用就继续播放，全部失败才让播放失败（报告排在最前的那一档的错误）。取消原样传播，不当成某一档失败。
  与 AI 配音一致，单个附加档位失败不拖垮播放。读取成功之后，生成 playlist 或计算码率出错（例如
  `noMediaSegments`、`invalidCalculatedBitRate`）仍让整次播放失败。
- 同一 AUDIO group 以原声 SIDX 起点为准；起点不一致的 AI 音轨在生成 master 前丢弃。
- AI 配音只对账户读取请求，按语言逐个取 playurl；某个语言失败（风控、网络、业务拒绝、本地授权不可用，
  至多经过一次 WBI 重试）就停止后续语言的配音请求，只保留已拿到的音轨和原声，播放照常进行。凭据失效与
  会话变化仍让播放失败或取消。
- 没有 DASH 但有安全单段 `durl` 时注册 progressive MP4 route：原样保留 AVPlayer 的单一 Range，
  验证后逐 chunk 写入 loopback，不累积整段；不支持多段 `durl` 拼接。格式只接受 `mp4` 与 `hdmp4`
  （较早视频只有整段文件，最高 720P），`flv*` 不支持；请求的清晰度只有 FLV 时，按 `support_formats`
  里不高于请求的最高 MP4 清晰度重取一次。
- `AVPlayerEngine` 是 `AVPlayerItem`、loopback server、原生字幕 route 的唯一 owner；替换、停止或
  释放时关闭 server 并取消连接与上游 Task。不使用私有 AVFoundation header 注入。

### 媒体时间轴

`BiliApplication.PlaybackTimelineProviding` 是弹幕、Now Playing 与观看进度的唯一时间来源，由
`BiliPlayback` 用 AVPlayer observation 与 item 通知实现，表达 item identity、位置、速率、状态与
discontinuity generation。消费者不自建 wall-clock timer，也不接触 `AVPlayer`／`CMTime`／KVO；各自 timer 无法正确
表达卡顿、暂停、倍速和 seek。唯一的例外是弹幕动画本身：弹幕 layer 挂在播放器宿主的
`AVSynchronizedLayer` 下，由 AVFoundation 按 item timebase 驱动（见「弹幕」）；哪些弹幕在屏上、何时请求
分段仍按时间线快照决定，`BiliDanmaku` 不接触 AVFoundation。字幕作为原生 subtitle rendition 进入同一 `AVPlayerItem`，由系统字幕
菜单选择。

- 续播位置在 load 时写入 master playlist 的 `#EXT-X-START:TIME-OFFSET=…,PRECISE=YES`，item 就绪即
  精确位于该处，不再“先就绪、再内部 seek”：少一次 seek、少下载开头分段，也没有 seek 期间辨认
  time-jump 来源的竞态。`beginPlayback` 只按就绪位置报告续播或从头开始；“从头播放”仍是 seek 到 0。
- 时间轴与交互记录器在 item 开始时得知起播位置：就绪时据此标记一次 discontinuity，弹幕从起播位置
  排起；落在起播位置的系统 time-jump 不算用户操作，否则会拒绝自动开播。
- `discontinuityGeneration` 由 engine 的 seek 收尾与 `AVPlayerItem` 的 time-jump 通知推进，观看进度、
  Now Playing 与弹幕使用；原生拖动的每一步都会推进它。一次 seek 的落点记录在播放位置仍在落点附近时吞掉
  落在它附近的重复跳变（例如暂停中 seek 后开播时系统再报一次），播放离开落点、新 seek、外部跳变、换项或
  clear 之后不再吞；这样同一次 seek 只推进一次，Now Playing 依赖它。每次从暂停恢复播放，系统都会报一次
  原地的时间跳变（刚在原处 seek 过、落点还在吞的除外），它推进一次不连续代号；弹幕因此多做一次内容相同的
  暂存提交，画面不变。周期回调的位置照常写入。
- progressive 单文件（充电试看、没有 DASH 的较早视频）没有 playlist，不续播，一律从头播放。

### 弹幕

- 分段是 protobuf。`BiliAPI` 以 exact 1.38.1 依赖 SwiftProtobuf（Apache 2.0 + runtime exception），
  `.proto` 自行编写，用同版本 `protoc-gen-swift` 显式生成并提交 `.pb.swift`，不挂 build plugin。
  手写 wire reader 要长期自维护 varint、未知字段和恶意长度边界，成本高于约 1.8 MiB 的体积。
- wire 类型解码后立即映射为 `BiliModels.DanmakuEvent`；`BiliDanmaku` 只见 Models/Application。
- renderer 使用 Core Animation layer 与纹理缓存，车道布局与 materializer 可用虚拟时间独立测试。系统内存压力时
  清空纹理缓存，在途准备以容量不足拒绝；`BiliDanmaku` 不自己监听内存压力，监听由窗口 adapter（`WindowAdapters.live`）持有并在
  窗口关闭时先于会话注销取消，与图片管线共用 `SystemMemoryPressureObserver`。
- 分段请求会被间歇风控（游客更常见），被 HTTP 412 拒绝的分段由 API 客户端等 2 秒后再请求一次（等待期间
  占一个加载名额）；其余失败与再次被拒的分段在当前视频内不再请求，换视频或重开会话才重来。
- 在同一组已缓存分段、同一组设置下，画面是媒体时间的纯函数：seek（含暂停中）到某一时刻与连续播放到该
  时刻看到同样的弹幕，之后立即满屏，不需要识别 seek 才能正确显示，也没有投递游标、去重或补位。与「从头
  连续排」一致只在下文的种子链成立时才保证。三部分：
  - 车道布局（`DanmakuLayoutPlanner`，后台由 `DanmakuLayoutCoordinator` 串行计算）：每个缓存的分段把
    通过过滤的事件按 (时间, ID) 排序，在弹幕自己的时间点逐条交给 `DanmakuLaneAllocator` 准入，得到车道、
    层、纵坐标与运动时长；同屏上限 `hardMaximumActiveCount` 在这里按同一顺序丢弃。宽度来自只排版不栅格化的
    测量，与纹理共用一份排版计算，按文字、字号与 scale 缓存。相邻分段重复给出的 ID 只在前一段显示，同一段
    里重复的只取第一条。分段边界以上一段末尾的车道占用为种子，边界处不重叠；上一段不在缓存里时从空占用
    开始排。因此同一时刻的车道可能因浏览历史不同而不同：只有上一段在缓存、且它的种子链一直能接到第一段
    时，结果才与从头连续排一致，否则差异只出现在分段开头、两份占用收敛之前（实测多在一两条弹幕的最长时长
    之内）；缓存不为此扩大。上一段晚到时以它为种子重排本段（屏上少数弹幕可能换一次车道），末尾占用变了
    才继续重排下一段。设置（类型显隐、速度、显示区域、密度、画面尺寸、backing scale）变化时后台整张
    重排，generation 丢弃过期结果，完成后一次替换；窗口 live resize 去抖 200ms，去抖期间屏上仍是旧布局，
    顶部底部弹幕随新宽度重新居中、底部弹幕贴住底边，滚动弹幕按旧宽度运动。画面尚未布局（尺寸为 0）时
    不布局。
  - 交叉淡化：设置或画面尺寸变化（全屏、缩放、live resize 去抖后）引起、且屏上已有弹幕的整张重排，旧组
    淡出、新组淡入，各 200ms。淡化放在同步 layer 之外的两个普通容器上，显式的不透明度动画按挂钟计时，
    暂停时照常走完；旧组移出同步 layer 后由自己的时间属性按淡化开始时的媒体时间与速率继续走（暂停时
    静止）。新组挂同一条弹幕时复用旧组的同一个 CGImage，不重新栅格化；淡化结束后移除旧组。淡化中再次
    重排时立即结束当前淡化、以当前画面为新的旧组；淡化中 seek、换 item、关闭弹幕时立即结束、瞬时替换。
    seek 落地、分段到达、上一段晚到、打开弹幕与换 item 一律瞬时替换。
  - materializer（`DanmakuMaterializer`）：时刻 t 在屏的 layer 是布局表里已进场未走完、或 2 秒内要进场的
    弹幕；纹理提前准备，以将来的开始时间挂上，迟到的纹理挂上后直接出现在中途应在的位置。播放中时间每推进
    1 秒对齐一次；布局表替换、时间不连续、打开弹幕、接管 surface 时暂存提交：缺的纹理全部有结果后，在一次调用里
    按此刻完成整屏的移除、换车道与挂上，挂上按 (时间, ID) 顺序。窗口换到 backing scale 不同的屏幕时，已在屏
    的弹幕也当作缺纹理重新准备，提交时原位换纹理，不先移除。
  - 渲染：`rootLayer` 挂在播放器宿主（`DanmakuOverlayView`）的 `AVSynchronizedLayer` 下，子树的局部时间
    就是播放 item 的时间。动画 `beginTime` 是弹幕的时间点（0 写成 `AVCoreAnimationBeginTimeAtZero`，由
    App 注入，`BiliDanmaku` 不 import AVFoundation），`removedOnCompletion` 为 false；fillMode 保持默认，
    动画区间外呈现回到模型值，所以模型值本身不可见（滚动弹幕在画面左外侧，顶部底部弹幕不透明度为 0），
    可见区间由动画撑起。暂停、倍速、缓冲停顿、播放结束与暂停中 seek 都由 AVFoundation 调整同步 layer，
    renderer 没有时钟；主线程卡顿时渲染服务器按原速率继续插值，之后精确跳回。同步 layer 不随
    `replaceCurrentItem` 自动换绑：宿主在 `currentItem` 变化时先让呈现控制器清屏（只接受当前 surface
    owner，布局表保留），再换绑。以上是在 macOS 27 上用本地 HLS 与 mp4 实测的系统行为。
- seek 不隐藏也不清屏，屏上的 layer 一直跟随媒体时间：拖到远处时它们都落在动画区间之外，画面自然为空；
  原地跳变画面不变。`discontinuityGeneration` 变化时按快照位置暂存提交一次，否则播放中每推进 1 秒普通
  对齐。拖动的每一步都推进不连续代号，每步都发起一次暂存提交并作废上一步还没完成的纹理准备（排队中的
  栅格化随之取消，不拖慢下一步），最后一步之后自然提交到落点；误报的跳变只多做一次内容相同的提交。落点
  分段未到时对齐为空，分段到达后整屏挂上。清屏只在换 item、换视频、关闭弹幕与交接 surface 时出现；关闭
  弹幕保留布局表，打开时按当前时刻整屏挂上。
- 分段缓存（`DanmakuSegmentCache`）最多三段，淘汰离最近快照位置（拖动中随拖动更新）最远的；位置在分段
  开头 60 秒（滚动弹幕的最长时长）内时一并请求上一段，未到结尾时请求下一段。暂停、缓冲时没有新快照，
  一个分段加载完腾出名额后，会话按最近处理过的快照继续请求。
- 纹理字节上限（64 MiB）只作内存安全阀，按全部 layer（含前瞻弹幕）计：超限时先移除已走完、还没等到
  对齐的，再由已进场的弹幕挤掉进场最晚的前瞻弹幕；前瞻弹幕之间不互相挤，超限即被拒。被拒的弹幕缺席，
  但不影响车道布局。
- 弹幕由同步 layer 驱动，暂停时增删 layer 由系统照常合成，不需要主动请求重新合成。弹幕 layer 与 `rootLayer`
  用 `actions` 禁用上屏、移除、子层与几何变化的隐式动画，增删不另包显式事务（顶层显式事务会单独提交，
  把同一次对齐拆进不同的提交）。
- 大会员彩色弹幕：元素字段 24 `colorful` 为 60001 时映射为 `DanmakuColorStyle.vipGradient`，其余类型按普通
  弹幕显示。外观按官方贴图的结论内置：白色填充、0.5pt 描边从文字左缘到右缘按采样色标做横向渐变、阴影
  仍为深色；不下载分段回复 `colorfulSrc` 给的贴图，纹理同步绘制，官方更换贴图时不会跟随。

### 原生 AppKit 集合视图

- **播放侧栏**：上传者、简介、选集／分 P、评论与分页 footer 由一个 `NSScrollView + NSCollectionView`
  拥有，全部是原生 item。真实长评论下 `ScrollView + LazyVStack` 产生不收敛的 SwiftUI
  transaction／AttributeGraph 工作；逐行 `NSHostingView` + `fittingSize` 会把全表重测放大到秒级。
  正文使用可选择、不可编辑的 `NSTextView`；diffable identity 为 subject + root `CommentID`；
  高度缓存按 identity、宽度桶、内容 revision 做有界 LRU，resize 分批精测并恢复语义 anchor。
  `PlaybackCommentsViewModel` 仍唯一拥有 subject、排序、分页、并发上限与 generation。
  评论状态行与页脚的加载是固定行高的系统转圈（状态行大号、页脚小号）：加载中的状态行与说明行
  （idle／empty／closed）同高，加载中的页脚与“加载更多”行同高；转圈只在加载中转动，复用即停，不单独读屏。
- **浏览网格与 shelf**：首页推荐、热门、搜索、观看历史、稍后再看、收藏夹的网格和相关推荐 shelf 使用
  `NSCollectionView` + 复用的原生卡片；卡片与网格在 `BiliVideoCollectionUI`，各来源的网格包装在拥有它的
  Feature，shelf 在 `BiliVideoDetailFeature`。热门 50 卡 A/B 表明 SwiftUI `LazyVGrid`/AttributeGraph 是主要滚动成本；卡片 overlay
  与文字改为持久 `CALayer`／`CATextLayer` 后，同样约 20 秒滚动 cycles 下降约 39%，0 hitch。来源的
  loading／empty／failure 等状态与网格在同一个 Feature 视图里渲染，网格只是已加载状态的呈现。
  网格加载中的骨架（BiliUI `VideoCardGridSkeleton`）与相关推荐横排的骨架共用卡片骨架 `VideoCardSkeleton`
  （横排不带头像），张数由可见尺寸与真实网格或横排的同一几何算出（`VideoCardGridGeometry.placeholderCount`、
  `NativeVideoShelfGeometry.placeholderCount`）并向上取整，露出一部分的行或卡片也画，任何窗口都铺满可见区域。
  网格骨架的张数取“可见区域能放下的张数”与“来源已知的本页条数”中的较小者，来源不知道条数时铺满，内容少的
  来源加载完不会突然少掉一大片：收藏夹按侧栏列表里该夹的 `media_count` 与页码算本页条数（有关键词或没有该夹
  的元数据时不知道）；稍后再看取同一条件上次成功加载的总数、封顶为一页（首次进入与条件变化后不知道）；首页、
  热门、搜索与观看历史不知道。只用已拿到的数，不另发请求、不缓存。
- 网格提前准备：AppKit 默认只为视野内创建卡片，封面要等卡片露出来才开始加载。网格的集合视图把准备区域
  设为视野上下各一屏（`prepareContent(in:)`），并在滚动、布局与内容更新时检查余量，不足半屏就主动刷新，
  同时存在的卡片约为三屏；离开准备区域的卡片照常复用并取消封面等待。键盘选择的起点与滚动锚点只取与
  视野相交的卡片，不取准备区域里看不见的卡片。视野底边离内容底部不足 1.5 屏时请求
  下一页；新一页到来时若仍在阈值内（一页可能比阈值矮）立即再布防，保持内容储备，仍是每个尾部一次、
  一次滚动手势最多一页。评论侧栏的阈值比一页矮，保留“先离开阈值再布防”。
- 首页推荐、热门、搜索、观看历史与稍后再看的分页都由 `PagedVideoList`（BiliApplication）承担；来源只把远端页
  适配为“条目 + 下一页游标”（Feed 的游标是下一页请求，历史是 adapter 生成的不透明 continuation，稍后再看是条件加页码的完整请求 `WatchLaterRequest`），
  Feed 与稍后再看另校验响应属于所请求的页（稍后再看：总条数不为负、条数不超过每页条数；`count` 口径未经证实，有条目而总条数不多于前面各页时按最后一页接受，页码衔接在
  `WatchLaterUseCase`）。稍后再看本页有条目且已请求条数少于接口给的总条数才有下一页，不另设条数上限。各来源最多
  保留 1000 条（`VideoListRetention`），按 BVID 去重后截断（这五个分页来源只在 `PagedVideoList`
  去重，adapter 映射与网格卡片映射不另做；集合层的 `NativeVideoCardContents` 另按卡片 ID 兜底）；达到上限即收起分页
  尾标、不再请求下一页。没有新条目的页：推荐、热门、搜索与稍后再看停止翻页；历史保留 continuation、收起尾标，由用户
  点“加载更早的记录”显式继续（空页跳过与游标前进校验在 `WatchHistoryUseCase`）。下一页游标回环（含不前进）
  按无效响应报告并停止，即使同时达到条目上限。历史一次分页会话最多加载更多 100 页；推荐、热门、搜索与稍后再看每页
  至少新增一条，页数已被条目上限封住，不另设页数上限。分页尾标是只在并入新条目时递增的计数。加载更多失败
  保留条目与游标、暂停自动加载（不给尾标），底部重试请求同一游标；被失败或离开页面打断的显式继续仍需显式
  继续，不会变成自动扫描。
- 收藏夹与 UP 主空间按页整体替换，不走 `PagedVideoList`：翻页状态是 BiliApplication 的 `PageReplacementPaging`
  （保留上一页的总数与总页数、越界与正在显示／加载的页不请求、失败重试当前页、总数变少时退回最后一页），底部悬浮
  页码条是 BiliUI 的 `PageNumberPager`。收藏夹每页 40 条，总页数取当前条件下的 `media_count`，越界页给出的 0 不
  覆盖已知总数（先回第 1 页取新总数再转到最后一页，一次意图里至多改请求两次），是否还有下一页以 `has_more` 为准，
  某页过滤后为空而还有其他页时说明“本页没有可显示的视频”并保留页码条。网格不做近尾自动加载（尾标为 `.end`），
  末行下方为页码条留出 `PageNumberPagerGeometry.reservedHeight`（`NativeVideoGridView` 的 `bottomInset`，布局与内容
  高度同源）；选夹、换夹、翻页、换排序或关键词与刷新每次替换成功，刷新代次都前进、网格回顶。
- 首页推荐、热门、搜索、观看历史、稍后再看与收藏夹在已有内容时都原地刷新（收藏夹原地重读当前页）：网格不卸载，顶部显示共用的 `RefreshStatusCapsule`
  （BiliUI；结果为空时也显示），成功后整体替换并由刷新代次把该来源的网格滚回顶部；失败保留已显示内容并在
  胶囊里给出原因。底部的加载更多转圈、失败原因与重试，以及历史空页之后的“加载更早的记录”按钮共用
  `PaginationStatusOverlay`（BiliUI）。刷新期间各来源都收起分页尾标（历史的“加载更早的记录”也一并收起），
  结束后重新给出：
  网格对同一尾标只触发一次，刷新中被忽略的近尾事件要靠尾标重新出现才能再布防。账户变化替换所有来源的内容，所有网格都回到顶部。
  观看历史与稍后再看（同一 `LibraryVideoListModel`）以及收藏夹（复核进度同一份 `LibraryAccountRevalidation`）在
  刷新或加载更多遇到凭据缺失或失效时放弃已显示内容、转入失败页并请求账户复核；复核期间显示“正在重新确认”，确认仍登录后自动重载一次（直到下一次加载成功前不再自动
  重载），复核结束仍失败时给静态说明。离开页面时停止等待复核，凭据失败页回到初始状态，回来时重新加载。本地凭据读不到与复核失败显示
  “无法读取登录状态”并可重试。首次加载仍是骨架屏。程序回到顶部后、用户再次滚动前，内容整体
  替换保持在顶部（`NativeVideoGridTopPin`），不按旧内容第一张可见卡片做锚点恢复；锚点卡片已不在新内容里时
  也直接回到顶部，不停在被新内容高度截断的旧偏移上。网格的 snapshot 不做差异动画：动画结束前新卡片不会
  创建，而整体替换紧接着回顶，视野会空白一段。重排 document 或等待恢复偏移期间不判断翻页。网格同步出去的
  滚动位置在同一轮更新里被交回旧值时不当作新的请求（`NativeVideoScrollBindingBridge`）。
- 卡片尾部（历史的日期）前可带一个 SF Symbol 小图标，作为遮罩、底色取页脚颜色，随外观与文字同色；图标
  宽度计入尾部宽度，名字放不下时只截断左侧名字。历史的观看设备来自接口 `history.dt`（1/3/5/7 手机、2 网页、
  4/6 平板、33 电视），其他取值不显示。
- **UP 主空间列表**：头部（返回、头像、名字、三段排序）与投稿行是同一个 `NSCollectionView` 的原生
  item，随列表滚到工具栏下由系统做边缘模糊。行高固定，不需要测量缓存；加载、空、失败与登录提示
  由 SwiftUI 叠在头部下方，返回按钮始终可点。加载用转圈而不是骨架：投稿数因人而异，占位行会误导数量。
  评论区同理，首次、重新加载与追加都用转圈：评论长短、图片与楼中楼各不相同，骨架会误导条数与长度。
  列表不接收键盘焦点，方向键、空格留给播放器快捷键。
  悬停由 `NativeVideoHoverTracker` 统一管理（网格卡片与投稿行都实现 `NativeHoverableCollectionItem`）；
  “返回顶部”玻璃按钮与评论区共用 `NativeScrollToTopScrollView`。
- 封面、头像与评论图片由 `WindowComposition` 持有的窗口级匿名、有界 `NativeVideoImagePipeline`
  加载（Now Playing 封面另有进程级实例）；cell 离屏、复用和 teardown 取消等待者。缓存上界按管线用途
  只在 `NativeVideoImageCacheLimits` 定义：窗口 160 张／64 MiB，Now Playing 4 张／8 MiB；单张成本超过
  总上限的 1/4（如评论图片预览的大原图）不进共享缓存，由预览会话持有当前与前后各一张，来回翻页不重新
  下载；关闭预览即释放，再打开会重新下载。系统内存压力时清空缓存，
  在途请求照常完成；owner shutdown 时先取消压力监听。
- 评论列表图片与头像请求图床按框缩小的 WebP（`@{宽}w_{高}h.webp`，图床按比例缩进框内、不放大），框按
  用途只在 `NativePlaybackCommentAssetSizing` 定义：列表为最大显示尺寸的 2 倍，头像取 BiliUI 的
  `BiliAvatarImageSize`（卡片头像的缩略框与管线的头像解码上限同源）；表情与预览请求原图。预览先显示列表里已缓存的缩小图并标出原图加载中，原图到达后原位替换，原图失败时保留缩小图并提供重试。
- 评论图片预览右上角的「保存图片」（⌘S）由窗口级的 `NativeCommentImageSaver` 拥有：保存面板以 sheet 挂在
  预览自己的窗口上，选好位置后再取原图在后台原样写入；已确认的保存不随预览关闭而丢失，关窗时取消。
- 评论动图：管线按解码出的帧数判断（接口没有可靠的动图标记），列表格子拿到图床转出的动态 WebP，预览拿到
  原图；`NativeAnimatedImagePlayback` 用 ImageIO 边解码边播放，不预先解出所有帧，始终无限循环。只在宿主
  真正可见时播放（在窗口里、没被隐藏、可见区域非空、窗口没被遮住、系统没开「减少动态效果」），每帧检查
  一次，停下时换回第一帧；停下后监听滚动、窗口遮挡与辅助功能设置变化，宿主布局完成时也重新判断。动图数据
  是引用类型，同一张图重新配置时继续播放。列表格子角上显示自绘的 GIF 角标；预览里缩小图占位不播放，逐帧
  只替换图片内容，不改尺寸与缩放状态。正文里的动态表情不在此列。
- 评论图片预览的图片区是 AppKit `NSScrollView`（`NativeCommentImageZoomView`）：SwiftUI 没有现成的
  “触控板双指缩放 + 两指平移 + 回弹”容器。倍率以适配可视区为 1，上限与单击倍率在
  `NativeCommentImageZoomGeometry`；单击图片（双击只算一次、两指双击同样）在适配与放大之间切换，放大后
  可拖动平移，拖动超过阈值不算单击；指针用系统放大镜（`NSCursor.zoomIn`／`zoomOut`），读屏用自定义操作
  切换。点图片四周空白或背景关闭；关闭手势只挂在背景上，挂在外层容器会让点图片同时关闭。图片区不接收
  键盘焦点，方向键照旧翻页；换图回到适配，同一张从缩小图换成原图、改窗口大小时保留缩放与可视位置。

### 播放页布局

- 主区固定不滚动：视频取剩余空间里最大的 16:9，下方是固定高度的相关推荐横排；真实页面与加载骨架
  共用 `PlaybackDetailLayout`，横排几何只在 BiliUI `VideoCardShelfGeometry`。布局交给 SwiftUI，
  不测量 frame。标题与数据是工具栏标题／副标题，弹幕设置在工具栏弹出面板，简介、选集与评论在侧栏。
- 骨架与内容切换只在外层交叉淡化，`PlaybackDetailLayout` 内部整体不参与动画：新建的 AppKit 视图
  （播放器、推荐横排）会随布局动画从初始 frame 移到最终位置，看起来像“飞入”。
- 横排自己延伸到侧栏下：`NSScrollView.automaticallyAdjustsContentInsets` 让内容伸进侧栏下方而首卡
  仍对齐。不用 SwiftUI 纵向 `ScrollView` 承载详情：它延伸进安全区后不再向内容传递横向安全区，
  横向内容边距也不含安全区，只能靠测量 frame 模拟。
- 播放页压在 NavigationStack 根（来源页）之上，根页面为保留状态仍在渲染；macOS 不为压栈页面绘制
  底色，播放页必须自铺不透明窗口背景并延伸到工具栏与侧栏下，不寄托在某个子视图顺带画出的背景上。
- F 键切换 AVKit 全屏，与控制条全屏按钮同一路径。AVKit 没有公开进入／退出全屏的方法，
  `enterFullScreen:`／`exitFullScreen:` 是唯一允许使用的私有 AVKit 接口：调用前确认响应，系统移除后
  F 键静默无效、全屏按钮不受影响；是否全屏由公开的 `AVPlayerViewDelegate` 回调记录，不读私有状态。
- 加载转圈分三处衔接：首次打开、详情未到时是骨架上的转圈；已有详情页面而 player 还没挂上 item 时
  （换视频、切分 P 的请求期间，以及准备播放时桥接读取索引、等字幕目录）由播放器浮层画同款转圈；
  item 挂上到就绪之间由 AVKit 自己的转圈接手。AVKit 只在“有 item 且未就绪”时画转圈，不受
  `controlsStyle` 影响，没有 item 时只是黑屏，开播后缓冲卡住也不画。
- 开播后缓冲卡住由浮层转圈：只认 AVPlayer 为减少卡顿而等待（`toMinimizeStalls`），开播与
  seek 时的短暂评估等待不算；卡住持续 `PlayerStallPolicy.presentationDelay` 才呈现，恢复播放立即撤下。
- 播放器上的滚轮不再拦截，交给 AVKit 原生处理。键盘快捷键以 content overlay 中弹幕层所在窗口为准；
  AVKit detached 全屏只携带 content overlay，锚点必须是其中的视图。
- 播放态侧栏替换导航侧栏，不另开右侧 inspector：播放期间导航使用率低，双栏把宽度留给视频。两种状态
  共用一列，`ideal` 只在首次布局生效，切换时宽度被夹进新范围，进入播放时即为播放态最小宽度。

### 动线与侧栏上下文层

- 平级来源（搜索、首页、热门、稍后再看、观看历史、收藏夹）以 `AppTab` 为 id，各由一份 `AppSourceDescriptor` 描述：标题、SF Symbol、
  所属侧栏分组、在侧栏提供多行时的选中读写、是否要求账户、内容整体替换的代次（推荐、热门与搜索只计原地刷新，稍后再看与观看历史含首次加载，
  收藏夹计每次整体替换）、离开来源时的停用、账户变化的通知、绑定本来源的复核参与者与丢弃内容的 reset。`AppSources` 由 `WindowComposition` 对
  `AppTab.allCases` 穷尽构造一次，每个来源必须给出所属的组。侧栏按 `AppSourceGroup` 分段（`Section`）：顶部不带标题的一组（搜索、
  首页、热门）、带标题的「资料库」（稍后再看、观看历史）与可折叠的「收藏夹」；组的顺序由 `AppSourceGroup` 固定，组内按 case 顺序。分组只决定
  侧栏的分段、标题、折叠与未登录时是否显示，不改变来源的停用、账户与清理语义。
- 「收藏夹」组只在已登录时显示，由一个来源（`.favorites`）为每个自己创建的收藏夹提供一行（Apple Music「播放列表」式），
  点一行直接在右侧显示夹内视频，不进右侧栈。侧栏 `List` 的选择值是 `AppSidebarSelection`：单行来源是 `.source(AppTab)`，
  收藏夹的行是 `.item(.favorites, id:)`，每行带不同的 tag，避免多行同时高亮、键盘上下错乱；选中的收藏夹记在收藏夹模型里，
  读写经来源描述的 `itemSelection` 映射，进入、退出播放重建侧栏后照样恢复高亮。组的展开状态只在窗口内存（`AppShellView`
  的 `@State`，导航侧栏重建不丢失），默认展开、不持久化，组标题不可选中。列表加载中、失败（可重试按钮）与账户 mid 未知
  （需复核或重新登录）各显示一行说明，说明行不可选中；已有列表时重读保留原有的行，直到新列表到达（普通失败保留旧列表，凭据
  失败放弃）。没有选中收藏夹时主区按列表状态说明（加载中、可重试的失败、账户未知、请在侧栏选择），工具栏刷新重读列表。列表重新加载后选中的收藏夹不在了就回落到默认收藏夹（按 `attr` 标记
  识别），没有则第一个；不在收藏夹时只改选择、不读取。在收藏夹时登出（组不再显示）回到首页，换号仍留在收藏夹并选新账户的
  默认收藏夹。侧栏行、
  刷新回顶、离开停用、账户变化、关窗清理与其他窗口换号时的提前清理（只对要求账户的来源）都遍历它。来源描述的 reset 只丢弃
  本来源自己的内容，推荐、热门与搜索共用的 Browse 工作集关窗时由 `AppSources` 整体丢弃一次。根视图构造与 Browse
  激活依赖各来源自己的类型，仍是 `AppTab` 上的穷尽 switch。
- 右侧栈深最多 1：来源页之上最多一层播放页，换视频只替换当前视频。新页面先判断属于哪一类：与首页、
  热门平级的来源进导航侧栏；围绕当前视频的浏览（UP 主空间）作为侧栏上下文层，不新增右侧压栈层级。
- 侧栏 = 底层（导航或播放详情）+ 可选的上下文层，两层并列叠放、各自按安全区布局。上下文层打开时，
  底层保留状态（关闭后评论位置还在），但必须真正隐藏：AppKit 底层设 `isHidden`，只设 SwiftUI 透明度
  与 hit testing 管不到 cursor rect 和 tracking area。进出动画只作用于上下文层，底层立即隐藏，
  否则底层集合视图的布局变化也会被做成动画。
- 上下文层的打开（播放侧栏 UP 主行、评论作者、空间链接）与关闭都经 `AppNavigationCoordinator`，是否打开从
  空间模型的 `owner` 派生（空间自己的返回按钮与账户会话切换时的关闭同样反映出来）。关闭规则按“从哪里打开”
  判断：在上下文层里选的视频保留它；来源页、相关推荐、选集、评论链接等其他入口换视频，或关闭播放（返回、
  切换来源、登出、换号）时关闭。不比较新视频的 UP 主：联合投稿的 UP 主字段可能是另一位。
- UP 主空间只在登录后可用（匿名请求会被间歇风控，见 `SECURITY-MODEL.md`），从播放侧栏的 UP 主行或
  评论作者（头像与昵称，含楼中楼）进入，两处共用限定区域的点击与手形指针（`NativeClickRegion`），
  VoiceOver 通过昵称上的自定义操作进入；评论正文里的 @ 提及同样在应用内打开空间（@ 用户的昵称与头像
  来自评论接口的 `members`），未登录时空间层显示登录提示。正文里的空间链接只有 MID：空间先以 UID
  作头部打开，`/x/web-interface/card` 名片到达后补上名字与头像。按页替换，底部悬浮页码条翻页与跳页，
  不做无限流。
- 评论正文链接（`jump_url`；`pc_url` 为空时用正文里作键的网址，b23.tv 短链就是这种形状）由 BiliAPI
  分类：桌面版、手机版与裸域的视频地址（BV 号，或在本地换算的 av 号）在应用内播放，链接里的 `p` 作为分 P 序号偏好（超出范围按默认分 P，命中时续播该分 P 的上次
  位置）；空间主页与投稿列表链接在侧栏空间层打开，合集、收藏夹等其他空间子页面应用内没有对应页面，
  交给浏览器；搜索词链接（`is_word_search`）不生成链接，因为跳到搜索页会离开播放；站内目标按未解码的
  host 与 path 精确匹配、不带端口，其余 HTTPS 地址交给系统浏览器。指向正在播放的视频时，带分 P 的
  链接就地切换分 P，不带或超出范围的保持当前播放。
- 接口链接带 `title` 时，站内目标（视频、空间、短链）的正文原文显示为标题；站外链接保留真实网址，
  点击前能看到域名。`prefix_icon` 作为前置小图标与表情走同一套附件加载（先占位、失败去掉、重新测量），
  在固定边长的正方形里按原比例绘制；标题与图标都带同一个链接，点图标经附件点击回调走同一条打开路径。
  与表情重叠的链接不替换，表情优先。读屏读渲染后的文字：链接读标题、表情保留原文写法。
  `match_once` 只链接第一处，其余同文出现由正文识别处理。正文自己识别的链接没有标题，保持原文。
- 接口没标出的纯文字由 BiliAPI 的 `CommentTextLinkDetector` 识别，结果走同一分类：网址（只取 ASCII
  字符，不含 `[` `]`，所以紧跟的中文与表情不算进来，末尾句读与不成对的右括号剔除）、不带协议头的
  b23.tv、BV 号与至少 5 位数字的 av 号（`AV1` 编码这类短写法不算）。`http` 网址只在指向站内目标时
  升级为 HTTPS，通不过公开 HTTPS 复核的外链不显示为链接；网址整段先占位，里面的片段不再单独识别；
  接口链接与表情覆盖的文字不再识别。
- 时间跳转：正文时间戳（`m:ss`、`h:mm:ss`，前后紧挨字母或数字、全角冒号都不认）与视频链接的 `t`
  （只认正整数秒）都在当前视频里跳转并播放。可跳转范围只由 `VideoContext.seekableDurationSeconds`
  决定（充电试看取试看时长）：时间戳只在播放器就绪且在范围内时显示为链接，切换分 P 时只重新配置含
  时间戳的评论（行高不变）；点击后由 Composition 的 `seekPlayback` 校验播放器 item 仍属该视频再跳转。
  `t` 指向正在播放的分 P 时原地跳转，不经导航去重；指向别的分 P 或视频时作为起播位置传给播放器
  （只有 DASH 采用，progressive 从头播），优先于续播位置、不显示续播提示，超出范围时忽略。链接起播
  时间开播成功后即用过，之后的重试由视频模型按续播规则处理，不跳回链接时间。
- b23.tv 短链在点击后由 BiliAPI 的 `BiliShortLinkResolver` 读一次跳转目标，再走同一分类；Composition 的
  `CommentLinkRouting` 是链接目标到 App 路由（`CommentLinkRoute`）的唯一翻译处，路由只由 `Navigation/` 的
  `CommentLinkOpener` 执行（系统打开网址经注入的 `OpenURLAction`），在途解析由窗口级
  `CommentShortLinkResolution` 拥有，评论所属视频变化或关窗时取消，解析不出时打开原短链。
- 视频简介与评论正文共用同一套链接目标、识别、路由与时间戳规则。正文按 `desc_v2` 分段拼出：@ 段
  （`type` 2，`raw_text` 不带 @）按官方显示为「@昵称 」（后跟一个空格，拼出的正文与 `desc` 逐字一致），
  `biz_id` 为正整数 MID 时标为 @ 用户、在应用内打开空间，没有头像时空间头部先显示占位；
  分段缺失、形状不对或任一段解码失败时整体退回 `desc`。其余文字由 `CommentTextLinkDetector` 识别。
  简介链接只改颜色、不改字形，测量仍用纯文字；链接属性的编码、点击解码与时间戳可跳转判断只在
  `NativePlaybackTextLinks` 一处，分 P 时长变化时只有含时间戳的简介重新配置。

### 搜索起始页

- 未提交搜索时，搜索页主区显示 `SearchStartView`：本机搜索历史与 B 站热搜。点选任一词等同于填入
  搜索框后提交，历史在 `VideoSearchSession.submit()` 里统一写入。草稿、排序与筛选、已提交的条件都在每个窗口
  一份的 `VideoSearchSession`（Browse），清空草稿即撤回提交、回到起始页；工具栏搜索框与筛选控件的宿主在 App，
  只绑定会话状态。
- 搜索历史由 App 的进程级 `SearchHistoryStore` 持有（`ProcessComposition` 创建，所有窗口共享），Feature
  只经 `SearchStartPageContext` 接收读取闭包与删除、清除回调；读取闭包只在起始页里求值，历史变化不让搜索页
  其余部分与工具栏重算。写入经 `VideoSearchSession` 在每次提交时调用注入的写入闭包。持久化规则见
  `SECURITY-MODEL.md` §6。
- 热搜由每个窗口一个 `TrendingSearchViewModel` 持有，起始页每次出现时刷新；port 独立于
  `FeedRepository`。首次加载失败只在热搜区显示错误与重试，刷新失败保留已显示的结果。图标地址在 BiliAPI 映射时经 `BiliBFSImageURLPolicy` 校验，Feature 经自己的
  `TrendingSearchIconLoading` port 取图，实现是窗口图片管线（请求与响应校验仍只在管线里），Feature 不接触
  图片管线本身。
- 工具栏正中的搜索框是 AppKit `NSSearchField`（`ToolbarSearchField`），挂系统联想菜单
  （`NSTextSuggestionsDelegate`，macOS 15 起）。SwiftUI `.searchable` 放在工具栏正中时不显示
  `.searchSuggestions`，系统联想菜单只能挂在 AppKit 文本框上；Apple Music 的居中搜索框也是这一做法。
- 联想菜单分两区：“搜索历史”最多 3 条包含当前输入的本机历史词，立即作为中间结果给出；“搜索联想”是
  B 站联想，去掉已在历史区的词，停顿后作为最终结果补上（规则在 `SearchSuggestionPolicy`）。选中联想
  只回调一次 `didSelect`，与点选起始页的词走同一条搜索路径；直接回车照常提交。
- 联想 port 独立于 `FeedRepository`；接口没有联想时以状态码 3 回复，BiliAPI 映射为空列表。搜索词按
  `URLQueryUnreservedEncoding` 编码，与 WBI 签名一致（`queryItems` 会保留 `+`，被服务端当成空格）。
- 搜索框只把外部改动（点选词、关窗清空）写回字段，且在输入法组字时不写：直接赋值会丢掉未确认的
  拼音或假名。

### 稍后再看的排序、筛选与搜索

- 条件（排序、观看进度、加入时间、时长与关键词）在每个窗口一份的 `WatchLaterSession`（Library），只在内存里，
  `reset`（关窗）与账户范围变化恢复默认，工具栏刷新也经会话。游标是完整请求（条件加页码），条件变化以新条件的第一页从空列表重新加载
  （不原地刷新：旧条件的条目不能留在新条件下显示），成功后刷新代次前进、网格回顶；旧条件的迟到结果由 `LatestTask`
  丢弃，旧条件的下一页游标与新列表不等而被 `PagedVideoList` 拒收。
- 番剧／影视、课程与已失效的条目本来就打不开，接口常给不全：这些行缺标题、作者、加入时间或时长时留空（卡片用
  占位标题，省略作者、头像、时长与加入时间，读屏不读空的部分），不让整页失败；可播放的行仍严格校验。
- 会话保存未解析的加入时间选项；每次开始新的分页会话（首次加载、应用条件、刷新、复核后重载）时由列表的
  `firstPageCursor` 按此刻与本地日历重新解析（`WatchLaterAddedTimeRangeResolver`），翻页沿用游标里冻结的区间；
  刷新时解析出的请求与当前内容不同（如跨过午夜）就清空重载，相同则原地刷新。今天为今天 0 点到明天 0 点，昨天为
  昨天整日，近一周为现在往前 7 天到明天 0 点，自定义为开始日 0 点到结束日次日 0 点；结束取明天 0 点，午夜不会得到
  空区间，解析后才加入的视频刷新时也在区间内。语义与搜索的发布日期（整日闭区间、结束日不晚于今天）不同，两者
  不共用解析；早于 1970 年与空区间的拒绝规则共用 `DateRangeFilterValidation`（`DateRangeFilterError`），两处弹窗据此
  显示原因并禁用“应用”，日期选择器以 1970-01-01 为下界。时长四档 `VideoDurationFilter` 与搜索共用，秒数边界只在
  `secondsRange`。
- 工具栏：排序菜单、筛选按钮、刷新依次在 primaryAction 同一组；搜索框是系统 `.searchable` 在工具栏尾部的紧凑
  搜索框（回车提交、清空恢复全部），不占工具栏正中的全局搜索位置。排序菜单、筛选按钮（草稿在“应用”前不生效）、
  弹窗外壳由 App 的 `ToolbarFilterControls` 与搜索共用，时长档标题与日期筛选的错误文案在 `SearchToolbarControls` 一处。副标题是当前条件下接口给的总数；有筛选或
  关键词而结果为空时空态给出“清除筛选”（清除筛选与关键词，保留排序）。

### 收藏夹的排序与搜索

- 选中的收藏夹、排序（最近收藏 `mtime` 默认、最多播放 `view`、最近投稿 `pubtime`）与关键词在每个窗口一份的
  `FavoriteFolderViewModel`，只在内存里，`reset`（关窗）与账户范围变化恢复默认。换夹时取消在途请求、回到第 1 页、清空
  关键词、保留排序。工具栏从左到右是排序菜单（与搜索、稍后再看共用 `ToolbarSortMenu`）、刷新与尾部的紧凑 `.searchable`
  搜索框（只搜当前收藏夹 `type=0`，回车提交、清空恢复）；不做“全部收藏夹”搜索与分区筛选。导航标题是收藏夹名称，副标题是
  当前条件下的总数（有关键词时是过滤后的数量）。整个收藏夹为空、搜索无结果（给“清除搜索”）与某页没有可显示的视频是三种
  不同的空态。
- 只有 type 2 的普通视频（含 `attr` bit7 仅自己可见）可以播放；合集（type 21）、音频（type 12）、番剧／影视（`ogv` 非空，
  角标用 `ogv.type_name`，空时写“番剧”）、其他未知类型与已失效（`attr` bit0，或标题为“已失效视频”“该合集已失效”；失效优先）
  是不可用卡片。不可用原因的角标与占位标题与稍后再看共用 `LibraryUnavailabilityFormatting`；不可用条目字段不全时放宽，
  普通视频严格校验。

### 认证

Web QR 协议没有官方稳定文档，按“fixture 固定的外部观察”处理，未知状态一律失败关闭。秘密只在
`BiliAuth`；Application 只暴露非秘密认证状态与 `AuthenticationServicing`，二维码图像走
`BiliAuthFeature` 定义的窄 Presentation port 注入。`BiliAPIClient` 的请求 builder（`RequestAccess`
与请求管线）只在 `BiliAPI` 内部可见，由同 actor 的各域 endpoint 扩展逐请求选择匿名或账户读取；
Repository adapter 只调用 endpoint 方法，不自行构造 `RequestAccess`。授权器由 Composition 注入。
唯一写能力是观看进度 heartbeat。具体边界见
[`SECURITY-MODEL.md`](SECURITY-MODEL.md)。

窗口复核契约：凭据失效只由 ViewModel 记录。参与者实现 BiliApplication 的 `@MainActor` 协议
`AccountRevalidationParticipant`（推荐／热门／搜索、视频、弹幕、评论、UP 主空间、稍后再看、观看历史、收藏夹列表与夹内页面；字幕目录由
`SubtitleUseCase` 报告给视频模型，播放侧仍把失败的目录当作没有字幕）：发现需要复核的失败时以 `&+=` 递增
`authenticationRevalidationGeneration`，复核结束的 `authenticationRevalidationSucceeded`／`Failed` 默认不动作。
参与者集合 `AccountRevalidationParticipants` 由 `WindowComposition` 构造一次，`AppRootView` 只读取各参与者的代次，前后
不等（不比大小，回绕仍算）就调用一次 `revalidate()`；复核离开 restoring 时把结果交给参与者，绑定来源的参与者
只在该来源是当前来源时收到（绑定关系只来自来源描述）（稍后再看、观看历史与收藏夹的夹内页面：复核成功后自动重载至多一次、失败时给可重试说明），
不在本页时不在后台读取账户内容。收藏夹列表是例外：它是侧栏常驻的元数据（名称、私密、默认），按窗口级（不绑定来源）登记，
窗口已登录就读取、复核结果不论当前来源都交给它；首次读取由导航侧栏出现时按窗口账户范围触发（未解析到已登录不算账户
变化），mid 只取自窗口账户范围（`AccountSessionScope.signedIn(accountID:)`），adapter 不自己取账户；认证仍在确认、或其他窗口
换号而本窗口还没复核到（`AccountSessionCoordinator.awaitsRevalidation`）时不读取，外部复核结束后重新对齐。夹内视频仍绑定收藏夹来源。
Feature 不直接调用认证服务，也不经单独回调。heartbeat 写请求例外，不触发复核。

多窗口共享一个 App 级账户 session coordinator：窗口出现后注册其 API transport，登出／换号／凭据
失效时先全局推进 authentication epoch，其他窗口再复核 Keychain 并按新 generation 重启依赖账户的
内容；窗口关闭时注销。账户变化由来源自己处理，App 只经来源描述通知（进程代次、窗口账户范围、是否当前来源）：
Browse 按代次去重，丢弃三份工作集并重启当前路由；关闭播放之后再通知稍后再看、观看历史与收藏夹：丢弃条目，已登录且是当前
来源时立即重载（收藏夹列表不论是否当前来源都按新账户重读，夹内页面在新列表到达后选默认收藏夹）。其他窗口
换号时，本窗口先丢弃要求账户的来源的内容再复核，复核结束后只通知不要求账户的来源，稍后再看、观看历史与收藏夹由复核得出的范围变化
重新加载。

### 播放线路偏好与测速

同一 fMP4 播放中换源会破坏字节一致性和单一播放器 owner，一次样本也不能代表未来视频，所以只做
显式选择：Settings 提供服务端默认、服务端原始 Akamai／bilivideo 与固定 bilivideo 镜像；每次新
load 只读一次，只调整视频候选。实验镜像只替换原始 bilivideo URL 的 host，保留签名；缺失时回退
服务端顺序。测速仅在已登录用户显式点击后运行，样本与路线严格串行、流量有硬上限、结果只存在于当前
Settings 窗口，从不自动改选。

### 响度均一化（macOS 27 起）

UGC playurl 带 `voice_balance=1` 时返回 loudness 元数据。macOS 27 起 Apple 官方支持对 HLS item 的
全部音轨混音挂 `MTAudioProcessingTap`：input parameters 用 `AVAudioMixInputParametersTrackMixID`，
tap 用 `MTAudioProcessingTapCreateWithPreferredFormat` 指定处理格式（未指定时格式未定义）。更早
系统不提供此功能，不依赖未文档化行为。默认关闭，新 load 读一次设置；旧版实验开关（可放大、仅
macOS 26）含义不同，用新的偏好键，不沿用。只有至少一条音轨需要压低时才安装 tap：处理格式固定为
48 kHz 立体声浮点（B 站 AAC 音轨均为立体声，多数为 44.1 kHz），不需要压低时不为此多一次重采样。

gain 只压低不放大：`min(−18 LUFS − I, 0)`，下限 −12 dB。不放大就不会超出原始峰值，所以没有峰值
余量项与限幅器；比目标安静的视频保持原样。−18 是按 B 站热门视频实测分布取的折中：多数视频被拉到
同一响度，整体压低幅度仍可用音量补回。

起播后按系统选中的音轨选项重算增益，只按语言与角色（原声／机器配音）匹配；`displayName` 是系统
本地化后的界面名称，不能用来匹配。语言优先取选项保留的原始标签（`extendedLanguageTag`），字面不同
时按 BCP 47 补全后比较。元数据缺失、音轨无法唯一映射或 tap 失败时保持 unity，播放不得
失败。B 站未测量响度的视频（多为较早上传）四个测量值都是 `0.001` 占位，按无效元数据处理、原音量播放；
不自行测量响度。实时回调只读固定内存／原子值，不分配、不加锁、不记日志。

### 分发

- Developer ID 站外 DMG + 公证，不走 Mac App Store；更新用 Sparkle 2.9.6 完整包 + Cloudflare 静态签名
  appcast，不自研更新器。
- 1.0.0 是最后一个 Universal 版本；此后 Release 主程序只含 `arm64`，Sparkle 官方嵌套组件保留其自带
  架构。不为旧 Intel 用户建立专用 feed。
- 只维护发布工具链 Xcode 27 一个版本，不保留按编译器版本分叉的代码。CI 在 macOS 27 上跑完整
  Gate；macOS 26／15 只启动同一 App 做冒烟：测试 bundle 依赖随 Xcode 发布的
  `Testing.framework`，旧 runner 上的 Xcode 加载不了 27 构建的 bundle，而 Xcode 27 不支持 macOS 15。
- 因此 macOS 15 只有“能启动并持续运行”的自动证据；AVFoundation、loopback 与窗口行为在最低系统上
  没有自动验证，deployment target 编译成功不能证明它们可用。
- Gate 构建的 App 不签名，测试宿主的身份每次构建都变。App 测试不读仓库源文件：仓库在外接卷上时，
  系统每次都会弹出访问授权，Gate 无法无人值守。字符串目录完整性这类源文件检查放在 static 阶段的
  脚本里（`Scripts/check-localization.py`），App 测试只检查构建产物。
- 字符串目录按位置发现：App 用 `BiliKitMac/Localizable.xcstrings`，经 `AppStrings` 或 SwiftUI 字面量
  （`Bundle.main`）查表；Package target 用 `Resources/Localizable.xcstrings`，经本 target 的
  `XxxFeatureStrings` 查表。脚本要求调用点的字面量 key 都在本 target 目录里、目录里的 key 都仍被
  使用：缺 key 运行期会静默回退中文源文，残留 key 让译文脱离代码。key 写成单行字面量，不动态拼接。
  Package 里未指定 bundle 的 SwiftUI 字面量会查 App 的 `Bundle.main`，非 ASCII 文案必须走本 target 的 helper。

## 不采用

- 每条评论或每张卡片嵌入 `NSHostingView`；`List`／`LazyVStack`／`LazyVGrid` 作为生产长列表容器。
- 第三方 DI、Coordinator 框架、Redux／TCA。
- 每个模块独立 `Package.swift`；为单一调用方新建 renderer／Shared target。
- Feature 直接观察 `AVPlayer`；字幕或弹幕独立 timer；弹幕放进 Feature 或在 `BiliDanmaku` 解码 wire。
- 弹幕自建动画时钟（按快照改 `rootLayer` 的速率与时间）或靠识别 seek 清屏、补位：时钟切换与误判的跳变
  都会闪，画面也依赖到达顺序；弹幕动画只由同步 layer 按 item 时间驱动。
- mpv 等第二播放后端；AVPlayer + loopback 能满足当前需求。
- `*.bilibili.com` 后缀匹配授权；WKWebView 登录；共享 `HTTPCookieStorage` 或 `URLSession.shared`
  作为登录态。
- 播放中自动换源、后台测速、按测速结果自动改选。
