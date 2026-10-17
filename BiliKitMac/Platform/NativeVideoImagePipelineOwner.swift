import Foundation

/// 管线的生命周期 owner：持有系统内存压力监听，shutdown 时先取消监听再关闭管线。
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
