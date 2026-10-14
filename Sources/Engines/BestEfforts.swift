import Foundation

/// 一段最佳成绩：任意 windowKm 公里里最快的那一段均速。
/// 骑行圈说的「最快 1 公里」「最快 5 公里」就是这个口径。
struct BestEffort: Hashable {
    let windowKm: Double
    let speedKmh: Double
    /// 这段窗口的起点
    let date: Date
}

/// 纯计算，不碰 HealthKit 与 SwiftUI，方便测试。
enum BestEfforts {
    /// 从「(时间, 累计米)」序列里找最快的一段。序列必须按时间升序、累计米单调不减。
    /// 距离不够整段窗口时返回 nil，绝不用不足的距离硬凑一个速度出来。
    static func best(in series: [(date: Date, meters: Double)], windowKm: Double) -> BestEffort? {
        let window = windowKm * 1000
        guard series.count > 1, let last = series.last, last.meters >= window else { return nil }

        var start = 0
        var best: BestEffort?
        for end in 1..<series.count {
            // 起点尽量往后推，窗口里仍然是整段距离，花的时间最短就是最快的一段
            while start + 1 <= end, series[end].meters - series[start + 1].meters >= window {
                start += 1
            }
            guard series[end].meters - series[start].meters >= window else { continue }
            let seconds = series[end].date.timeIntervalSince(series[start].date)
            guard seconds > 0 else { continue }
            let speed = windowKm / (seconds / 3600)
            if speed > (best?.speedKmh ?? 0) {
                best = BestEffort(windowKm: windowKm, speedKmh: speed, date: series[start].date)
            }
        }
        return best
    }
}
