import Foundation
import CoreLocation
import HealthKit

/// HealthKit 读写：训练写入 + 心率读取（延迟兜底）+ 历史查询
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

    private var entitled: Bool {
        // 无 HealthKit 能力的构建（临时测试包）里完全不触碰 HealthKit，避免运行时异常。
        // 注意：Info.plist 经构建处理后布尔可能以字符串形式存在，必须两种都认。
        switch Bundle.main.object(forInfoDictionaryKey: "BIKECUES_HEALTHKIT") {
        case let flag as Bool: return flag
        case let flag as String: return ["yes", "1", "true"].contains(flag.lowercased())
        default: return false
        }
    }

    var isAvailable: Bool { entitled && HKHealthStore.isHealthDataAvailable() }

    /// 用户拒绝了健康读取权限（授权弹窗点了“不允许”）
    func heartRateAuthDenied() -> Bool {
        guard isAvailable else { return false }
        return store.authorizationStatus(for: HKQuantityType(.heartRate)) == .sharingDenied
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        let toShare: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.cyclingCadence),
        ]
        let toRead: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass),
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        try await store.requestAuthorization(toShare: toShare, read: toRead)
    }

    // MARK: - 训练写入（WorkoutBuilder）

    private var builder: HKWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?

    func startWorkout(start: Date) {
        guard isAvailable else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .outdoor
        let b = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        b.beginCollection(withStart: start) { _, _ in }
        builder = b
        // 跟 workout 绑定的路线构建器：workout 结束时自动收尾
        routeBuilder = b.seriesBuilder(for: .workoutRoute()) as? HKWorkoutRouteBuilder
    }

    func addDistanceSample(meters: Double, at date: Date) {
        guard let builder else { return }
        let qty = HKQuantity(unit: .meter(), doubleValue: meters)
        let sample = HKQuantitySample(type: HKQuantityType(.distanceCycling), quantity: qty, start: date, end: date)
        builder.add([sample]) { _, _ in }
    }

    func addHeartRateSample(bpm: Double, at date: Date) {
        guard let builder else { return }
        let qty = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: bpm)
        let sample = HKQuantitySample(type: HKQuantityType(.heartRate), quantity: qty, start: date, end: date)
        builder.add([sample]) { _, _ in }
    }

    func addEnergySample(kcal: Double, start: Date, end: Date) {
        guard let builder else { return }
        let qty = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let sample = HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: qty, start: start, end: end)
        builder.add([sample]) { _, _ in }
    }

    func endWorkout(end: Date, completion: ((Bool) -> Void)? = nil) {
        guard let builder else { completion?(false); return }
        self.builder = nil
        builder.endCollection(withEnd: end) { _, _ in
            builder.finishWorkout { _, error in
                if let error { print("[bikecues] finishWorkout error:", error.localizedDescription) }
                DispatchQueue.main.async { completion?(error == nil) }
            }
        }
    }

    func discardWorkout() {
        builder?.discardWorkout()
        builder = nil
        routeBuilder = nil
    }

    /// 轨迹入库：攒一批点写一次，省事务开销
    func addRouteLocations(_ locations: [CLLocation]) {
        guard let routeBuilder, isAvailable, !locations.isEmpty else { return }
        routeBuilder.insertRouteData(locations) { _, _ in }
    }

    /// 最近一次体重记录（千卡 MET 计算用），无记录返回 nil
    func latestBodyMass() async -> Double? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(.bodyMass)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                let kg = (samples as? [HKQuantitySample])?.first?.quantity.doubleValue(for: .gramUnit(with: .kilo))
                cont.resume(returning: kg)
            }
            store.execute(q)
        }
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

    /// 某次体能训练的踏频时间序列（有则导出，无则空）
    func cadenceSamples(for workout: HKWorkout) async -> [(Date, Double)] {
        guard isAvailable else { return [] }
        let type = HKQuantityType(.cyclingCadence)
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

    // MARK: - 心率读取

    private var hrObserver: HKQuery?
    private var hrAnchor: HKQueryAnchor?

    /// 实时心率观察：手表上跑着任意体能训练时，心率样本约每 5 秒写入 HealthKit，
    /// iPhone 侧用长驻 AnchoredObjectQuery 即可拿到准实时心率，无需手表 App。
    func startLiveHeartRateObservation(handler: @escaping (Double, Date) -> Void) {
        guard isAvailable, hrObserver == nil else { return }
        let type = HKQuantityType(.heartRate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        func process(_ samples: [HKSample]?, anchor: HKQueryAnchor?) {
            hrAnchor = anchor
            for s in samples ?? [] {
                if let hs = s as? HKQuantitySample {
                    let bpm = hs.quantity.doubleValue(for: unit)
                    DispatchQueue.main.async { handler(bpm, hs.endDate) }
                }
            }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: hrAnchor, limit: HKObjectQueryNoLimit) { _, samples, _, newAnchor, _ in
            process(samples, anchor: newAnchor)
        }
        // 关键：长驻更新回调。缺了它查询只跑一次，永远“不实时”。
        q.updateHandler = { _, samples, _, newAnchor, _ in
            process(samples, anchor: newAnchor)
        }
        store.execute(q)
        hrObserver = q
    }

    func stopLiveHeartRateObservation() {
        if let q = hrObserver { store.stop(q) }
        hrObserver = nil
        hrAnchor = nil
    }

    /// 查询最近 N 秒内的心率样本，返回 (样本时间, bpm)；过期样本坚决不冒充实时
    func latestHeartRate(within seconds: TimeInterval = 12) async -> (Date, Double)? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(.heartRate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-seconds), end: nil)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                guard let s = samples?.first as? HKQuantitySample else { cont.resume(returning: nil); return }
                cont.resume(returning: (s.endDate, s.quantity.doubleValue(for: unit)))
            }
            store.execute(q)
        }
    }

    // MARK: - 历史读取

    func recentWorkouts(limit: Int = 20) async -> [HKWorkout] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForWorkouts(with: .cycling)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    // MARK: - 删除

    func deleteWorkout(_ w: HKWorkout) async -> Bool {
        guard isAvailable else { return false }
        return await withCheckedContinuation { cont in
            store.delete([w]) { _, error in
                cont.resume(returning: error == nil)
            }
        }
    }
}
