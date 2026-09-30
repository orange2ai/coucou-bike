import XCTest
import CoreLocation
@testable import coucou

/// 冒烟测试：工程完整性 + 核心算法正确性
/// 存在的意义：2026-09-23 的 GO 闪退（Info.plist 丢失 UIBackgroundModes）
/// 和装机失败（appex 缺 NSExtension）都是工程级回归，本文件负责在推送前拦住。
final class SmokeTests: XCTestCase {

    // MARK: - 工程完整性（两次事故的直接防线）

    func testAppInfoPlistHasBackgroundModes() throws {
        let info = try requireAppInfo()
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        XCTAssertTrue(modes.contains("location"),
                      "UIBackgroundModes 缺 location：后台记录失效，GO 时开后台定位直接闪退")
        XCTAssertTrue(modes.contains("audio"),
                      "UIBackgroundModes 缺 audio：锁屏后语音播报会停")
    }

    func testAppInfoPlistKeyDeclarations() throws {
        let info = try requireAppInfo()
        XCTAssertEqual(info["NSSupportsLiveActivities"] as? Bool, true,
                       "缺 NSSupportsLiveActivities：实时活动不会显示")
        XCTAssertNotNil(info["UILaunchScreen"], "缺 UILaunchScreen：杀 App 会白屏")
        for key in ["NSLocationWhenInUseUsageDescription",
                    "NSMotionUsageDescription"] {
            let value = info[key] as? String
            XCTAssertFalse(value?.isEmpty ?? true, "缺 \(key)")
        }
    }

    func testWidgetExtensionIsEmbeddedAndValid() throws {
        let appex = Bundle.main.bundleURL.appendingPathComponent("PlugIns/coucouWidgets.appex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appex.path),
                      "coucouWidgets.appex 未嵌入主 App：实时活动不可用")
        let plistURL = appex.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        let ext = plist?["NSExtension"] as? [String: Any]
        XCTAssertEqual(ext?["NSExtensionPointIdentifier"] as? String,
                       "com.apple.widgetkit-extension",
                       "appex 缺 NSExtension 字典：装机直接报错")
    }

    private func requireAppInfo() throws -> [String: Any] {
        guard let info = Bundle.main.infoDictionary else {
            throw XCTSkip("测试宿主不是 App Bundle")
        }
        return info
    }

    // MARK: - 卡尔曼测速（GPS 速度/距离的根基，边界用真机同款实现标定）

