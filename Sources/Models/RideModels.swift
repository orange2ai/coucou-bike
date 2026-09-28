import Foundation

/// 一次骑行的实时状态
struct RideState {
    var speedKmh: Double = 0          // 当前速度
    var distanceKm: Double = 0        // 距离
    var elapsed: TimeInterval = 0     // 骑行用时（不含暂停）
    var heartRate: Double? = nil      // 实时心率
    var heartRateSource: HeartRateSource = .none
    var heartRateStale: Bool = false  // 心率样本过期（手表体能训练暂停等），保留末次值但置灰
    var averageSpeedKmh: Double = 0
    var maxSpeedKmh: Double = 0
    var calories: Double = 0
    var cadence: Double? = nil        // 踏频（外接传感器，MVP 可空）
    var elevationM: Double = 0
}

/// 心率数据源
enum HeartRateSource: String {
    case none          // 无
    case bluetooth     // 蓝牙心率带 / AirPods Pro 3（实时）
    case watchBridge   // Apple Watch 经心率广播链路（实时）
    case healthKit     // HealthKit 延迟兜底（秒级到几十秒）
}

/// 一条播报记录
struct CueEvent: Identifiable, Codable {
    let id: UUID
    let date: Date
    let text: String
    let kind: CueKind

    enum CueKind: String, Codable {
        case kmSplit       // 每公里
        case interval      // 定时
        case hrZone        // 心率区间
        case anomaly       // 配速异常
        case lifecycle     // 开始 / 暂停 / 结束
    }
}

/// 播报设置（UserDefaults 持久化）
struct CueSettings: Codable, Equatable {
    var perKilometer: Bool = true
    var hrZoneAlert: Bool = true
    var paceAnomaly: Bool = false
    var mixWithAudio: Bool = true      // 混音播放，不暂停音乐
    var emotionalValue: Bool = true    // 情绪价值：歪嘴夸夸
    var autoPause: Bool = true         // 低速自动暂停/继续
    var hrReminder: Bool = true        // GO 时提醒开手表体能训练
    var keepScreenOn: Bool = true      // 骑行中屏幕常亮（可手动关闭）

    static func load() -> CueSettings {
        guard let data = UserDefaults.standard.data(forKey: "cue.settings"),
              let s = try? JSONDecoder().decode(CueSettings.self, from: data) else {
            return CueSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "cue.settings")
        }
    }
}

extension CueSettings {
    // 自定义解码：新增字段在旧存档中不存在时用默认值，避免整体解码失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        perKilometer = try c.decodeIfPresent(Bool.self, forKey: .perKilometer) ?? true
        hrZoneAlert = try c.decodeIfPresent(Bool.self, forKey: .hrZoneAlert) ?? true
        paceAnomaly = try c.decodeIfPresent(Bool.self, forKey: .paceAnomaly) ?? false
        mixWithAudio = try c.decodeIfPresent(Bool.self, forKey: .mixWithAudio) ?? true
        emotionalValue = try c.decodeIfPresent(Bool.self, forKey: .emotionalValue) ?? true
        autoPause = try c.decodeIfPresent(Bool.self, forKey: .autoPause) ?? true
        hrReminder = try c.decodeIfPresent(Bool.self, forKey: .hrReminder) ?? true
        keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? true
    }
}

/// 心率区间（五区制）
enum HRZone: Int, CaseIterable {
    case z1 = 1, z2, z3, z4, z5

    init(heartRate: Double, maxHR: Double = 190) {
        let ratio = heartRate / maxHR
        switch ratio {
        case ..<0.60: self = .z1
        case ..<0.70: self = .z2
        case ..<0.80: self = .z3
        case ..<0.90: self = .z4
        default: self = .z5
        }
    }

    var name: String {
        switch self {
        case .z1: return "热身区 Z1"
        case .z2: return "耐力区 Z2"
        case .z3: return "节奏区 Z3"
        case .z4: return "阈值区 Z4"
        case .z5: return "极限区 Z5"
        }
    }
}
