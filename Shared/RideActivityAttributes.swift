import Foundation
import ActivityKit

/// 骑行实时活动（锁屏 + 灵动岛）的共享定义：App 与 Widget 扩展两个 target 都编译此文件
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var speedKmh: Double
        var distanceKm: Double
        var elapsed: TimeInterval
        var heartRate: Double?
        var heartRateStale: Bool = false
        var paused: Bool
    }
}
