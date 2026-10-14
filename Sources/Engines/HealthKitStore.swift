import Foundation
import CoreLocation
import HealthKit

/// HealthKit 只读：骑行记录的来源是手表/手机写入健康的历史训练，咕咕只读不写
/// 保证 continuation 只被 resume 一次（HealthKit 回调可能多次到达）
private final class ResumeOnce {
    private let lock = NSLock()
    private var fired = false
    func run(_ body: () -> Void) {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        lock.unlock()
        body()
    }
}

final class HealthKitStore {
    static let shared = HealthKitStore()
    private let store = HKHealthStore()

    private init() {}

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 是否已经向用户请求过读取权限（用于设置页显示状态）
    func hasRequestedRead() async -> Bool {
        guard isAvailable else { return false }
        let read: Set<HKObjectType> = [HKObjectType.workoutType()]
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: read)
        return status == .unnecessary
    }

    /// 只请求读取权限，绝不写入
    func requestAuthorization() async throws {
        guard isAvailable else { return }
        let toRead: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        try await store.requestAuthorization(toShare: [], read: toRead)
    }

    /// 某次体能训练期间的平均心率
    func averageHeartRate(for workout: HKWorkout) async -> Double? {
        let samples = await heartRateSamples(for: workout)
        guard !samples.isEmpty else { return nil }
        return samples.map { $0.1 }.reduce(0, +) / Double(samples.count)
    }

    /// 某次体能训练的心率时间序列
    func heartRateSamples(for workout: HKWorkout) async -> [(Date, Double)] {
        guard isAvailable else { return [] }
        let type = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let out = (samples as? [HKQuantitySample])?.map { ($0.endDate, $0.quantity.doubleValue(for: unit)) } ?? []
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// 某次体能训练的 GPS 轨迹逐点
    func routeLocations(for workout: HKWorkout) async -> [CLLocation] {
        guard isAvailable else { return [] }
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                  predicate: HKQuery.predicateForObjects(from: workout),
                                  limit: 1, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }
            store.execute(q)
        }
        guard let route = routes.first else { return [] }
        return await withCheckedContinuation { cont in
            var acc: [CLLocation] = []
            let once = ResumeOnce()
            let q = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                acc.append(contentsOf: locations ?? [])
                if done || error != nil {
                    once.run { cont.resume(returning: acc) }
                }
            }
            store.execute(q)
        }
    }

    // MARK: - 最佳一段

    /// 某次训练的距离累计序列（时间升序、累计米），用来算最快的一段
    /// 优先用健康里记录的距离采样（手表/手机在训练期间写入，够密），采样太稀才回退到 GPS 轨迹
    func distanceSeries(for workout: HKWorkout) async -> [(date: Date, meters: Double)] {
        let samples = await distanceSamples(for: workout)
        if samples.count >= 10 { return samples }
        return Self.cumulative(from: await routeLocations(for: workout))
    }

    private func distanceSamples(for workout: HKWorkout) async -> [(date: Date, meters: Double)] {
        guard isAvailable else { return [] }
        let type = HKQuantityType(.distanceCycling)
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                var total = 0.0
                var out: [(Date, Double)] = []
                for s in (samples as? [HKQuantitySample]) ?? [] {
                    total += s.quantity.doubleValue(for: .meter())
                    out.append((s.endDate, total))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// 轨迹点累计距离。定位精度差的点直接丢掉，GPS 跳点会造出假的高速
    static func cumulative(from route: [CLLocation]) -> [(date: Date, meters: Double)] {
        let usable = route
            .filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 50 }
            .sorted { $0.timestamp < $1.timestamp }
        guard usable.count > 1 else { return [] }

        var total = 0.0
        var out: [(date: Date, meters: Double)] = [(usable[0].timestamp, 0)]
        for i in 1..<usable.count {
            let step = usable[i].distance(from: usable[i - 1])
            guard step.isFinite, step >= 0 else { continue }
            total += step
            out.append((usable[i].timestamp, total))
        }
        return out
    }

    // MARK: - 历史读取

    /// 全部骑行训练（含手表与手机写入的），新的在前
    func recentWorkouts(limit: Int = 500) async -> [HKWorkout] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForWorkouts(with: .cycling)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }
}