    /// 恒速 5 m/s（18 km/h）行驶 30 秒：速度应收敛，距离不得大幅偏差
    func testKalmanConvergesOnConstantSpeed() {
        let recorder = LocationRecorder()
        let exp = expectation(description: "30 fixes processed")
        var lastKmh = 0.0
        var totalMeters = 0.0
        var processed = 0
        recorder.onLocation = { _, kmh, meters in
            lastKmh = kmh
            totalMeters += meters
            processed += 1
            if processed == 30 { exp.fulfill() }
        }
        var t = Date(timeIntervalSince1970: 1_000_000)
        let manager = CLLocationManager()
        for i in 0..<30 {
            t = t.addingTimeInterval(1)
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 40.0 + Double(i) * 5.0 / 111_320.0, longitude: 116.0),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: t)
            recorder.locationManager(manager, didUpdateLocations: [loc])
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(lastKmh, 18.0, accuracy: 4.0, "卡尔曼未能收敛到真实速度 18km/h")
        XCTAssertEqual(totalMeters, 145.0, accuracy: 30.0, "距离积分偏差过大（30 秒 × 5m/s 应约 145m）")
    }

    /// 原地不动（±0.3m 噪声）：不得出现假速度，距离不得虚增
    func testKalmanReportsZeroWhenStationary() {
        let recorder = LocationRecorder()
        let exp = expectation(description: "20 fixes processed")
        var falseSpeedSeen = false
        var totalMeters = 0.0
        var processed = 0
        recorder.onLocation = { _, kmh, meters in
            if kmh > 0 { falseSpeedSeen = true }
            totalMeters += meters
            processed += 1
            if processed == 20 { exp.fulfill() }
        }
        var t = Date(timeIntervalSince1970: 1_000_000)
        let manager = CLLocationManager()
        for i in 0..<20 {
            t = t.addingTimeInterval(1)
            let lat = 40.0 + Double.random(in: -0.3...0.3) / 111_320.0
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 116.0),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: t)
            recorder.locationManager(manager, didUpdateLocations: [loc])
        }
        wait(for: [exp], timeout: 5)
        XCTAssertFalse(falseSpeedSeen, "静止时出现了假速度")
        XCTAssertEqual(totalMeters, 0, accuracy: 1.0, "静止时距离虚增")
    }

    // MARK: - 实时活动数据结构

    func testRideActivityContentStateCodable() throws {
        let state = RideActivityAttributes.ContentState(
            speedKmh: 23.4, distanceKm: 12.48, elapsed: 2452, paused: false)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded.speedKmh, 23.4)
        XCTAssertEqual(decoded.distanceKm, 12.48)
        XCTAssertEqual(decoded.elapsed, 2452)
        XCTAssertFalse(decoded.paused)
    }

    // MARK: - 本地骑行存档

    /// 存档→读回→每公里分段与测距，决定记录页与导出的正确性
    func testRideRecordArchiveRoundtrip() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var route: [RideRecord.RidePoint] = []
        // 沿经线骑 2.2km（每点 100m）
        for i in 0...22 {
            route.append(.init(t: Double(i) * 20,
                               lat: 40.0 + Double(i) * 100.0 / 111_320.0,
                               lon: 116.0, ele: 10 + Double(i)))
        }
        let rec = RideRecord(startDate: start, duration: 440,
                             distanceKm: 2.2, avgSpeedKmh: 18, maxSpeedKmh: 21,
                             calories: 120, elevationGainM: 22,
                             cues: [CueEvent(id: UUID(), date: start, text: "测试", kind: .kmSplit)],
                             route: route)
        RideArchive.save(rec)
        defer { RideArchive.delete(rec) }
        let all = RideArchive.loadAll()
        guard let loaded = all.first(where: { $0.id == rec.id }) else {
            return XCTFail("存档后读不回记录")
        }
        XCTAssertEqual(loaded.distanceKm, 2.2, accuracy: 0.001)
        XCTAssertEqual(loaded.route.count, 23)
        XCTAssertEqual(loaded.splits.count, 2, "2.2km 应有 2 个整公里分段")
        XCTAssertGreaterThan(loaded.splits[0].seconds, 0)
        // 分段用时合理性：100m/20s = 18km/h → 每公里约 200s
        XCTAssertEqual(loaded.splits[0].seconds, 200, accuracy: 30)
    }

    // MARK: - 千卡 MET 分级

    /// MET 分级边界：休闲/中速/竞速各档，且千卡积分应远低于旧版 9.8 kcal/min 固定值
    func testMetGradingBySpeed() {
        XCTAssertEqual(RideEngine.met(forKmh: 12), 4.0)
        XCTAssertEqual(RideEngine.met(forKmh: 16.5), 6.8)
        XCTAssertEqual(RideEngine.met(forKmh: 20), 8.0)
        XCTAssertEqual(RideEngine.met(forKmh: 24), 10.0)
        XCTAssertEqual(RideEngine.met(forKmh: 28), 12.0)
        XCTAssertEqual(RideEngine.met(forKmh: 35), 15.8)
        // 70kg 休闲骑（14km/h）一小时：4 MET × 3.5 × 70 / 200 ≈ 294 千卡；旧算法 9.8×60=588，正好高出约一倍
        // 90 分钟 20km/h：8 MET × 3.5 × 70 / 200 ≈ 9.8 kcal/min —— 同速同重才等价，速度低时必须更低
        let kcalLow = RideEngine.met(forKmh: 14) * 3.5 * 70 / 200 * 60
        XCTAssertLessThan(kcalLow, 9.8 * 60,
                          "低速骑行千卡必须低于旧版固定 9.8 kcal/min，否则永远比系统体能偏高")
    }

    // MARK: - 设置解码兼容旧存档

    func testCueSettingsDecodesLegacyArchiveWithoutNewFields() throws {
        let legacy = #"{"perKilometer": true, "hrZoneAlert": true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(CueSettings.self, from: legacy)
        XCTAssertTrue(settings.autoPause, "旧存档缺新字段时应取默认值，不能整体解码失败")
        XCTAssertTrue(settings.emotionalValue)
        XCTAssertTrue(settings.keepScreenOn)
    }
}
