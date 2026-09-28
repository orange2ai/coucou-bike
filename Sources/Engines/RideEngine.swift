import Foundation
import SwiftUI
import CoreLocation
import UIKit

/// 骑行总引擎：编排 GPS、HealthKit、播报、省电
@MainActor
final class RideEngine: ObservableObject {
    static let shared = RideEngine()

    // MARK: - 发布状态
    @Published var phase: Phase = .idle
    @Published var state = RideState()
    @Published var cues: [CueEvent] = []
    @Published var settings: CueSettings = CueSettings.load()
    @Published var healthAuthorized = false
    @Published var hrAuthDenied = false
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var locationFixCount = 0

    enum Phase { case idle, riding, paused }

    // MARK: - 内部
    private let recorder = LocationRecorder()
    private let pedometer = PedometerSource()
    private var lastGpsKmh = 0.0
    private var lastPedTime: Date?
    private let hk = HealthKitStore.shared
    private var startDate: Date?
    private var pausedAccum: TimeInterval = 0
    private var lastPauseStart: Date?
    private var lastKm = 0
    private var lastKmElapsed: TimeInterval = 0
    private var lastZone: HRZone?
    private let praise = PraisePicker()
    private var isAutoPaused = false
    private var lowSpeedTicks = 0
    private var ticker: Timer?
    // 本公里心率累计（用于“平均心率”播报）
    private var hrSegSum: Double = 0
    private var hrSegCount: Int = 0
    private var routeBuffer: [CLLocation] = []
    // 最后一次收到心率样本的时间：过期回落“未连接”
    private var lastHRDate: Date?
    private var hrNudgeShown = false
    private var locNudgeShown = false
    private var lastAccuracy: Double = 0
    private var lastSystemSpeed: Double = 0
    private var firstFix: CLLocation?
    private var lastKnownLocation: CLLocation?
    private var pedKmhForLog = 0.0
    private var gpsNudgeShown = false
    // 全程心率统计（结算页读）
    private(set) var rideHrSum: Double = 0
    private(set) var rideHrCount = 0
    private(set) var rideMaxHr: Double?
    /// 结束后的结算页开关
    @Published var showSummary = false
    private var lastHRPoll: Date?
    private var hrWatchdog: Timer?
    // 千卡计算用的体重（默认 70kg，startRide 时从健康取最近体重）
    private var bodyMassKg: Double = 70
#if targetEnvironment(simulator)
    private var promoDemoTick = 0
    private var promoDemoEndScheduled = false
#endif

    private var isPromoDemo: Bool {
#if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-promoDemo")
#else
        false
#endif
    }

