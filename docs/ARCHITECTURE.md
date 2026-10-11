# BiliKit 架构

本文只记录当前模块边界和仍约束代码的决策。事实以 `Packages/BiliKitCore/Package.swift`、
`Scripts/check-architecture.sh` 和 Xcode 工程为准；安全规则见 [`SECURITY-MODEL.md`](SECURITY-MODEL.md)。

## 平台与命名

- Swift 6、SwiftUI + AppKit、AVPlayer；App、测试 target 与 Package 最低 macOS 15。
- 用户可见 App、构建产品与 Swift app module 为 `BiliKit`；仓库、Xcode 工程、内部 App target
  和 `BiliKitMacTests` 保留 `BiliKitMac`，与原 BiliKit userscript 仓库区分。
- Bundle ID `com.shiinayane.BiliKit`；Debug／Release 相同。Keychain access group 固定为
  `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`，更换 Team 或 Bundle ID 等于换一个
  Keychain 范围，旧登录态不迁移，也不得扩大 access group 去读取。

## 模块与依赖方向

仓库只有一个本地 Package `Packages/BiliKitCore`，以 target 作编译边界：

```text
BiliKit App（Composition Root、AppKit/AVKit 宿主、Sparkle）
 ├─ BiliBrowseFeature ─┐
 ├─ BiliLibraryFeature ┼─> BiliApplication ─> BiliModels
 ├─ BiliAuthFeature ───┘         ^ ports
 │    (Browse/Library ─> BiliUI ─> SwiftUI/Foundation)
 ├─ BiliAPI ──────┐
 ├─ BiliAuth ─────┼─> BiliApplication / BiliModels / BiliNetworking
 ├─ BiliPlayback ─┘
 └─ BiliDanmaku ─────> BiliApplication / BiliModels
BiliNetworking 不依赖任何 Bili 模块
```

| target | 拥有 | 不得依赖 |
| --- | --- | --- |
| `BiliModels` | 跨层稳定实体与值类型（视频、播放清单、字幕、弹幕、评论、账户投影） | 任何 Bili 模块、SwiftUI、AppKit、AVFoundation、Network |
| `BiliApplication` | Use Case、port（内容仓库、播放控制与时间轴、字幕、弹幕、评论、认证、观看进度）、应用级错误，以及 Feature 共用的 `package` 并发原语 `LatestTask` | 除 `BiliModels` 外的 Bili 模块、UI/播放/网络框架、DTO、Keychain、Cookie |
| `BiliNetworking` | 无业务语义的 HTTP client、Range client、`HTTPRequestAuthorizing`、URL 形状策略与 JSON 响应判定 | Bili 模块、`Security`、UI/播放框架 |
| `BiliAPI` | endpoint DTO、WBI、解码、protobuf wire、远端错误映射，并实现 Application 仓库 port | `BiliAuth`（只接受注入的授权器） |
| `BiliAuth` | Web QR 状态机、Cookie envelope、Keychain store、请求授权器，实现 `AuthenticationServicing` | `BiliAPI`、`BiliPlayback`、`BiliDanmaku`、Feature、UI 框架 |
| `BiliPlayback` | DASH→HLS bridge、loopback server、SIDX、`AVPlayerEngine`、线路偏好与测速、响度 tap | `BiliAPI`、`BiliAuth` |
| `BiliDanmaku` | 弹幕会话、按媒体时间调度、lane 分配、Core Animation renderer | `BiliAPI`、`BiliAuth`、`BiliNetworking`、`BiliPlayback`、Feature、SwiftUI |
| `Bili*Feature` | SwiftUI View 与 `@MainActor` ViewModel；Browse（Feed/Search/VideoDetail）、Library（History）、Auth | adapter target、其他 Feature、AppKit/AVKit/AVFoundation |
| `BiliUI` | Browse、Library 与 App 原生网格、播放器浮层共用、无业务语义的卡片几何、网格、骨架、加载过渡与时长格式化；默认 `package` 访问级别，App 直接使用的卡片几何、时长格式化与播放器加载转圈为 `public`，无 library product | 除 Foundation、SwiftUI 外的任何模块 |
| App `BiliKitMac` | composition root、导航协调、窗口 owner、`AVPlayerView` 宿主、原生网格／侧栏、Settings、Now Playing、Sparkle | `App/` 目录不直接 import adapter、Application 或平台框架，具体实现只在 `Composition/`、`Platform/`、`Settings/` 出现 |

