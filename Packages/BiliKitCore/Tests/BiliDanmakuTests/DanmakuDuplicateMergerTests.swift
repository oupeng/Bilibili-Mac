import BiliApplication
import BiliModels
import Testing

@testable import BiliDanmaku

/// 重复弹幕合并的契约：同一位置、归一化后同文、组首后 4 秒内的弹幕并成一条带条数，组首的时间与样式不变；
/// 不跨分段、不跨组累计；合并弹幕换用自己的 ID；开关关闭时布局不变。
@Suite
struct DanmakuDuplicateMergerTests {
    @Test(
        arguments: [
            ("哈哈哈哈哈", "哈哈哈"),
            ("2333333", "2333"),
            ("６６６！！！", "666"),
            ("Ｌｉｋｅ  THIS～", "likethis"),
            ("好耶。", "好耶"),
            ("？？？？", "???"),
            ("👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧", "👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧"),
            ("ｶﾀｶﾅ", "ｶﾀｶﾅ")
        ]
    )
    func comparisonKeyFoldsOnlyCosmeticDifferences(text: String, expected: String) {
        #expect(DanmakuDuplicateMerger.comparisonKey(for: text) == expected)
    }

    /// 全是标点的弹幕按标点本身比较，不会因去掉句尾标点变成空串而与别的标点弹幕合并。
    @Test
    func punctuationOnlyTextsStayDistinct() {
        let question = DanmakuDuplicateMerger.comparisonKey(for: "？？？")
        let exclamation = DanmakuDuplicateMerger.comparisonKey(for: "！！！")
        #expect(!question.isEmpty)
        #expect(question != exclamation)
    }

    @Test
    func duplicatesWithinTheWindowBecomeOneCountedEvent() {
        let window = DanmakuDuplicateMerger.windowSeconds
        let events = [
            event("a", time: 10, text: "好耶"),
            event("b", time: 11, text: "别的"),
            event("c", time: 12, text: "好耶！", isHighLike: true),
            event("d", time: 10 + window, text: "好耶～"),
            event("e", time: 10 + window + 0.01, text: "好耶")
        ]

        let merged = DanmakuDuplicateMerger.merged(events)

        #expect(merged.map(\.text) == ["好耶 ×3", "别的", "好耶"])
        #expect(merged.map(\.timeSeconds) == [10, 11, 10 + window + 0.01])
        #expect(merged[0].id != "a")
        #expect(merged[0].isHighLike)
        #expect(merged[1] == events[1])
        #expect(merged[2] == events[4])
    }

    @Test
    func differentPositionsAreNotMerged() {
        let events = [
            event("a", time: 1, text: "好耶", mode: .scrolling),
            event("b", time: 1.5, text: "好耶", mode: .top),
            event("c", time: 2, text: "好耶", mode: .bottom)
        ]

        #expect(DanmakuDuplicateMerger.merged(events) == events)
    }

    /// 组首后同一组只吸收窗口内的弹幕；窗口外的同文另起一组，从 1 开始计，不接着上一组累计。
    @Test
    func laterGroupsStartCountingAgain() {
        let window = DanmakuDuplicateMerger.windowSeconds
        let events = (0..<6).map { offset in
            event("e\(offset)", time: Double(offset) * window * 0.6, text: "草")
        }

        #expect(DanmakuDuplicateMerger.merged(events).map(\.text) == ["草 ×2", "草 ×2", "草 ×2"])
    }

    /// 开关打开时同一段内合并、不跨分段；关闭时与原来的布局一致。
    @Test
    func plannerMergesWithinASegmentOnlyWhenEnabled() throws {
        let boundary = DanmakuSegmentCache.segmentDurationSeconds
        let segments: [Int: [DanmakuEvent]] = [
            1: [
                event("a", time: boundary - 2, text: "好耶"),
                event("b", time: boundary - 1, text: "好耶")
            ],
            2: [event("c", time: boundary + 0.5, text: "好耶")]
        ]

        let merged = try #require(layouts(segments, mergesDuplicates: true))
        let plain = try #require(layouts(segments, mergesDuplicates: false))

        #expect(merged[1]?.placements.map(\.request.event.text) == ["好耶 ×2"])
        #expect(merged[2]?.placements.map(\.request.event.text) == ["好耶"])
        #expect(plain[1]?.placements.map(\.request.event.id) == ["a", "b"])
        #expect(plain[2]?.placements.map(\.request.event.id) == ["c"])
    }

    private func layouts(
        _ segments: [Int: [DanmakuEvent]],
        mergesDuplicates: Bool
    ) -> [Int: DanmakuSegmentLayout]? {
        DanmakuLayoutPlanner.layouts(
            for: segments,
            reusing: [:],
            parameters: DanmakuLayoutParameters(
                configuration: BiliDanmakuTests.configuration(),
                speedLevel: .default,
                backingScale: 2,
                filter: DanmakuFilter(mergesDuplicates: mergesDuplicates)
            ),
            measure: fixtureMetrics
        )
    }

    private func event(
        _ id: String,
        time: Double,
        text: String,
        mode: DanmakuPresentationMode = .scrolling,
        isHighLike: Bool = false
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: text,
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1,
            isHighLike: isHighLike
        )
    }
}
