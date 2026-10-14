import Foundation

/// 扫遍所有骑行，找出任意 1 公里与 5 公里窗口里的最快均速。
/// 每趟骑行只算一次：结果按训练 id 缓存在 Caches 目录（派生数据，不是用户数据），
/// 系统清掉缓存也只是重算一遍，不会丢任何东西。
enum EffortScanner {
    struct Bests: Equatable {
        var oneKm: BestEffort?
        var fiveKm: BestEffort?
    }

    /// v3：只认系统来源（com.apple.health.*），旧版咕咕与第三方写的距离不再参与
    private static let cacheVersion = 3

    private struct CacheEntry: Codable {
        var oneKmSpeed: Double?
        var oneKmDate: Date?
        var fiveKmSpeed: Double?
        var fiveKmDate: Date?
    }

    private struct CacheFile: Codable {
        var version: Int
        var entries: [String: CacheEntry]
    }

    /// 边算边回调，回调发生在主线程：先把缓存里已有的值亮出来，后面算出来的更快的再替换
    static func scan(_ items: [RideItem], onUpdate: @MainActor @escaping (Bests) -> Void) async -> Bests {
        if DemoData.isEnabled { return demoBests() }

        var cache = loadCache()
        var current = bests(from: cache)
        await onUpdate(current)

        var changed = false
        for item in items {
            guard let workout = item.workout,
                  cache[item.id] == nil,
                  item.distanceKm >= 1,
                  workout.sourceRevision.source.bundleIdentifier.hasPrefix("com.apple.health")
            else { continue }
            if Task.isCancelled { break }

            var entry = CacheEntry()
            let series = await HealthKitStore.shared.distanceSeries(for: workout)
            if let best = BestEfforts.best(in: series, windowKm: 1) {
                entry.oneKmSpeed = best.speedKmh
                entry.oneKmDate = best.date
            }
            if let best = BestEfforts.best(in: series, windowKm: 5) {
                entry.fiveKmSpeed = best.speedKmh
                entry.fiveKmDate = best.date
            }
            cache[item.id] = entry
            changed = true

            let updated = bests(from: cache)
            if updated != current {
                current = updated
                await onUpdate(current)
            }
        }

        if changed { saveCache(cache) }
        return current
    }

    private static func bests(from cache: [String: CacheEntry]) -> Bests {
        var out = Bests()
        for entry in cache.values {
            if let speed = entry.oneKmSpeed, let date = entry.oneKmDate,
               speed > (out.oneKm?.speedKmh ?? 0) {
                out.oneKm = BestEffort(windowKm: 1, speedKmh: speed, date: date)
            }
            if let speed = entry.fiveKmSpeed, let date = entry.fiveKmDate,
               speed > (out.fiveKm?.speedKmh ?? 0) {
                out.fiveKm = BestEffort(windowKm: 5, speedKmh: speed, date: date)
            }
        }
        return out
    }

    // MARK: - 缓存

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "best-efforts.json")
    }

    private static func loadCache() -> [String: CacheEntry] {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == cacheVersion
        else { return [:] }
        return file.entries
    }

    private static func saveCache(_ entries: [String: CacheEntry]) {
        guard let url = cacheURL,
              let data = try? JSONEncoder().encode(CacheFile(version: cacheVersion, entries: entries))
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 演示

    /// 演示数据没有轨迹，按演示骑行推一组合理的最佳成绩，只用于截图与冒烟
    static func demoBests() -> Bests {
        let rides = DemoData.items()
        var out = Bests()
        if let fastest = rides.max(by: { $0.avgSpeedKmh < $1.avgSpeedKmh }) {
            out.oneKm = BestEffort(windowKm: 1, speedKmh: fastest.avgSpeedKmh * 1.09, date: fastest.date)
        }
        if let longest = rides.filter({ $0.distanceKm >= 5 }).max(by: { $0.distanceKm < $1.distanceKm }) {
            out.fiveKm = BestEffort(windowKm: 5, speedKmh: longest.avgSpeedKmh * 1.05, date: longest.date)
        }
        return out
    }
}