补充规则：

- SwiftProtobuf 只允许 `BiliAPI` import；Sparkle 只允许 App target。
- Feature 之间不互相 import，跨域跳转由 App 层协调。
- ViewModel 拥有用户意图的 Task、取消与 generation；只有最新意图能写回 UI State，单一最新
  意图统一用 `LatestTask` 隔离，不各自手写。View 的 `.task(id:)` 只把生命周期意图交给 ViewModel。
- adapter 必须传播 `CancellationError`，不把取消折叠成网络失败。
- 新 target 需同时具备稳定独立领域、独立状态或安全／性能边界、真实调用方与测试；默认在现有
  target 内加子目录。不建立 `Common`／`Shared`／`Utils`，不建立空占位 target。
- `BiliUI` 只在出现至少两个真实调用方且语义稳定时才接收新组件；B 站主机、图片参数、计数和日期
  格式化留在拥有语义的 Feature。

## 关键决策

### 播放：DASH→HLS loopback bridge

`AVAssetResourceLoaderDelegate` 可以提供 playlist，但由它返回 fMP4 媒体分段时 `AVPlayerItem` 以
`CoreMediaErrorDomain -12881` 失败；AVFoundation 需要自己加载分段来执行自适应逻辑。因此
`BiliPlayback` 在进程内起一个最小 HTTP/1.1 server，只绑定 `127.0.0.1`、系统分配端口、随机
session path，提供内存中生成的 master／media playlist，并把 AVPlayer 的 Range 转发到 CDN。

- SIDX 成功的候选成为该 representation 的唯一远端来源，后续 init、media 与 Range 不跨来源拼字节；
  分段正文与 progressive 共用同一流式转发，逐 chunk 写入 loopback，不整段缓存；同一 bridge 的
  各播放会话共用一个 Range 会话以复用 CDN 连接，server 停止只取消自己的在途请求。
- 上游响应必须通过状态码、`Content-Range`、长度校验；取消不触发备用线路。
- 只有全部 SIDX reference 从 type-1 SAP 开始且 `SAP_delta_time` 为 0 时才发布 I-frame rendition，
  它复用同一 route 的完整 fragment Range，不预读、不缓存。
- 同一 AUDIO group 以原声 SIDX 起点为准；起点不一致的 AI 音轨在生成 master 前丢弃。
- 没有 DASH 但有安全单段 `durl` 时注册 progressive MP4 route：原样保留 AVPlayer 的单一 Range，
  验证后逐 chunk 写入 loopback，不累积整段；不支持多段 `durl` 拼接。
- `AVPlayerEngine` 是 `AVPlayerItem`、loopback server、原生字幕 route 的唯一 owner；替换、停止或
  释放时关闭 server 并取消连接与上游 Task。不使用私有 AVFoundation header 注入。

### 媒体时间轴

`BiliApplication.PlaybackTimelineProviding` 是弹幕、Now Playing 与观看进度的唯一时间来源，由
`BiliPlayback` 用 AVPlayer observation 实现，表达 item identity、位置、速率、状态和 discontinuity
generation。消费者不自建 wall-clock timer，也不接触 `AVPlayer`／`CMTime`／KVO；各自 timer 无法正确
表达卡顿、暂停、倍速和 seek。字幕作为原生 subtitle rendition 进入同一 `AVPlayerItem`，由系统字幕
菜单选择。

- 续播位置在 load 时写入 master playlist 的 `#EXT-X-START:TIME-OFFSET=…,PRECISE=YES`，item 就绪即
  精确位于该处，不再“先就绪、再内部 seek”：少一次 seek、少下载开头分段，也没有 seek 期间辨认
  time-jump 来源的竞态。`beginPlayback` 只按就绪位置报告续播或从头开始；“从头播放”仍是 seek 到 0。
