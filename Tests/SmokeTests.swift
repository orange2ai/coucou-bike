import XCTest
import HealthKit
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

    /// 个人纪录四项齐全，且最长单次取的是演示数据里的最大值
    func testRecordsShape() {
        let records = RideInsights(items: DemoData.items()).records()
        XCTAssertEqual(records.map(\.label), ["最长单次", "最快均速", "最长单次用时", "单月最多"])
        XCTAssertEqual(records.first?.value, "35.6 km")
        XCTAssertTrue(records.allSatisfy { !$0.detail.isEmpty }, "纪录必须带日期")
    }
}
