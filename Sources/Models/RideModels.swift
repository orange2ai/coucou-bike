import Foundation
import HealthKit

/// 一条用于展示的骑行。
/// 视图层只依赖这个结构，不直接碰 HKWorkout，方便演示数据与未来维度扩展。
struct RideItem: Identifiable, Hashable {
    let id: String
    var date: Date
    var distanceKm: Double
    var duration: TimeInterval
    var calories: Int?
    var source: String?
    /// 写入方的 bundle id：用来识别旧版咕咕与第三方写入的数据
    var sourceBundleID: String?
    /// 健康训练本体：详情页据此读取心率与轨迹；演示数据为 nil
    var workout: HKWorkout?

    init(workout: HKWorkout) {
        self.id = "hk-\(workout.uuid.uuidString)"
        self.date = workout.startDate
        self.distanceKm = (workout.totalDistance?.doubleValue(for: .meter()) ?? 0) / 1000
        self.duration = workout.duration
        self.calories = workout.totalEnergyBurned.map { Int($0.doubleValue(for: .kilocalorie())) }
        self.source = workout.sourceRevision.source.name
        self.sourceBundleID = workout.sourceRevision.source.bundleIdentifier
        self.workout = workout
    }

    init(id: String, date: Date, distanceKm: Double, duration: TimeInterval, calories: Int? = nil, source: String? = nil, sourceBundleID: String? = nil) {
        self.id = id
        self.date = date
        self.distanceKm = distanceKm
        self.duration = duration
        self.calories = calories
        self.source = source
        self.sourceBundleID = sourceBundleID
        self.workout = nil
    }

    /// 非系统写入的记录：旧版咕咕或第三方 App 写进健康的，数据质量不可控，
    /// 最佳成绩不参与计算，列表里单独标出来提醒用户可以清理
    var isLegacySource: Bool {
        guard let bundle = sourceBundleID else { return false }
        return !bundle.hasPrefix("com.apple.health")
    }

    /// 标记文案：旧版咕咕写得明明白白，其它第三方写来源名
    var legacyBadge: String? {
        guard isLegacySource else { return nil }
        return sourceBundleID == "coucou" ? "旧版咕咕写入" : "\(source ?? "第三方")写入"
    }

    /// 均速：距离 / 有效时长
    var avgSpeedKmh: Double {
        duration > 5 ? distanceKm / (duration / 3600) : 0
    }

    static func == (l: RideItem, r: RideItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// 启动参数：截图与冒烟需要直达某个 tab（-startTab 1 落到个人纪录）
enum LaunchOptions {
    static var startTab: Int { startTab(from: ProcessInfo.processInfo.arguments) }

    static func startTab(from arguments: [String]) -> Int {
        guard let i = arguments.firstIndex(of: "-startTab"),
              i + 1 < arguments.count,
              let value = Int(arguments[i + 1]), (0...1).contains(value)
        else { return 0 }
        return value
    }
}

/// 截图与演示用：-demoData 启动时造一批虚构骑行。
/// 只存在于内存，不写健康、不写磁盘。
enum DemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoData")
    }

    static func items() -> [RideItem] {
        let specs: [(daysAgo: Int, hour: Int, km: Double, mins: Int, kcal: Int)] = [
            (0, 8, 18.4, 47, 322), (2, 7, 12.6, 33, 215), (4, 18, 25.3, 66, 458),
            (6, 9, 31.8, 82, 590), (8, 7, 9.7, 26, 168), (11, 19, 22.5, 58, 402),
            (14, 8, 16.9, 43, 295), (17, 7, 28.1, 72, 516), (21, 9, 14.2, 37, 247),
            (26, 8, 35.6, 92, 668), (33, 7, 19.8, 50, 348), (41, 18, 11.3, 29, 194),
            (48, 8, 24.7, 64, 446), (55, 9, 30.2, 78, 558),
        ]
        let cal = Calendar.current
        return specs.enumerated().compactMap { index, s in
            guard let day = cal.date(byAdding: .day, value: -s.daysAgo, to: Date()),
                  let start = cal.date(bySettingHour: s.hour, minute: (index * 7) % 45 + 5, second: 0, of: day)
            else { return nil }
            return RideItem(id: "demo-\(index)",
                            date: start,
                            distanceKm: s.km,
                            duration: TimeInterval(s.mins * 60),
                            calories: s.kcal,
                            source: "Apple Watch")
        }
    }
}
