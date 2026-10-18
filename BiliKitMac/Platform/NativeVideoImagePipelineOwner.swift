import Foundation

/// 管线的生命周期 owner：持有系统内存压力监听，shutdown 时先取消监听再关闭管线。
///
/// 窗口级实例由 `WindowComposition` 持有并在关窗时 shutdown，Now Playing 封面实例由
/// `SystemNowPlayingController` 持有；deinit 兜底。内存压力事件在全局 utility 队列上清空缓存，
/// 管线状态由它自己的 `Mutex` 隔离。
final class NativeVideoImagePipelineOwner {
    let pipeline: NativeVideoImagePipeline
    private let memoryPressure: SystemMemoryPressureObserver

    init(cacheLimits: NativeVideoImageCacheLimits) {
        let pipeline = NativeVideoImagePipeline(cacheLimits: cacheLimits)
        self.pipeline = pipeline
        memoryPressure = SystemMemoryPressureObserver(
            queue: .global(qos: .utility)
        ) { [weak pipeline] in
            pipeline?.discardCachedImages()
        }
    }

    func shutdown() {
        memoryPressure.cancel()
        pipeline.shutdown()
    }

    deinit {
        shutdown()
    }
}
