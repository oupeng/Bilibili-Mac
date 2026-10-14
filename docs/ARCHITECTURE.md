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
- 强调色是资源目录的 `AccentColor`：B 站粉调深，浅色 `#E84B85`、深色 `#F25D8E`，让上面的白字仍可读。
  界面只通过系统强调色（`controlAccentColor`／`Color.accentColor`）取用；用户在系统设置里选了具体
  主题颜色时以系统为准。

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
  格式化留在拥有语义的 Feature；评论资源是不透明引用，其图片地址与缩略参数只由 BiliAPI 的 resolver
  生成。

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
  验证后逐 chunk 写入 loopback，不累积整段；不支持多段 `durl` 拼接。格式只接受 `mp4` 与 `hdmp4`
  （较早视频只有整段文件，最高 720P），`flv*` 不支持；请求的清晰度只有 FLV 时，按 `support_formats`
  里不高于请求的最高 MP4 清晰度重取一次。
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
- progressive 单文件（充电试看、没有 DASH 的较早视频）没有 playlist，不续播，一律从头播放。

### 弹幕

- 分段是 protobuf。`BiliAPI` 以 exact 1.38.1 依赖 SwiftProtobuf（Apache 2.0 + runtime exception），
  `.proto` 自行编写，用同版本 `protoc-gen-swift` 显式生成并提交 `.pb.swift`，不挂 build plugin。
  手写 wire reader 要长期自维护 varint、未知字段和恶意长度边界，成本高于约 1.8 MiB 的体积。
- wire 类型解码后立即映射为 `BiliModels.DanmakuEvent`；`BiliDanmaku` 只见 Models/Application。
- renderer 使用 Core Animation layer 与纹理缓存，调度与 lane 分配可用虚拟时间独立测试。
- 分段请求会被间歇风控（游客更常见），被拒的分段等 2 秒后由会话再请求一次（等待期间占一个加载名额）；
  其余失败与再次被拒的分段在当前视频内不再请求，换视频或重开会话才重来。
- 补位：seek、续播起点与时间回跳仍先清屏，播放中打开弹幕时从空屏开始；之后第一个播放中的快照补发回看窗口
  内本应仍在屏上的弹幕（暂停时 seek 等到继续播放才补）。窗口由 `DanmakuMotionPolicy.catchUpWindow` 按画面
  宽度与速度给出：顶部／底部 4 秒与“和画面等宽的滚动弹幕”跑完全程的时长取较大者。补位弹幕按自己的时间点做
  车道准入（准备按入队顺序完成，准入时间不倒退）；同批纹理全部准备好后一起上屏，已走过的时长按上屏时刻
  计算，renderer 把动画开始时间移到过去，从已走过的位置继续；等待期间已走完的丢弃，候选按车道数 × 重叠
  层数 × 4 取最新的。窗口跨进上一分段时一并请求上一分段，覆盖窗口的分段迟到时再补一次并按 ID 去重。切换
  弹幕类型显隐仍只清屏、不补位。
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
- **浏览网格与 shelf**：首页推荐、热门、搜索、历史的网格和相关推荐 shelf 使用
  `NSCollectionView` + 复用的原生卡片。热门 50 卡 A/B 表明 SwiftUI `LazyVGrid`/AttributeGraph
  是主要滚动成本；卡片 overlay 与文字改为持久 `CALayer`／`CATextLayer` 后，同样约 20 秒滚动
  cycles 下降约 39%，0 hitch。SwiftUI Feature 保留 loading／empty／failure 等状态所有权。
- 网格提前准备：AppKit 默认只为视野内创建卡片，封面要等卡片露出来才开始加载。网格的集合视图把准备区域
  设为视野上下各一屏（`prepareContent(in:)`），并在滚动、布局与内容更新时检查余量，不足半屏就主动刷新，
  同时存在的卡片约为三屏；离开准备区域的卡片照常复用并取消封面等待。键盘选择的起点与滚动锚点只取与
  视野相交的卡片，不取准备区域里看不见的卡片。视野底边离内容底部不足 1.5 屏时请求
  下一页；新一页到来时若仍在阈值内（一页可能比阈值矮）立即再布防，保持内容储备，仍是每个尾部一次、
  一次滚动手势最多一页。评论侧栏的阈值比一页矮，保留“先离开阈值再布防”。
