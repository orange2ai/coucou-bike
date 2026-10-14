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
    /// 从带来源的距离采样里选出系统的距离序列。
    /// 只认系统自己的记录（手表与 iPhone 自带体能训练，来源是 com.apple.health.*），
    /// 第三方 App 写的距离（旧版咕咕、Keep）不参与：质量不可控，宁可不算。
    /// 同一趟可能同时有手表与 iPhone 各写一份，只取累计距离最大的那个，混加会把速度翻倍。
    static func series(from samples: [(source: String, date: Date, meters: Double)]) -> [(date: Date, meters: Double)] {
        let system = samples.filter { $0.source.hasPrefix("com.apple.health") }
        guard !system.isEmpty else { return [] }
        var groups: [String: [(date: Date, meters: Double)]] = [:]
        for s in system {
            groups[s.source, default: []].append((s.date, s.meters))
        }
        let chosen = groups.values.max { lhs, rhs in
            let sumL = lhs.reduce(0) { $0 + $1.meters }
            let sumR = rhs.reduce(0) { $0 + $1.meters }
            if sumL != sumR { return sumL < sumR }
            return lhs.count < rhs.count
        } ?? []
        var total = 0.0
        var out: [(date: Date, meters: Double)] = []
        for s in chosen.sorted(by: { $0.date < $1.date }) {
            total += s.meters
            out.append((s.date, total))
        }
        return out
    }

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
