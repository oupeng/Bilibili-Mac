import Foundation

/// HLS `BANDWIDTH` 的峰值码率：任意连续分段在总时长落在目标时长 0.5–1.5 倍之间时的最大码率。
///
/// 逐个起点累加窗口是 O(n²)，病态 SIDX（大量极短分段加一个极长分段）会让播放准备长时间占满 CPU
/// 且无法取消。这里用 Dinkelbach 迭代把“最大比值”化为若干轮“最大差值”：每轮以双指针维护时长合法的
/// 起点区间、用单调队列取区间内的最小前缀，单轮 O(n)；比值每轮严格上升，通常两三轮收敛。时长与比特数
/// 全部用整数 tick 与 bit 精确比较，结果是某个合法窗口的真实码率。
enum HLSPeakBitRate {
    /// 前缀和上限；乘积保持在 `Int128` 范围内，超出说明 SIDX 声明的数值不可能是真实媒体。
    private static let maximumPrefixTotal = Int128(1) << 62

    /// 返回 bit/s，没有满足时长约束的窗口时返回 0。
    ///
    /// 调用方已验证非空分段、正 timescale 与正时长。
    static func peak(of index: SegmentIndex) throws -> Double {
        let references = index.references
        let count = references.count
        guard count > 0 else { return 0 }
        let timescale = Int128(index.timescale)
        let maximumDuration =
            references.map { Double($0.duration) / Double(index.timescale) }.max() ?? 0
        let targetDuration = Int128(ceil(maximumDuration))
        // 窗口时长 T（tick）合法当且仅当 0.5·target ≤ T/timescale ≤ 1.5·target，两边乘 2 化为整数。
        let doubledMinimum = targetDuration * timescale
        let doubledMaximum = 3 * targetDuration * timescale

        var bitPrefix = [Int128](repeating: 0, count: count + 1)
        var tickPrefix = [Int128](repeating: 0, count: count + 1)
        for (offset, reference) in references.enumerated() {
            let byteCount =
                Int128(reference.byteRange.endInclusive)
                - Int128(reference.byteRange.start) + 1
            bitPrefix[offset + 1] = bitPrefix[offset] + byteCount * 8
            tickPrefix[offset + 1] = tickPrefix[offset] + Int128(reference.duration)
        }
        guard bitPrefix[count] < maximumPrefixTotal,
            tickPrefix[count] < maximumPrefixTotal
        else {
            throw HLSPlaylistBuilderError.invalidCalculatedBitRate
        }

        // 当前最优比值 bits/ticks，初值 0/1。
        var bits: Int128 = 0
        var ticks: Int128 = 1
        var weightedPrefix = [Int128](repeating: 0, count: count + 1)
        var queue = [Int](repeating: 0, count: count + 1)
        while true {
            for position in 0...count {
                weightedPrefix[position] =
                    ticks * bitPrefix[position] - bits * tickPrefix[position]
            }
            var head = 0
            var tail = 0
            var nextStart = 0
            var best: (gain: Int128, start: Int, end: Int)?
            for end in 1...count {
                while nextStart < end,
                    2 * (tickPrefix[end] - tickPrefix[nextStart]) >= doubledMinimum
                {
                    while tail > head,
                        weightedPrefix[queue[tail - 1]] >= weightedPrefix[nextStart]
                    {
                        tail -= 1
                    }
                    queue[tail] = nextStart
                    tail += 1
                    nextStart += 1
                }
                while tail > head,
                    2 * (tickPrefix[end] - tickPrefix[queue[head]]) > doubledMaximum
                {
                    head += 1
                }
                guard tail > head else { continue }
                let start = queue[head]
                let gain = weightedPrefix[end] - weightedPrefix[start]
                if best.map({ gain > $0.gain }) ?? true {
                    best = (gain, start, end)
                }
            }
            guard let best else { return 0 }
            // 首轮比值为 0，任一窗口都有正增益；之后没有窗口能超过当前比值即为最优。
            if bits > 0, best.gain <= 0 {
                return Double(bits) / (Double(ticks) / Double(timescale))
            }
            bits = bitPrefix[best.end] - bitPrefix[best.start]
            ticks = tickPrefix[best.end] - tickPrefix[best.start]
        }
    }
}
