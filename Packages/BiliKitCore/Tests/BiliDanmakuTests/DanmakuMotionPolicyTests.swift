import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕运动时长的契约：速度档位越快时长越短，安全边界只钳制极端输入。
@Suite
struct DanmakuMotionPolicyTests {
    @Test(
        arguments: [
            (400, 100), (1_100, 429), (3_440, 1_479)
        ] as [(Double, Double)]
    )
    func fasterSpeedLevelsMoveLongAndShortTextFaster(
        surfaceWidth: Double,
        textWidth: Double
    ) {
        let durations = DanmakuSpeedLevel.allCases.map {
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: textWidth,
                surfaceWidth: surfaceWidth,
                speedLevel: $0
            )
        }

        #expect(zip(durations, durations.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test
    func durationSafetyBoundsOnlyClampExtremeInputs() {
        #expect(
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: 1,
                surfaceWidth: 1,
                speedLevel: .five
            ) == 1.5
        )
        #expect(
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: 4_000,
                surfaceWidth: 10_000,
                speedLevel: .one
            ) == 60
        )
        #expect(
            DanmakuMotionPolicy.duration(
                for: .top,
                textWidth: 123,
                surfaceWidth: 1_100,
                speedLevel: .five
            ) == 4
        )
    }
}
