import QuartzCore

/// 宿主视图向 renderer 提供的「下一显示帧」回调，由 App 的弹幕 overlay 用 display link 实现。
///
/// renderer 只在静止（速率为 0）且有改动时请求，用来强制窗口重新合成，见
/// `CoreAnimationDanmakuRenderer.recompositeIfStill`；呈现端目前不再主动触发，这套机制留待实机确认
/// 没有残影后删除。宿主只在有请求时运行 display link，回调一次即停。
@MainActor
public protocol DanmakuFrameScheduling: AnyObject {
    /// 请求在下一显示帧回调一次 `handler`，参数为 true；视图不可见（不在窗口里、隐藏、最小化或被完全
    /// 遮挡）时返回 false，不会回调。
    ///
    /// 宿主停止 display link（离开窗口、变为不可见、交还 surface）或调用方取消时，未回调的请求以 false
    /// 回调。display link 可能一直不出帧（例如显示器休眠），调用方要自备时限并在到点时取消。
    func requestNextFrame(_ handler: @escaping @MainActor (Bool) -> Void) -> Bool
    /// 取消全部未回调的请求并停止 display link；未回调的请求以 false 回调。
    func cancelNextFrameRequests()
}