- 首页推荐、热门、搜索与观看历史在已有内容时都原地刷新：网格不卸载，顶部显示共用的 `RefreshStatusCapsule`
  （BiliUI；结果为空时也显示），成功后整体替换并由刷新代次把该来源的网格滚回顶部；失败保留已显示内容并在
  胶囊里给出原因。刷新期间各来源都收起分页尾标，结束后重新给出：网格对同一尾标只触发一次，刷新中被忽略的
  近尾事件要靠尾标重新出现才能再布防。账户变化替换所有来源的内容，所有网格都回到顶部。
  历史只有登录失效时转入失败页，交给登录提示。首次加载仍是骨架屏。程序回到顶部后、用户再次滚动前，内容整体
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
  列表不接收键盘焦点，方向键、空格留给播放器快捷键。
  悬停由 `NativeVideoHoverTracker` 统一管理（网格卡片与投稿行都实现 `NativeHoverableCollectionItem`）；
  “返回顶部”玻璃按钮与评论区共用 `NativeScrollToTopScrollView`。
- 封面、头像与评论图片由 `AppWindowOwner` 持有的窗口级匿名、有界 `NativeVideoImagePipeline`
  加载（Now Playing 封面另有进程级实例）；cell 离屏、复用和 teardown 取消等待者。
- 评论列表图片与头像请求图床按框缩小的 WebP（`@{宽}w_{高}h.webp`，图床按比例缩进框内、不放大），框按
  用途只在 `NativePlaybackCommentAssetSizing` 定义：列表为最大显示尺寸的 2 倍，头像为解码上限；表情与
  预览请求原图。预览先显示列表里已缓存的缩小图并标出原图加载中，原图到达后原位替换，原图失败时保留缩小图并提供重试。
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
  `CommentLinkRouting` 是链接目标到 App 路由（`CommentLinkRoute`）的唯一翻译处，在途解析由窗口级
  `CommentShortLinkResolution` 拥有，评论所属视频变化或关窗时取消，解析不出时打开原短链。
- 视频简介与评论正文共用同一套链接目标、识别、路由与时间戳规则。正文按 `desc_v2` 分段拼出：@ 段
  （`type` 2，`raw_text` 不带 @）按官方显示为「@昵称 」（后跟一个空格，拼出的正文与 `desc` 逐字一致），
  `biz_id` 为正整数 MID 时标为 @ 用户、在应用内打开空间，没有头像时空间头部先显示占位；
  分段缺失、形状不对或任一段解码失败时整体退回 `desc`。其余文字由 `CommentTextLinkDetector` 识别。
  简介链接只改颜色、不改字形，测量仍用纯文字；链接属性的编码、点击解码与时间戳可跳转判断只在
  `NativePlaybackTextLinks` 一处，分 P 时长变化时只有含时间戳的简介重新配置。

### 搜索起始页

- 未提交搜索时，搜索页主区显示 `SearchStartView`：本机搜索历史与 B 站热搜。点选任一词等同于填入
  搜索框后提交，历史在 `performSearch()` 里统一写入。
- 搜索历史由 App 的进程级 `SearchHistoryStore` 持有（`BiliKitMacApp` 创建，所有窗口共享），Feature
  只接收词列表与删除、清除回调；持久化规则见 `SECURITY-MODEL.md` §6。
- 热搜由每个窗口一个 `TrendingSearchViewModel` 持有，起始页每次出现时刷新；port 独立于
  `FeedRepository`。首次加载失败只在热搜区显示错误与重试，刷新失败保留已显示的结果。图标地址在 BiliAPI 映射时经 `BiliBFSImageURLPolicy` 校验，由 App 注入的视图走
  窗口图片管线加载，Feature 不接触图片管线。
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

## 不采用

- 每条评论或每张卡片嵌入 `NSHostingView`；`List`／`LazyVStack`／`LazyVGrid` 作为生产长列表容器。
- 第三方 DI、Coordinator 框架、Redux／TCA。
- 每个模块独立 `Package.swift`；为单一调用方新建 renderer／Shared target。
- Feature 直接观察 `AVPlayer`；字幕或弹幕独立 timer；弹幕放进 Feature 或在 `BiliDanmaku` 解码 wire。
- mpv 等第二播放后端；AVPlayer + loopback 能满足当前需求。
- `*.bilibili.com` 后缀匹配授权；WKWebView 登录；共享 `HTTPCookieStorage` 或 `URLSession.shared`
  作为登录态。
- 播放中自动换源、后台测速、按测速结果自动改选。
