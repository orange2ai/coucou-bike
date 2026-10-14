import Foundation

/// 记录页的统计口径：累计、里程碑、周期对比、个人纪录。
/// 纯值计算，不碰 SwiftUI 与 HealthKit，方便测试。
struct RideInsights {
    let items: [RideItem]

    init(items: [RideItem]) { self.items = items }

    private var cal: Calendar { Calendar.current }

    // MARK: - 累计

    var totalKm: Double { items.reduce(0) { $0 + $1.distanceKm } }
    var rideCount: Int { items.count }
    var totalDuration: TimeInterval { items.reduce(0) { $0 + $1.duration } }
    var totalCalories: Int { items.reduce(0) { $0 + ($1.calories ?? 0) } }

    // MARK: - 里程碑（保养）

    static let serviceInterval: Double = 1000
    var nextServiceKm: Double { (floor(totalKm / Self.serviceInterval) + 1) * Self.serviceInterval }
    var remainingKm: Double { max(0, nextServiceKm - totalKm) }
    var serviceProgress: Double {
        totalKm.truncatingRemainder(dividingBy: Self.serviceInterval) / Self.serviceInterval
    }

    // MARK: - 周期对比

    struct Comparison: Identifiable {
        let title: String
        let km: Double
        let previousTitle: String
        let previousKm: Double

        var id: String { title }
        var delta: Double { km - previousKm }
        /// 上期为 0 时返回 nil：界面绝不允许显示 NaN 或 ∞
        var percent: Int? { previousKm > 0 ? Int((delta / previousKm * 100).rounded()) : nil }
    }

    func comparisons(now: Date = Date()) -> [Comparison] {
        var out: [Comparison] = []
        if let thisWeek = cal.dateInterval(of: .weekOfYear, for: now),
           let lastWeekAnchor = cal.date(byAdding: .weekOfYear, value: -1, to: now),
           let lastWeek = cal.dateInterval(of: .weekOfYear, for: lastWeekAnchor) {
            out.append(Comparison(title: "本周", km: sum(in: thisWeek),
                                  previousTitle: "上周", previousKm: sum(in: lastWeek)))
        }
        if let thisMonth = cal.dateInterval(of: .month, for: now),
           let lastMonthAnchor = cal.date(byAdding: .month, value: -1, to: now),
           let lastMonth = cal.dateInterval(of: .month, for: lastMonthAnchor) {
            out.append(Comparison(title: "本月", km: sum(in: thisMonth),
                                  previousTitle: "上月", previousKm: sum(in: lastMonth)))
        }
        // 去年同期：去年年初到今天在今年的同等进度，不是整年，否则年初必然显得暴跌
        if let thisYear = cal.dateInterval(of: .year, for: now),
           let lastYearStart = cal.date(byAdding: .year, value: -1, to: thisYear.start) {
            let elapsed = now.timeIntervalSince(thisYear.start)
            let samePeriod = DateInterval(start: lastYearStart,
                                          end: lastYearStart.addingTimeInterval(elapsed))
            out.append(Comparison(title: "今年", km: sum(in: thisYear),
                                  previousTitle: "去年同期", previousKm: sum(in: samePeriod)))
        }
        return out
    }

    private func sum(in interval: DateInterval) -> Double {
        items.filter { interval.contains($0.date) }.reduce(0) { $0 + $1.distanceKm }
    }

    // MARK: - 连续骑行周数

    /// 含本周往前数；本周还没骑就从上周算，不让「今天还没出门」把连击清零
    var streak: (current: Int, longest: Int) {
        let weeks = Set(items.compactMap { cal.dateInterval(of: .weekOfYear, for: $0.date)?.start })
        guard !weeks.isEmpty else { return (0, 0) }
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        var cursor = weeks.contains(thisWeek) ? thisWeek : lastWeek
        var current = 0
        while weeks.contains(cursor) {
            current += 1
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = prev
        }
        var longest = 0
        for start in weeks {
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: start), !weeks.contains(prev) else { continue }
            var run = 0
            var c = start
            while weeks.contains(c) {
                run += 1
                guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: c) else { break }
                c = next
            }
            longest = max(longest, run)
        }
        return (current, longest)
    }

    // MARK: - 个人纪录

    struct Record: Identifiable {
        let label: String
        let value: String
        let detail: String
        var id: String { label }
    }

    func records() -> [Record] {
        var out: [Record] = []

        if let r = items.max(by: { $0.distanceKm < $1.distanceKm }), r.distanceKm > 0 {
            out.append(Record(label: "最长单次", value: String(format: "%.1f km", r.distanceKm),
                              detail: Self.shortDay(r.date)))
        }
        // 太短的一次均速没有意义，至少 5 分钟才参与评比
        let ranked = items.filter { $0.duration >= 300 }
        if let r = ranked.max(by: { $0.avgSpeedKmh < $1.avgSpeedKmh }), r.avgSpeedKmh > 0 {
            out.append(Record(label: "最快均速", value: String(format: "%.1f km/h", r.avgSpeedKmh),
                              detail: Self.shortDay(r.date)))
        }
        if let r = items.max(by: { $0.duration < $1.duration }), r.duration > 0 {
            out.append(Record(label: "最长单次用时", value: Self.clock(r.duration),
                              detail: Self.shortDay(r.date)))
        }
        var byMonth: [Date: Double] = [:]
        for it in items {
            guard let m = cal.dateInterval(of: .month, for: it.date)?.start else { continue }
            byMonth[m, default: 0] += it.distanceKm
        }
        if let best = byMonth.max(by: { $0.value < $1.value }), best.value > 0 {
            out.append(Record(label: "单月最多", value: String(format: "%.1f km", best.value),
                              detail: Self.monthText(best.key)))
        }
        return out
    }

    // MARK: - 文案

    var totalDurationText: String { String(format: "%.1f 小时", totalDuration / 3600) }
    var totalCaloriesText: String { Self.thousands(totalCalories) + " 千卡" }

    static func km(_ v: Double) -> String { String(format: "%.1f km", v) }

    static func clock(_ t: TimeInterval) -> String {
        String(format: "%d:%02d:%02d", Int(t) / 3600, Int(t) % 3600 / 60, Int(t) % 60)
    }

    static func thousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func shortDay(_ d: Date) -> String { shortDayFormatter.string(from: d) }
    static func monthText(_ d: Date) -> String { monthFormatter.string(from: d) }

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()
}
