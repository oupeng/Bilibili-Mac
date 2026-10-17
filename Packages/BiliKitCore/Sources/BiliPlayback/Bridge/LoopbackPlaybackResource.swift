import BiliNetworking
import Foundation

/// DASH 分段的远端来源：构造时校验媒体 CDN 来源与正长度，见 SECURITY-MODEL §4、§5。
public struct LoopbackRemoteResource: Sendable, Equatable {
    public let sourceURL: URL
    public let contentLength: Int64
    public let contentType: String
    public let headers: [String: String]

    public init(
        sourceURL: URL,
        contentLength: Int64,
        contentType: String,
        headers: [String: String] = [:]
    ) throws {
        guard BiliMediaCDNURLPolicy().allows(sourceURL) else {
            throw LoopbackPlaybackServerError.invalidRemoteSource
        }
        guard contentLength > 0 else {
            throw LoopbackPlaybackServerError.invalidContentLength(contentLength)
        }

        self.sourceURL = sourceURL
        self.contentLength = contentLength
        self.contentType = contentType
        self.headers = headers
    }
}

/// 单个 progressive item 的来源选择状态。
///
/// 首个通过响应头验证的完整 URL 会固定给后续 Range。
public final class LoopbackProgressiveResource: @unchecked Sendable, Equatable {
    public let candidateURLs: [URL]
    public let contentLength: Int64
    public let contentType: String
    public let allowedUpstreamContentTypes: Set<String>
    public let headers: [String: String]

    private let lock = NSLock()
    private var selectedSourceURL: URL?

    public init(
        candidateURLs: [URL],
        contentLength: Int64,
        contentType: String,
        allowsOctetStreamWithContainerEvidence: Bool,
        headers: [String: String] = [:]
    ) throws {
        let mediaURLPolicy = BiliMediaCDNURLPolicy()
        guard !candidateURLs.isEmpty,
            candidateURLs.allSatisfy(mediaURLPolicy.allows)
        else {
            throw LoopbackPlaybackServerError.invalidProgressiveSource
        }
        guard contentLength > 0 else {
            throw LoopbackPlaybackServerError.invalidContentLength(contentLength)
        }
        guard contentType.caseInsensitiveCompare("video/mp4") == .orderedSame else {
            throw LoopbackPlaybackServerError.invalidProgressiveSource
        }
        self.candidateURLs = candidateURLs
        self.contentLength = contentLength
        self.contentType = contentType.lowercased()
        var allowed = Set([self.contentType])
        if allowsOctetStreamWithContainerEvidence {
            allowed.insert("application/octet-stream")
        }
        allowedUpstreamContentTypes = allowed
        self.headers = headers.removingCredentialAndRangeHeaders()
    }

    public static func == (
        lhs: LoopbackProgressiveResource,
        rhs: LoopbackProgressiveResource
    ) -> Bool {
        lhs === rhs
    }

    var eligibleSourceURLs: [URL] {
        lock.withLock {
            selectedSourceURL.map { [$0] } ?? candidateURLs
        }
    }

    func select(_ url: URL) -> Bool {
        lock.withLock {
            if let selectedSourceURL {
                return selectedSourceURL == url
            }
            guard candidateURLs.contains(url) else { return false }
            selectedSourceURL = url
            return true
        }
    }
}

/// 生成资源的配置错误、生成正文长度不合规与重试次数用尽。
public enum LoopbackGeneratedResourceError: Error, Sendable, Equatable {
    case invalidMaximumContentLength(Int)
    case invalidMaximumLoadAttempts(Int)
    case invalidGeneratedContentLength(Int)
    case loadAttemptsExhausted
}

/// 首次请求时生成正文；成功后只缓存于当前 loopback 会话，失败可由后续请求重试。
public final class LoopbackGeneratedResource: @unchecked Sendable, Equatable {
    public let contentType: String

    private let lock = NSLock()
    private let maximumContentLength: Int
    private let loader: @Sendable () async throws -> Data
    private var generation: UInt64 = 0
    private var remainingLoadAttempts: Int
    private var invalidated = false
    private var cachedBody: Data?
    private var loadTask: Task<Data, any Error>?

