import XCTest
import HealthKit
import CoreLocation
@testable import coucou

/// 冒烟测试：工程完整性 + 展示层数据契约
/// 产品在 2026-10-13 收敛为「只读苹果健康的骑行数据展示」，定位/播报/实时活动全部退场，
/// 所以这里同时守着「不该有的东西不许回来」。
final class SmokeTests: XCTestCase {

    // MARK: - 工程完整性

    func testAppInfoPlistDeclaresOnlyHealthRead() throws {
        let info = try requireAppInfo()
        let share = info["NSHealthShareUsageDescription"] as? String
        XCTAssertFalse(share?.isEmpty ?? true, "缺 NSHealthShareUsageDescription：读不了骑行记录")
        XCTAssertNil(info["NSHealthUpdateUsageDescription"],
                     "咕咕只读健康，不应声明写入用途")
        XCTAssertNil(info["NSLocationWhenInUseUsageDescription"],
                     "定位链路已删除，不应再声明定位用途")
        XCTAssertNil(info["NSMotionUsageDescription"],
                     "计步器兜底已删除，不应再声明运动与健身用途")
        XCTAssertNil(info["UIBackgroundModes"],
                     "后台定位与音频已删除，不应再有后台模式")
        XCTAssertNil(info["NSSupportsLiveActivities"],
                     "实时活动已删除，不应再声明")
        XCTAssertNotNil(info["UILaunchScreen"], "缺 UILaunchScreen：杀 App 会白屏")
    }

