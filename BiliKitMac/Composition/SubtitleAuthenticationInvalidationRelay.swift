import Synchronization

/// 把字幕目录发现的凭据失效转给本窗口的视频模型。
///
/// AsyncStream 只能有一个消费者：每次 `makeStream()` 都建新的 stream，只有最新的一条接到字幕回调，
/// 旧的随之结束，因此重复创建视频模型不会出现两个消费者同时等待同一个 stream。
final class SubtitleAuthenticationInvalidationRelay: Sendable {
    private let continuation = Mutex<AsyncStream<Void>.Continuation?>(nil)

    func report() {
        continuation.withLock { $0 }?.yield()
    }

    func makeStream() -> AsyncStream<Void> {
        let (stream, newContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let previous = continuation.withLock { current in
            defer { current = newContinuation }
            return current
        }
        previous?.finish()
        return stream
    }
}
