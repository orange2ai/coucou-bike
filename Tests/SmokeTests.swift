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
}