    func testNoWidgetExtensionEmbedded() {
        let appex = Bundle.main.bundleURL.appendingPathComponent("PlugIns")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: appex.path)) ?? []
        // 测试宿主的 PlugIns 里会有 coucouTests.xctest，只禁扩展
        let extensions = contents.filter { $0.hasSuffix(".appex") }
        XCTAssertTrue(extensions.isEmpty, "实时活动 Widget 已删除，不应再嵌入 appex：\(extensions)")
    }

    private func requireAppInfo() throws -> [String: Any] {
        guard let info = Bundle.main.infoDictionary else {
            throw XCTSkip("测试宿主不是 App Bundle")
        }
        return info
    }

    // MARK: - 展示层数据映射

    /// 健康训练到展示项的映射：距离取米转公里、时长透传、均速按有效时长算
    func testRideItemMappingFromWorkout() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = HKWorkout(activityType: .cycling,
                                start: start,
                                end: start.addingTimeInterval(3600),
                                duration: 3600,
                                totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: 420),
                                totalDistance: HKQuantity(unit: .meter(), doubleValue: 24_000),
                                metadata: nil)
        let item = RideItem(workout: workout)
        XCTAssertEqual(item.distanceKm, 24, accuracy: 0.001, "24000 米应映射为 24 公里")
        XCTAssertEqual(item.duration, 3600)
        XCTAssertEqual(item.calories, 420)
        XCTAssertEqual(item.avgSpeedKmh, 24, accuracy: 0.001, "24 公里 1 小时 = 24 km/h")
        XCTAssertEqual(item.date, start)
    }

    /// 演示数据必须可控：条数固定、按时间倒序无关（由展示层排序）、字段齐全
    func testDemoDataShape() {
        let items = DemoData.items()
        XCTAssertEqual(items.count, 14, "官网截图依赖这批固定演示数据")
        XCTAssertTrue(items.allSatisfy { $0.distanceKm > 0 && $0.duration > 0 }, "演示数据缺字段")
        XCTAssertTrue(items.allSatisfy { $0.workout == nil }, "演示数据不应引用真实健康训练")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "演示数据 id 必须唯一")
    }

    /// 统计区依赖的距离序列：总里程是所有场次之和
    func testTotalDistanceAggregation() {
        let items = DemoData.items()
        let total = items.reduce(0) { $0 + $1.distanceKm }
        XCTAssertEqual(total, 301.1, accuracy: 0.05, "官网截图里总里程为 301.1 km")
    }

    // MARK: - 成长口径

    /// 上期没有数据时不能算百分比，界面也就不可能出现 NaN / ∞
    func testComparisonWithoutPreviousPeriod() {
        let now = Date()
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: now)!.start
        let items = [RideItem(id: "a", date: weekStart.addingTimeInterval(3600),
                              distanceKm: 10, duration: 1800, calories: 120)]
        let week = RideInsights(items: items).comparisons(now: now).first { $0.title == "本周" }
        XCTAssertEqual(week?.km ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(week?.previousKm ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(week?.percent, "上期为 0 时百分比必须是 nil")
    }

    /// 去年同期只算到今天的同等进度，不能把去年年底的里程也算进来
    func testLastYearComparisonUsesSamePeriod() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let inPeriod = cal.date(from: DateComponents(year: 2025, month: 3, day: 1, hour: 9))!
        let afterPeriod = cal.date(from: DateComponents(year: 2025, month: 12, day: 1, hour: 9))!
        let items = [
            RideItem(id: "p", date: inPeriod, distanceKm: 20, duration: 3600),
            RideItem(id: "q", date: afterPeriod, distanceKm: 99, duration: 3600),
        ]
        let year = RideInsights(items: items).comparisons(now: now).first { $0.title == "今年" }
        XCTAssertEqual(year?.previousKm ?? -1, 20, accuracy: 0.001)
    }

    /// 连续周数：本周往前连着三周，再往前空一周
    func testStreakCountsConsecutiveWeeks() {
        let cal = Calendar.current
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        let offsets = [0, -7, -14, -28]
        let items = offsets.enumerated().compactMap { index, days -> RideItem? in
            guard let day = cal.date(byAdding: .day, value: days, to: thisWeek) else { return nil }
            return RideItem(id: "w\(index)", date: day.addingTimeInterval(3600),
                            distanceKm: 10, duration: 1800)
        }
        let streak = RideInsights(items: items).streak
        XCTAssertEqual(streak.current, 3, "本周、上周、上上周连着，再往前断了")
        XCTAssertEqual(streak.longest, 3)
    }

    // MARK: - 最佳一段（最快 1 公里 / 5 公里）

    /// 最快 1 公里取的是真的最快那一段：前 1 公里慢、后 1 公里快，结果必须是快的那段
    func testBestEffortPicksFastestWindow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // 0 到 200 秒 5 m/s，200 秒之后 10 m/s
        let series: [(date: Date, meters: Double)] = stride(from: 0, through: 400, by: 10).map { second in
            let t = Double(second)
            let meters = t <= 200 ? t * 5 : 1000 + (t - 200) * 10
            return (date: start.addingTimeInterval(t), meters: meters)
        }
        let best = BestEfforts.best(in: series, windowKm: 1)
        XCTAssertEqual(best?.speedKmh ?? 0, 36, accuracy: 0.1, "每 10 秒 100 米就是 36 km/h")
        XCTAssertEqual(best?.date.timeIntervalSince1970 ?? 0,
                       start.addingTimeInterval(200).timeIntervalSince1970,
                       accuracy: 0.001, "纪录日期取最快那段窗口的起点")

        // 同一条序列里 5 公里窗口根本不够长，不能有值
        XCTAssertNil(BestEfforts.best(in: series, windowKm: 5), "总距离 3 公里不能凑出 5 公里纪录")
    }

    /// 距离不够整段窗口时返回 nil，绝不用不足的距离硬凑一个速度
    func testBestEffortNeedsWholeWindow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let series: [(date: Date, meters: Double)] = stride(from: 0, through: 100, by: 10).map { second in
            (date: start.addingTimeInterval(Double(second)), meters: Double(second) * 8)
        }
        XCTAssertNil(BestEfforts.best(in: series, windowKm: 1), "只有 800 米")
        XCTAssertNil(BestEfforts.best(in: series, windowKm: 5))
    }

    /// GPS 跳点必须丢掉：精度 120 米的点会把累计距离吹成一段假的高速
    func testRouteSeriesSkipsBadFixes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = (0...4).map { i -> CLLocation in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31.2 + Double(i) * 0.001, longitude: 121.4),
                       altitude: 0,
                       horizontalAccuracy: i == 2 ? 120 : 8,
                       verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(Double(i) * 10))
        }
        let series = HealthKitStore.cumulative(from: route)
        XCTAssertEqual(series.count, 4, "精度 120 米的那个点要被丢掉")
        XCTAssertEqual(series.first?.meters ?? -1, 0, "序列从 0 米开始")
        XCTAssertTrue(zip(series, series.dropFirst()).allSatisfy { $0.meters <= $1.meters }, "累计米必须单调不减")
        XCTAssertTrue(HealthKitStore.cumulative(from: [route[0]]).isEmpty, "一个点算不出距离")
    }

    /// 同一趙骑行手表和第三方 App 各写一遍距离时只认一个来源，混加会把速度翻倍
    func testSeriesIgnoresDuplicateSources() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // 两个来源各写 10 段、每段 100 米，时间交错：混加会变成每秒 200 米
        var raw: [(source: String, date: Date, meters: Double)] = []
        for i in 0..<10 {
            let t = start.addingTimeInterval(Double(i + 1) * 10)
            raw.append(("com.apple.health.watch", t, 100))
            raw.append(("coucou", t.addingTimeInterval(0.5), 100))
        }
        let series = BestEfforts.series(from: raw)
        XCTAssertEqual(series.last?.meters ?? -1, 1000, "第三方写的距离不参与，只累计系统来源的增量")
        XCTAssertNil(BestEfforts.best(in: series, windowKm: 5), "总距离只有 1 公里，不能出 5 公里纪录")
    }

    /// 多个来源时取累计距离最大的那个（覆盖最完整）
    func testSeriesPicksLargestSource() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var raw: [(source: String, date: Date, meters: Double)] = []
        for i in 0..<10 {
            let t = start.addingTimeInterval(Double(i + 1) * 10)
            raw.append(("com.apple.health.watch", t, 120))
            raw.append(("com.apple.health.iphone", t.addingTimeInterval(0.5), 30))
        }
        let series = BestEfforts.series(from: raw)
        XCTAssertEqual(series.last?.meters ?? -1, 1200, "取覆盖最完整的手表来源，不是两者相加")
    }

    /// 演示数据的最佳成绩要有合理层级：1 公里比 5 公里快，两个都大于 0
    func testDemoEffortsAreSane() {
        let bests = EffortScanner.demoBests()
        guard let one = bests.oneKm, let five = bests.fiveKm else {
            return XCTFail("演示数据必须给出最佳成绩，官网截图要用")
        }
        XCTAssertGreaterThan(one.speedKmh, five.speedKmh, "短窗口一定比长窗口快")
        XCTAssertGreaterThan(five.speedKmh, 0)
    }

    // MARK: - 页面结构

    /// 两个 tab 的直达参数：截图与冒烟靠在启动时指定落到哪个 tab
    func testStartTabArgumentParsing() {
        XCTAssertEqual(LaunchOptions.startTab(from: []), 0)
        XCTAssertEqual(LaunchOptions.startTab(from: ["coucou", "-demoData"]), 0)
        XCTAssertEqual(LaunchOptions.startTab(from: ["coucou", "-startTab", "1"]), 1)
        XCTAssertEqual(LaunchOptions.startTab(from: ["coucou", "-startTab", "9"]), 0, "越界要回落到第一个 tab")
        XCTAssertEqual(LaunchOptions.startTab(from: ["coucou", "-startTab"]), 0, "参数没跟上要给默认值")
    }

    /// 对比卡要能一眼看出涨还是跌：涨是正的、百分比同向
    func testComparisonDeltaDirection() {
        let cal = Calendar.current
        let now = Date()
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek)!

        let up = [
            RideItem(id: "this", date: thisWeek.addingTimeInterval(3600), distanceKm: 30, duration: 3600),
            RideItem(id: "last", date: lastWeek.addingTimeInterval(3600), distanceKm: 20, duration: 3600),
        ]
        let risen = RideInsights(items: up).comparisons(now: now).first { $0.title == "本周" }
        XCTAssertEqual(risen?.delta ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(risen?.percent, 50, "20 涨到 30 是 +50%")

        let down = [
            RideItem(id: "this", date: thisWeek.addingTimeInterval(3600), distanceKm: 10, duration: 3600),
            RideItem(id: "last", date: lastWeek.addingTimeInterval(3600), distanceKm: 25, duration: 3600),
        ]
        let fallen = RideInsights(items: down).comparisons(now: now).first { $0.title == "本周" }
        XCTAssertEqual(fallen?.delta ?? 0, -15, accuracy: 0.001)
        XCTAssertEqual(fallen?.percent, -60)
    }

    /// 个人纪录四项齐全，且最长单次取的是演示数据里的最大值
    func testRecordsShape() {
        let records = RideInsights(items: DemoData.items()).records()
        XCTAssertEqual(records.map(\.label), ["最长单次", "最快均速", "最长单次用时", "单月最多"])
        XCTAssertEqual(records.first?.value, "35.6 km")
        XCTAssertTrue(records.allSatisfy { !$0.detail.isEmpty }, "纪录必须带日期")
    }
}