- 时间轴与交互记录器在 item 开始时得知起播位置：就绪时据此标记一次 discontinuity，弹幕从起播位置
  排起；落在起播位置的系统 time-jump 不算用户操作，否则会拒绝自动开播。
- progressive 单文件（充电试看）没有 playlist，不续播，一律从头播放。

### 弹幕

- 分段是 protobuf。`BiliAPI` 以 exact 1.38.1 依赖 SwiftProtobuf（Apache 2.0 + runtime exception），
  `.proto` 自行编写，用同版本 `protoc-gen-swift` 显式生成并提交 `.pb.swift`，不挂 build plugin。
  手写 wire reader 要长期自维护 varint、未知字段和恶意长度边界，成本高于约 1.8 MiB 的体积。
- wire 类型解码后立即映射为 `BiliModels.DanmakuEvent`；`BiliDanmaku` 只见 Models/Application。
- renderer 使用 Core Animation layer 与纹理缓存，调度与 lane 分配可用虚拟时间独立测试。

### 原生 AppKit 集合视图

- **播放侧栏**：上传者、简介、选集／分 P、评论与分页 footer 由一个 `NSScrollView + NSCollectionView`
  拥有，全部是原生 item。真实长评论下 `ScrollView + LazyVStack` 产生不收敛的 SwiftUI
  transaction／AttributeGraph 工作；逐行 `NSHostingView` + `fittingSize` 会把全表重测放大到秒级。
  正文使用可选择、不可编辑的 `NSTextView`；diffable identity 为 subject + root `CommentID`；
  高度缓存按 identity、宽度桶、内容 revision 做有界 LRU，resize 分批精测并恢复语义 anchor。
  `PlaybackCommentsViewModel` 仍唯一拥有 subject、排序、分页、并发上限与 generation。
- **浏览网格与 shelf**：首页推荐、热门、搜索、历史的网格和相关推荐 shelf 使用
  `NSCollectionView` + 复用的原生卡片。热门 50 卡 A/B 表明 SwiftUI `LazyVGrid`/AttributeGraph
  是主要滚动成本；卡片 overlay 与文字改为持久 `CALayer`／`CATextLayer` 后，同样约 20 秒滚动
  cycles 下降约 39%，0 hitch。SwiftUI Feature 保留 loading／empty／failure 等状态所有权。
- **UP 主空间列表**：头部（返回、头像、名字、三段排序）与投稿行是同一个 `NSCollectionView` 的原生
  item，随列表滚到工具栏下由系统做边缘模糊。行高固定，不需要测量缓存；加载、空、失败与登录提示
  由 SwiftUI 叠在头部下方，返回按钮始终可点。加载用转圈而不是骨架：投稿数因人而异，占位行会误导数量。
  列表不接收键盘焦点，方向键、空格留给播放器快捷键。
  悬停由 `NativeVideoHoverTracker` 统一管理（网格卡片与投稿行都实现 `NativeHoverableCollectionItem`）；
  “返回顶部”玻璃按钮与评论区共用 `NativeScrollToTopScrollView`。
- 封面、头像与评论图片由 `AppWindowOwner` 持有的窗口级匿名、有界 `NativeVideoImagePipeline`
  加载（Now Playing 封面另有进程级实例）；cell 离屏、复用和 teardown 取消等待者。

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

- 右侧栈深最多 1：来源页之上最多一层播放页，换视频只替换当前视频。新页面先判断属于哪一类：与首页、
  热门平级的来源进导航侧栏；围绕当前视频的浏览（UP 主空间）作为侧栏上下文层，不新增右侧压栈层级。
- 侧栏 = 底层（导航或播放详情）+ 可选的上下文层，两层并列叠放、各自按安全区布局。上下文层打开时，
  底层保留状态（关闭后评论位置还在），但必须真正隐藏：AppKit 底层设 `isHidden`，只设 SwiftUI 透明度
  与 hit testing 管不到 cursor rect 和 tracking area。进出动画只作用于上下文层，底层立即隐藏，
  否则底层集合视图的布局变化也会被做成动画。
