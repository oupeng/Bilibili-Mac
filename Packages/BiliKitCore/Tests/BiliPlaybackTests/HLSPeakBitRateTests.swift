import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

@Suite(.timeLimit(.minutes(1)))
struct HLSPeakBitRateTests {
    /// 时长可精确表示（tick 为 2 的幂分之一秒或整秒）时，结果与逐窗口累加的定义逐位相同。
    @Test(arguments: peakBoundaryCases)
    func matchesWindowDefinition(_ peakCase: PeakCase) throws {
        let index = peakCase.index
        #expect(try HLSPeakBitRate.peak(of: index) == referencePeak(of: index))
    }

    @Test
    func matchesWindowDefinitionAcrossMixedDurations() throws {
        var generator = LinearCongruentialGenerator(seed: 0x5EED)
        for _ in 0..<300 {
            let count = Int(generator.next() % 40) + 1
            let segments = (0..<count).map { _ in
                PeakCase.Segment(
                    UInt64(generator.next() % 4_000_000) + 1,
                    UInt32(generator.next() % 6_144) + 1
                )
            }
            let index = PeakCase(timescale: 1_024, segments: segments).index
            #expect(try HLSPeakBitRate.peak(of: index) == referencePeak(of: index))
        }
    }

    @Test
    func pathologicalIndexFinishesWithinLinearPasses() throws {
        // reference_count 上限 65535：逐起点累加需要约 21 亿步。
        let shortSegments = (0..<65_534).map { PeakCase.Segment(UInt64(1_000 + $0 % 4_999), 1) }
        let segments = shortSegments + [PeakCase.Segment(10, 90_000 * 600)]
        let index = PeakCase(timescale: 90_000, segments: segments).index

        #expect(try HLSPeakBitRate.peak(of: index) > 0)
    }

    /// 峰值的原始定义：逐个起点累加，时长超过上界即停。
    private func referencePeak(of index: SegmentIndex) -> Double {
        let segments = index.references.map { reference in
            (
                bits: Double(reference.byteRange.endInclusive - reference.byteRange.start + 1) * 8,
                duration: Double(reference.duration) / Double(index.timescale)
            )
        }
        let targetDuration = ceil(segments.map(\.duration).max() ?? 0)
        var peak = 0.0
        for start in segments.indices {
            var bits = 0.0
            var duration = 0.0
            for end in start..<segments.endIndex {
                bits += segments[end].bits
                duration += segments[end].duration
                if duration > 1.5 * targetDuration { break }
                if duration >= 0.5 * targetDuration {
                    peak = max(peak, bits / duration)
                }
            }
        }
        return peak
    }
}

private let manyShortSegments: [PeakCase.Segment] = (0..<2_000).map {
    PeakCase.Segment(UInt64(1_000 + $0 % 37), 1)
}

let peakBoundaryCases: [PeakCase] = [
    // 普通：90 kHz、2 秒等长分段。
    PeakCase(timescale: 90_000, segments: [.init(500_000, 180_000), .init(900_000, 180_000)]),
    // 单个分段恰好等于 0.5×目标时长（下界含等号）。
    PeakCase(timescale: 4, segments: [.init(9_000, 2), .init(1_000, 4)]),
    // 三段合计恰好等于 1.5×目标时长（上界含等号）。
    PeakCase(
        timescale: 4,
        segments: [.init(1_000, 2), .init(6_000, 2), .init(1_000, 2), .init(100, 4)]
    ),
    // 最高码率出现在较短窗口而不是最长合法窗口。
    PeakCase(timescale: 1, segments: [.init(10, 1), .init(80, 1), .init(10, 1), .init(10, 2)]),
    // 只有一个过短分段：没有合法窗口。
    PeakCase(timescale: 4, segments: [.init(1_000, 1)]),
    // 大量极短分段加一个极长分段。
    PeakCase(timescale: 1_024, segments: manyShortSegments + [.init(5, 1_024 * 8)])
]

struct PeakCase: Sendable, CustomTestStringConvertible {
    struct Segment: Sendable {
        let byteCount: UInt64
        let ticks: UInt32

        init(_ byteCount: UInt64, _ ticks: UInt32) {
            self.byteCount = byteCount
            self.ticks = ticks
        }
    }

    let timescale: UInt32
    let segments: [Segment]

    var testDescription: String { "\(segments.count) segments @ \(timescale)" }

    var index: SegmentIndex {
        var offset: Int64 = 0
        let references = segments.map { segment in
            defer { offset += Int64(segment.byteCount) }
            return SegmentReference(
                byteRange: try! MediaByteRange(
                    start: offset,
                    endInclusive: offset + Int64(segment.byteCount) - 1
                ),
                duration: segment.ticks,
                startsWithSAP: true,
                sapType: 1,
                sapDeltaTime: 0
            )
        }
        return SegmentIndex(
            referenceID: 1,
            timescale: timescale,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: references
        )
    }
}

/// 固定种子的可复现输入生成器。
private struct LinearCongruentialGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