    private init() {
        recorder.onLocation = { [weak self] loc, kmh, meters in
            self?.absorb(location: loc, speedKmh: kmh, meters: meters)
        }
        pedometer.onSpeed = { [weak self] kmh in
            self?.absorbPedometer(kmh)
        }
        recorder.onAuthorizationChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.locationStatus = status
                self.rideLog("location auth -> \(Self.describe(status))")
                if status == .denied || status == .restricted {
                    self.cue("定位权限被拒绝了，咕咕没法记录骑行。去系统设置里打开定位权限", kind: .lifecycle)
                }
            }
        }
        locationStatus = recorder.authorizationStatus
        // 清理上一场骑行的残留实时活动（App 重启后骑行不会恢复）
        Task { @MainActor in RideLiveActivity.shared.clearStale() }
        // App 启动即挂载心率监听：手表在练，设置页随时能看到"已连接"
        // （带调试参数启动时跳过，避免模拟器截图被授权弹窗挡住）
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("-") }) {
            Task { @MainActor in
                try? await hk.requestAuthorization()
            self.healthAuthorized = self.hk.isAvailable
            self.hrAuthDenied = self.hk.heartRateAuthDenied()
            self.hrLog("auth done, available=\(self.hk.isAvailable), denied=\(self.hrAuthDenied)")
            guard self.hk.isAvailable, !self.hrAuthDenied else { return }
            self.hk.startLiveHeartRateObservation { [weak self] bpm, endDate in
                Task { @MainActor in
                    guard let self, Date().timeIntervalSince(endDate) < 60 else { return }
                    self.absorbHeartRate(bpm, source: .healthKit, at: endDate)
                }
            }
            self.startHRWatchdog()
            }
        }
    }

    /// 骑行 MET 分级（Compendium of Physical Activities，按当前速度）
    nonisolated static func met(forKmh kmh: Double) -> Double {
        switch kmh {
        case ..<16.1: return 4.0      // ≤10 mph 休闲骑
        case ..<19.3: return 6.8      // 10–11.9 mph
        case ..<22.5: return 8.0      // 12–13.9 mph
        case ..<25.7: return 10.0     // 14–15.9 mph
        case ..<30.6: return 12.0     // 16–19 mph
        default: return 15.8          // >20 mph 竞速
        }
    }

    static func describe(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "未请求"
        case .restricted: return "受限"
        case .denied: return "被拒绝"
        case .authorizedWhenInUse: return "使用期间"
        case .authorizedAlways: return "始终"
        @unknown default: return "未知"
        }
    }

    /// 骑行链路诊断日志（定位/心率/距离）
    private func rideLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let text = "[\(f.string(from: Date()))] \(line)\n"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "ride_debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            handle.write(text.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 计步器兜底：GPS 被挡住（室内/隧道）时用运动协处理器估算速度
    private func absorbPedometer(_ kmh: Double) {
        guard phase == .riding else { return }
        // GPS 能给速度时以 GPS 为准
        guard lastGpsKmh < 0.6 else { return }
        let now = Date()
        defer { lastPedTime = now }
        guard kmh > 0.6 else { return }
        if kmh > state.maxSpeedKmh { state.maxSpeedKmh = kmh }
        if let prev = lastPedTime {
            let dt = now.timeIntervalSince(prev)
            if dt > 0.2, dt < 10 {
                let meters = kmh / 3.6 * dt
                state.distanceKm += meters / 1000
                hk.addDistanceSample(meters: meters, at: now)
            }
        }
        state.speedKmh = kmh
        pedKmhForLog = kmh
    }

    /// 手动请求定位权限（设置页用）
    func requestLocationPermission() {
        recorder.requestPermission()
    }

    /// 打开系统里本 App 的设置页（权限被拒后引导用户）
    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// 心率链路诊断日志（写入沙盒 Documents，可经 devicectl 拉取）
    private func hrLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let text = "[\(f.string(from: Date()))] \(line)\n"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "hr_debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            handle.write(text.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 心率看门狗：15 秒没有新样本先保留末次值并置灰（手表体能训练暂停/同步延迟也常见），
    /// 120 秒仍无新样本才回落“未连接”。恢复收到新样本后自动回实时。
    private func startHRWatchdog() {
        hrWatchdog?.invalidate()
        hrWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let last = self.lastHRDate {
                    let age = Date().timeIntervalSince(last)
                    if age > 120, self.state.heartRateSource != .none {
                        self.hrLog("watchdog: sample age \(Int(age))s, drop to disconnected")
                        self.state.heartRate = nil
                        self.state.heartRateStale = false
                        self.state.heartRateSource = .none
                    } else if age > 15, !self.state.heartRateStale {
                        self.hrLog("watchdog: sample age \(Int(age))s, mark stale (keep last value)")
                        self.state.heartRateStale = true
                    }
                }
                // 断连期间每 5 秒主动捞一次：中途开手表也能快速连上；12 秒窗口，过期样本绝不冒充实时
                if self.state.heartRateSource == .none, !self.hrAuthDenied,
                   self.lastHRDate == nil || Date().timeIntervalSince(self.lastHRDate!) > 15,
                   self.lastHRPoll == nil || Date().timeIntervalSince(self.lastHRPoll!) > 5 {
                    self.lastHRPoll = Date()
                    Task { [weak self] in
                        if let (date, hr) = await HealthKitStore.shared.latestHeartRate(within: 12) {
                            self?.hrLog("poll hit: bpm=\(Int(hr)), age=\(Int(Date().timeIntervalSince(date)))s")
                            guard let self else { return }
                            self.absorbHeartRate(hr, source: .healthKit, at: date)
                        } else {
                            self?.hrLog("poll miss: no sample within 12s")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 生命周期

    func startRide() {
        guard phase == .idle else { return }
        let now = Date()
        startDate = now
        lastKm = 0
        lastZone = nil
        pausedAccum = 0
        hrNudgeShown = false
        cues.removeAll()
        state = RideState()
        rideHrSum = 0
        rideHrCount = 0
        rideMaxHr = nil
        showSummary = false
#if targetEnvironment(simulator)
        promoDemoTick = 0
        promoDemoEndScheduled = false
#endif

        if !isPromoDemo {
            recorder.requestPermission()   // 必须显式请求，否则系统不弹框、定位收不到点
            recorder.start()
            pedometer.start()
        }
        lastGpsKmh = 0
        lastPedTime = nil
        locationStatus = recorder.authorizationStatus
        locationFixCount = 0
        locNudgeShown = false
        gpsNudgeShown = false
        firstFix = nil
        rideLog("startRide: location auth=\(Self.describe(recorder.authorizationStatus))")
        CueSpeaker.shared.activateSession(mixWithOthers: settings.mixWithAudio)
        if !isPromoDemo {
            cue("已开始记录，咕咕陪你出发", kind: .lifecycle)
        }

        // 屏幕常亮：默认开，可在设置里关（关了也能后台记录与播报）
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        phase = .riding
        if !isPromoDemo {
            RideLiveActivity.shared.start(state: state)
        }
        startTicker()

        // 宣发演示不请求授权、不写入健康；普通骑行仍先授权再启动 workout。
        if !isPromoDemo {
            Task { @MainActor in
                try? await hk.requestAuthorization()
                if let kg = await hk.latestBodyMass(), kg > 25, kg < 250 {
                    bodyMassKg = kg
                }
                self.healthAuthorized = hk.isAvailable
                guard phase != .idle, let s = startDate else { return }
                hk.startWorkout(start: s)
                hk.startLiveHeartRateObservation { [weak self] bpm, endDate in
                    Task { @MainActor in
                        guard let self, Date().timeIntervalSince(endDate) < 90 else { return }
                        self.absorbHeartRate(bpm, source: .healthKit)
                    }
                }
            }
        }
    }

    func pause() {
        guard phase == .riding else { return }
        phase = .paused
        isAutoPaused = false
        lastPauseStart = Date()
        RideLiveActivity.shared.update(state: state, paused: true)
        recorder.stop()
        cue(settings.emotionalValue ? "已暂停。" + PraisePool.pause : "已暂停", kind: .lifecycle)
    }

    /// 低速自动暂停：GPS 保持开启，以便检测重新出发
    private func autoPause() {
        guard phase == .riding else { return }
        phase = .paused
        isAutoPaused = true
        lastPauseStart = Date()
        RideLiveActivity.shared.update(state: state, paused: true)
        cue("已自动暂停，咕咕帮你盯着，动起来就继续", kind: .lifecycle)
    }

    private func autoResume() {
        guard phase == .paused, isAutoPaused else { return }
        pausedAccum += Date().timeIntervalSince(lastPauseStart ?? Date())
        phase = .riding
        isAutoPaused = false
        lowSpeedTicks = 0
        RideLiveActivity.shared.update(state: state, paused: false)
        cue("继续骑行，咕咕盯着呢", kind: .lifecycle)
    }

    func resume() {
        guard phase == .paused else { return }
        pausedAccum += Date().timeIntervalSince(lastPauseStart ?? Date())
        phase = .riding
        isAutoPaused = false
        lowSpeedTicks = 0
        RideLiveActivity.shared.update(state: state, paused: false)
        recorder.start()
        pedometer.start()
        cue("继续骑行", kind: .lifecycle)
    }

    func endRide() {
        guard phase != .idle else { return }
        let end = Date()
        recorder.stop()
        pedometer.stop()
        let start = startDate ?? end.addingTimeInterval(-max(state.elapsed, 1))
        CueSpeaker.shared.deactivateSession()
        stopTicker()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle

        // 一分钟以内的骑行视为测试，不写入健康，也不弹结算页
        if state.elapsed < 60 {
            RideLiveActivity.shared.end(state: state)
            hk.discardWorkout()
            routeBuffer.removeAll()
            cue("骑了不到一分钟，咕咕当你在测试，没有记录", kind: .lifecycle)
            return
        }

        state.averageSpeedKmh = state.elapsed > 5 ? state.distanceKm / (state.elapsed / 3600) : 0
        RideLiveActivity.shared.end(state: state)
        showSummary = true

        // 宣发模式只展示结算，不碰 HealthKit/轨迹/能量写入。
        if isPromoDemo {
            routeBuffer.removeAll()
            return
        }

        // 千卡用骑行中按秒积分的结果（MET×体重），不再用固定 9.8 kcal/min 粗估
        if state.calories > 0.5 {
            hk.addEnergySample(kcal: state.calories, start: start, end: end)
        }
        let buffered = routeBuffer
        routeBuffer.removeAll()
        Task { @MainActor in
            self.hk.addRouteLocations(buffered)
            self.hk.endWorkout(end: end) { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    if ok {
                        var text = "骑行结束，数据已写入苹果健康"
                        if self.settings.emotionalValue {
                            text += "。" + PraisePool.finish(distanceKm: self.state.distanceKm)
                        }
                        self.cue(text, kind: .lifecycle)
                    } else {
                        self.cue("骑行结束，但健康写入未完成，请检查健康授权", kind: .lifecycle)
                    }
                }
            }
        }
        // 保留 cues 供结束页展示；新骑行时清空
    }

    // MARK: - 定时器

    private func startTicker() {
        ticker?.invalidate()
        let interval: TimeInterval = isPromoDemo ? 0.6 : 1.0
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard phase == .riding, let start = startDate else { return }
#if targetEnvironment(simulator)
        if isPromoDemo {
            tickPromoDemo()
            return
        }
#endif
        state.elapsed = Date().timeIntervalSince(start) - pausedAccum
        state.averageSpeedKmh = state.elapsed > 5 ? state.distanceKm / (state.elapsed / 3600) : 0
        // 千卡：MET 分级 × 体重，按秒积分（暂停/自动暂停不计时，与骑行用时一致）
        state.calories += Self.met(forKmh: state.speedKmh) * 3.5 * bodyMassKg / 200 / 60
        RideLiveActivity.shared.update(state: state, paused: false)

        // 低速自动暂停：连续 3 秒低于 1 km/h
        if settings.autoPause {
            if state.speedKmh < 1 {
                lowSpeedTicks += 1
                if lowSpeedTicks >= 3 {
                    lowSpeedTicks = 0
                    autoPause()
                    return
                }
            } else {
                lowSpeedTicks = 0
            }
        }

        // 模拟器演示模式：GPS 不会移动，注入合成数据让播报可测（60 倍速）
        #if targetEnvironment(simulator)
        if let s = startDate {
            let t = Date().timeIntervalSince(s)
            state.speedKmh = max(4, 23 + sin(t / 7) * 6 + sin(t / 2.3) * 2.5)
            state.distanceKm += state.speedKmh / 3600 * 60
            let hr = min(172, max(98, (state.heartRate ?? 118) + Double.random(in: -2...2.4)))
            absorbHeartRate(hr, source: .healthKit)
        }
        #endif

        // 骑行 20 秒还没有任何定位点：权限或 GPS 有问题，直接说
        if !locNudgeShown, state.elapsed > 20, locationFixCount == 0 {
            locNudgeShown = true
            let status = Self.describe(recorder.authorizationStatus)
            rideLog("no fix after 20s, auth=\(status)")
            if recorder.authorizationStatus == .notDetermined || recorder.authorizationStatus == .denied {
                cue("定位权限没开，咕咕记不了速度。请在系统设置里允许咕咕骑车使用定位", kind: .lifecycle)
            } else {
                cue("还没收到定位信号，到空旷处试试", kind: .lifecycle)
            }
        }

        // 每 30 秒写一次骑行诊断（moved = 相对首点位移，能直接看出位置是否被钉死）
        if Int(state.elapsed) % 30 == 0 {
            let moved = (firstFix.map { first -> Double in
                guard let last = lastKnownLocation else { return 0 }
                return first.distance(from: last)
            }) ?? 0
            rideLog("t=\(Int(state.elapsed))s fixes=\(locationFixCount) dist=\(String(format: "%.2f", state.distanceKm))km speed=\(String(format: "%.1f", state.speedKmh)) acc=\(Int(lastAccuracy))m sysSpeed=\(String(format: "%.1f", lastSystemSpeed)) moved=\(Int(moved))m ped=\(String(format: "%.1f", pedKmhForLog)) hr=\(state.heartRateSource == .none ? "无" : "\(Int(state.heartRate ?? 0))")")
        }

        // 60 秒了位置几乎没挪：不是没权限，是 GPS 被挡了（室内 Wi-Fi 定位感知不到米级移动）
        if !gpsNudgeShown, state.elapsed > 60, locationFixCount > 5,
           state.distanceKm < 0.02,
           (firstFix.map { first -> Bool in
                guard let last = lastKnownLocation else { return false }
                return first.distance(from: last) < 20
            }) ?? false {
            gpsNudgeShown = true
            rideLog("gps weak: moved<20m after 60s, likely indoors")
            cue("GPS 信号很弱，咕咕可能被墙挡住了。到空旷处或窗边试试", kind: .lifecycle)
        }

        // 骑行 30 秒仍无心率：主动说一次，别让用户对着“—”发呆
        if !hrNudgeShown, state.elapsed > 30, state.heartRateSource == .none {
            hrNudgeShown = true
            if hrAuthDenied {
                cue("健康读取权限没开，心率进不来。去系统设置，隐私与安全，健康里打开咕咕骑车", kind: .lifecycle)
            } else {
                cue("咕咕还没听到心率，确认手表体能训练已经在跑", kind: .lifecycle)
            }
        }

        // 心率兜底源：定时从 HealthKit 捞最新心率（仅在实时观察未生效时使用）
        if state.heartRateSource == .none {
            Task { [weak self] in
                guard let (date, hr) = await HealthKitStore.shared.latestHeartRate(within: 12) else { return }
                guard let self else { return }
                self.absorbHeartRate(hr, source: .healthKit, at: date)
            }
        }

        checkTriggers()
    }

#if targetEnvironment(simulator)
    /// 宣发视频专用：8 个模拟 tick = 30 分钟/10 公里，约 8 秒走完整趟。
    private func tickPromoDemo() {
        promoDemoTick += 1
        let ticks = min(promoDemoTick, 8)
        state.elapsed = Double(ticks) * 225          // 每个现实秒模拟 3分45秒
        state.distanceKm = min(Double(ticks) * 1.25, 10)
        state.speedKmh = 19 + sin(Double(ticks) * 0.7) * 4
        state.maxSpeedKmh = max(state.maxSpeedKmh, state.speedKmh)
        state.averageSpeedKmh = 20
        state.calories = 9.8 * state.elapsed / 60
        absorbHeartRate(145 + sin(Double(ticks) * 0.5) * 3, source: .healthKit)

        if ticks == 4 {
            cue("已经骑行 5 公里，最近一公里平均速度 20 公里", kind: .kmSplit)
        }
        if ticks == 8, !promoDemoEndScheduled {
            promoDemoEndScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.endRide()
            }
        }
    }
#endif

    // MARK: - 数据吸收

    private func absorb(location: CLLocation, speedKmh: Double, meters: Double) {
        locationFixCount += 1
        lastGpsKmh = speedKmh
        lastAccuracy = location.horizontalAccuracy
        lastSystemSpeed = location.speed
        lastKnownLocation = location
        if firstFix == nil { firstFix = location }
        if locationFixCount == 1 {
            rideLog("first fix: \(String(format: "%.5f,%.5f", location.coordinate.latitude, location.coordinate.longitude)) acc=\(Int(location.horizontalAccuracy))m sysSpeed=\(String(format: "%.2f", location.speed)) sysAcc=\(String(format: "%.2f", location.speedAccuracy))")
        }
        // 自动暂停状态下继续监听位置，速度起来就自动继续
        if phase == .paused {
            if isAutoPaused, speedKmh > 3 {
                autoResume()
            }
            return
        }
        guard phase == .riding else { return }
        state.speedKmh = speedKmh
        if speedKmh > state.maxSpeedKmh { state.maxSpeedKmh = speedKmh }
        if meters > 0 {
            state.distanceKm += meters / 1000
            hk.addDistanceSample(meters: meters, at: location.timestamp)
        }
        state.elevationM = location.altitude
        if location.horizontalAccuracy < 30 {
            routeBuffer.append(location)
            if routeBuffer.count >= 10 {
                hk.addRouteLocations(routeBuffer)
                routeBuffer.removeAll()
            }
        }
    }


    func absorbHeartRate(_ bpm: Double, source: HeartRateSource, at date: Date = Date()) {
        lastHRDate = date
        state.heartRate = bpm
        state.heartRateSource = source
        state.heartRateStale = Date().timeIntervalSince(date) > 15
        guard phase == .riding else { return }
        hrSegSum += bpm
        hrSegCount += 1
        rideHrSum += bpm
        rideHrCount += 1
        rideMaxHr = max(rideMaxHr ?? 0, bpm)
    }

    // MARK: - 触发器

    private func checkTriggers() {
        let avg = state.averageSpeedKmh

        // 每公里
        if settings.perKilometer {
            let km = Int(state.distanceKm)
            if km > lastKm {
                lastKm = km
                let split = state.elapsed - lastKmElapsed
                lastKmElapsed = state.elapsed
                let splitSpeed = split > 1 ? 3600 / split : state.speedKmh
                let avgHR = hrSegCount > 0 ? hrSegSum / Double(hrSegCount) : state.heartRate
                let hrText = avgHR.map { "，平均心率 \(Int($0))" } ?? ""
                hrSegSum = 0
                hrSegCount = 0
                var text = "已经骑行 \(km) 公里，最近一公里平均速度 \(Int(splitSpeed)) 公里\(hrText)"
                // 情绪价值：报完正事，三成概率补一句歪嘴夸夸
                if settings.emotionalValue, Double.random(in: 0..<1) < 0.35,
                   let line = praise.pick(from: PraisePool.perKilometer) {
                    text += " " + line
                }
                cue(text, kind: .kmSplit)
            }
        }

        // 心率区间
        if settings.hrZoneAlert, let hr = state.heartRate {
            let z = HRZone(heartRate: hr)
            if let last = lastZone, z != last {
                var text = "心率进入\(z.name)，当前 \(Int(hr))"
                if settings.emotionalValue, z.rawValue > last.rawValue,
                   let line = praise.pick(from: PraisePool.highHeartRate) {
                    text += " " + line
                }
                cue(text, kind: .hrZone)
            }
            lastZone = z
        }
    }

    // MARK: - 播报

    private func cue(_ text: String, kind: CueEvent.CueKind) {
        let event = CueEvent(id: UUID(), date: Date(), text: text, kind: kind)
        cues.insert(event, at: 0)
        if cues.count > 100 { cues.removeLast() }
        CueSpeaker.shared.speak(text)
    }

    // MARK: - 省电策略：OLED 纯黑即熄灭，骑行页始终 100% 黑底，无需暗屏与亮屏机制

    func saveSettings() {
        settings.save()
    }

    func exportLatestRideMarkdown() -> String {
        let date = startDate ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let distStr = String(format: "%.2f", state.distanceKm)
        let avgStr = String(format: "%.1f", state.averageSpeedKmh)
        let hrStr = state.heartRate.map { " · 最新 \(Int($0)) bpm" } ?? ""
        var lines = [
            "# 骑行 · \(formatter.string(from: date))",
            "",
            "- 距离: \(distStr) km",
            "- 用时: \(Int(state.elapsed / 60)) 分钟",
            "- 平均速度: \(avgStr) km/h",
            "- 心率源: \(state.heartRateSource.rawValue)\(hrStr)",
            "- 播报记录: \(cues.count) 条",
            "",
            "> 由 咕咕骑车 Coucou Bike 导出 · 供人阅读，也供 agent 分析",
        ]
        for c in cues.reversed() {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            lines.append("- [\(f.string(from: c.date))] \(c.text)")
        }
        return lines.joined(separator: "\n")
    }
}
