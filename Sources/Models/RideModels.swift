import Foundation

/// 一次骑行的实时状态
struct RideState {
    var speedKmh: Double = 0          // 当前速度
    var distanceKm: Double = 0        // 距离
    var elapsed: TimeInterval = 0     // 骑行用时（不含暂停）
    var averageSpeedKmh: Double = 0
    var maxSpeedKmh: Double = 0
    var calories: Double = 0
    var elevationM: Double = 0        // 当前海拔
    var elevationGainM: Double = 0    // 累计爬升
    var recent1kmKmh: Double?         // 最近 1 公里均速
    var recent5kmKmh: Double?         // 最近 5 公里均速
}

/// 一条播报记录
struct CueEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let text: String
    let kind: CueKind

    enum CueKind: String, Codable {
        case kmSplit       // 每公里
        case lifecycle     // 开始 / 暂停 / 结束
    }
}

/// 播报设置（UserDefaults 持久化）
struct CueSettings: Codable, Equatable {
    var perKilometer: Bool = true
    var mixWithAudio: Bool = true      // 混音播放，不暂停音乐
    var emotionalValue: Bool = true    // 情绪价值：歪嘴夸夸
    var autoPause: Bool = true         // 低速自动暂停/继续
    var keepScreenOn: Bool = true      // 骑行中屏幕常亮（可手动关闭）
    var bodyMassKg: Double = 70        // 千卡计算用体重

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
        mixWithAudio = try c.decodeIfPresent(Bool.self, forKey: .mixWithAudio) ?? true
        emotionalValue = try c.decodeIfPresent(Bool.self, forKey: .emotionalValue) ?? true
        autoPause = try c.decodeIfPresent(Bool.self, forKey: .autoPause) ?? true
        keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? true
        bodyMassKg = try c.decodeIfPresent(Double.self, forKey: .bodyMassKg) ?? 70
    }
}

/// 本地骑行记录：一条骑行一个 JSON 文件，数据完全归本机所有
struct RideRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var startDate: Date
    var duration: TimeInterval
    var distanceKm: Double
    var avgSpeedKmh: Double
    var maxSpeedKmh: Double
    var calories: Int
    var elevationGainM: Double
    var cues: [CueEvent] = []
    var route: [RidePoint] = []

    /// 轨迹点：t 为相对骑行开始的秒数
    struct RidePoint: Codable, Hashable {
        var t: TimeInterval
        var lat: Double
        var lon: Double
        var ele: Double
    }

    /// 每公里分段：从轨迹点累计距离算
    var splits: [(km: Int, seconds: TimeInterval)] {
        guard route.count > 1 else { return [] }
        var result: [(Int, TimeInterval)] = []
        var cum = 0.0
        var kmIndex = 1
        var segStart = route[0].t
        var last = route[0]
        for p in route.dropFirst() {
            cum += Self.pointDistance(last, p)
            last = p
            if cum >= Double(kmIndex) * 1000 {
                result.append((kmIndex, p.t - segStart))
                kmIndex += 1
                segStart = p.t
            }
        }
        return result
    }

    static func pointDistance(_ a: RidePoint, _ b: RidePoint) -> Double {
        // 简化测地距离（小范围够用）
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let lat = (a.lat + b.lat) / 2 * .pi / 180
        let x = dLon * cos(lat)
        return 6_371_000 * (dLat * dLat + x * x).squareRoot()
    }
}

/// 本机骑行存档：Documents/Rides/ 下一条骑行一个 JSON
enum RideArchive {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Rides", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ record: RideRecord) {
        let url = dir.appending(path: "ride-\(record.id.uuidString).json")
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadAll() -> [RideRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(RideRecord.self, from: data)
            }
            .sorted { $0.startDate > $1.startDate }
    }

    static func delete(_ record: RideRecord) {
        let url = dir.appending(path: "ride-\(record.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}