- 关闭规则按“从哪里打开”判断，由 `AppNavigationCoordinator` 统一执行：在上下文层里选的视频保留它；
  来源页、相关推荐、选集、评论链接等其他入口换视频，或关闭播放（返回、切换来源、登出、换号）时关闭。
  不比较新视频的 UP 主：联合投稿的 UP 主字段可能是另一位。
- UP 主空间只在登录后可用（匿名请求会被间歇风控，见 `SECURITY-MODEL.md`），从播放侧栏的 UP 主行或
  评论作者（头像与昵称，含楼中楼）进入，两处共用限定区域的点击与手形指针（`NativeClickRegion`），
  VoiceOver 通过昵称上的自定义操作进入；评论正文里的 @ 提及同样在应用内打开空间（@ 用户的昵称与头像
  来自评论接口的 `members`），未登录时空间层显示登录提示。按页替换，底部悬浮页码条翻页与跳页，不做
  无限流。

### 搜索起始页

- 未提交搜索时，搜索页主区显示 `SearchStartView`：本机搜索历史与 B 站热搜。点选任一词等同于填入
  搜索框后提交，历史在 `performSearch()` 里统一写入。
- 搜索历史由 App 的进程级 `SearchHistoryStore` 持有（`BiliKitMacApp` 创建，所有窗口共享），Feature
  只接收词列表与删除、清除回调；持久化规则见 `SECURITY-MODEL.md` §6。
- 热搜由每个窗口一个 `TrendingSearchViewModel` 持有，起始页每次出现时刷新；port 独立于
  `FeedRepository`。首次加载失败只在热搜区显示错误与重试，刷新失败保留已显示的结果。图标地址在 BiliAPI 映射时经 `BiliBFSImageURLPolicy` 校验，由 App 注入的视图走
  窗口图片管线加载，Feature 不接触图片管线。

### 认证

Web QR 协议没有官方稳定文档，按“fixture 固定的外部观察”处理，未知状态一律失败关闭。秘密只在
`BiliAuth`；Application 只暴露非秘密认证状态与 `AuthenticationServicing`，二维码图像走
`BiliAuthFeature` 定义的窄 Presentation port 注入。`BiliAPIClient` 的请求 builder（`RequestAccess`
与请求管线）只在 `BiliAPI` 内部可见，由同 actor 的各域 endpoint 扩展逐请求选择匿名或账户读取；
Repository adapter 只调用 endpoint 方法，不自行构造 `RequestAccess`。授权器由 Composition 注入。
唯一写能力是观看进度 heartbeat。具体边界见
[`SECURITY-MODEL.md`](SECURITY-MODEL.md)。

多窗口共享一个 App 级账户 session coordinator：窗口出现后注册其 API transport，登出／换号／凭据
失效时先全局推进 authentication epoch，其他窗口再复核 Keychain 并按新 generation 重启依赖账户的
内容；窗口关闭时注销。

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
失败。实时回调只读固定内存／原子值，不分配、不加锁、不记日志。

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

## 不采用

- 每条评论或每张卡片嵌入 `NSHostingView`；`List`／`LazyVStack`／`LazyVGrid` 作为生产长列表容器。
- 第三方 DI、Coordinator 框架、Redux／TCA。
- 每个模块独立 `Package.swift`；为单一调用方新建 renderer／Shared target。
- Feature 直接观察 `AVPlayer`；字幕或弹幕独立 timer；弹幕放进 Feature 或在 `BiliDanmaku` 解码 wire。
- mpv 等第二播放后端；AVPlayer + loopback 能满足当前需求。
- `*.bilibili.com` 后缀匹配授权；WKWebView 登录；共享 `HTTPCookieStorage` 或 `URLSession.shared`
  作为登录态。
- 播放中自动换源、后台测速、按测速结果自动改选。