    public init(
        contentType: String,
        maximumContentLength: Int,
        maximumLoadAttempts: Int = 2,
        loader: @escaping @Sendable () async throws -> Data
    ) throws {
        guard maximumContentLength > 0 else {
            throw LoopbackGeneratedResourceError.invalidMaximumContentLength(
                maximumContentLength
            )
        }
        guard maximumLoadAttempts > 0 else {
            throw LoopbackGeneratedResourceError.invalidMaximumLoadAttempts(
                maximumLoadAttempts
            )
        }
        self.contentType = contentType
        self.maximumContentLength = maximumContentLength
        self.remainingLoadAttempts = maximumLoadAttempts
        self.loader = loader
    }

    public static func == (
        lhs: LoopbackGeneratedResource,
        rhs: LoopbackGeneratedResource
    ) -> Bool {
        lhs === rhs
    }

    func resolve() async throws -> Data {
        let pending = lock.withLock { () -> (UInt64, Task<Data, any Error>, Data?) in
            guard !invalidated else {
                return (generation, Task { throw CancellationError() }, nil)
            }
            if let cachedBody {
                let cached = cachedBody
                return (generation, Task { cached }, cached)
            }
            if let loadTask {
                return (generation, loadTask, nil)
            }
            guard remainingLoadAttempts > 0 else {
                return (
                    generation,
                    Task {
                        throw LoopbackGeneratedResourceError.loadAttemptsExhausted
                    },
                    nil
                )
            }
            remainingLoadAttempts -= 1
            generation &+= 1
            let loadGeneration = generation
            let task = Task {
                try await generateAndCache(generation: loadGeneration)
            }
            loadTask = task
            return (generation, task, nil)
        }
        if let cached = pending.2 {
            return cached
        }

        let body = try await pending.1.value
        try Task.checkCancellation()
        return body
    }

    private func generateAndCache(generation loadGeneration: UInt64) async throws -> Data {
        do {
            let body = try await loader()
            guard !body.isEmpty, body.count <= maximumContentLength else {
                throw LoopbackGeneratedResourceError.invalidGeneratedContentLength(
                    body.count
                )
            }
            let accepted = lock.withLock { () -> Bool in
                guard generation == loadGeneration, !invalidated else {
                    return false
                }
                cachedBody = body
                loadTask = nil
                return true
            }
            guard accepted else { throw CancellationError() }
            return body
        } catch {
            lock.withLock {
                if generation == loadGeneration {
                    loadTask = nil
                }
            }
            throw error
        }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Data, any Error>? in
            generation &+= 1
            invalidated = true
            cachedBody = nil
            let task = loadTask
            loadTask = nil
            return task
        }
        task?.cancel()
    }
}

/// loopback route 背后的资源：内存正文、DASH 远端分段、按需生成的正文或 progressive 文件。
public enum LoopbackPlaybackResource: Sendable, Equatable {
    case inMemory(data: Data, contentType: String)
    case remote(LoopbackRemoteResource)
    case generated(LoopbackGeneratedResource)
    case progressive(LoopbackProgressiveResource)

    var contentLength: Int64 {
        switch self {
        case .inMemory(let data, _):
            Int64(data.count)
        case .remote(let resource):
            resource.contentLength
        case .generated:
            preconditionFailure("Generated resources must be resolved before responding")
        case .progressive(let resource):
            resource.contentLength
        }
    }

    var contentType: String {
        switch self {
        case .inMemory(_, let contentType):
            contentType
        case .remote(let resource):
            resource.contentType
        case .generated(let resource):
            resource.contentType
        case .progressive(let resource):
            resource.contentType
        }
    }
}

/// 一条待登记的 route：session path 下的相对路径与它的资源，供成批原子登记。
public struct LoopbackRouteRegistration: Sendable, Equatable {
    public let relativePath: String
    public let resource: LoopbackPlaybackResource

    public init(
        relativePath: String,
        resource: LoopbackPlaybackResource
    ) {
        self.relativePath = relativePath
        self.resource = resource
    }
}

/// loopback server 的启动、route 登记、请求解析与来源校验错误。
public enum LoopbackPlaybackServerError: Error, Sendable, Equatable {
    case invalidContentLength(Int64)
    case invalidRoute(String)
    case duplicateRoute(String)
    case notStarted
    case listenerFailed(String)
    case invalidHTTPRequest
    case invalidProgressiveSource
    case invalidRemoteSource
}
