import Foundation
import SwiftUI
import CoreLocation
import UIKit

/// 骑行总引擎：编排 GPS、播报、省电。数据只落本机，不碰健康
@MainActor
final class RideEngine: ObservableObject {
    static let shared = RideEngine()

    // MARK: - 发布状态
    @Published var phase: Phase = .idle
    @Published var state = RideState()
    @Published var cues: [CueEvent] = []
    @Published var settings: CueSettings = CueSettings.load()
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var locationFixCount = 0

    enum Phase { case idle, riding, paused }

    // MARK: - 内部
    private let recorder = LocationRecorder()
    private let pedometer = PedometerSource()
    private var lastGpsKmh = 0.0
    private var lastPedTime: Date?
    private var startDate: Date?
    private var pausedAccum: TimeInterval = 0
    private var lastPauseStart: Date?
    private var lastKm = 0
    private var lastKmElapsed: TimeInterval = 0
    private let praise = PraisePicker()
    private var isAutoPaused = false
    private var lowSpeedTicks = 0
    private var ticker: Timer?
    private var routeBuffer: [RideRecord.RidePoint] = []
    // 滚动均速采样：(用时秒, 累计公里)，每秒一个点
    private var rollSamples: [(t: TimeInterval, d: Double)] = []
    private var locNudgeShown = false
    private var lastAccuracy: Double = 0
    private var lastSystemSpeed: Double = 0
    private var firstFix: CLLocation?
    private var lastKnownLocation: CLLocation?
    private var pedKmhForLog = 0.0
    private var gpsNudgeShown = false
    private var lastElevation: Double?
    /// 结束后的结算页开关
    @Published var showSummary = false
    private var rideStart = Date()
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

    /// 骑行链路诊断日志（定位/距离）
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

    // MARK: - 生命周期

    func startRide() {
        guard phase == .idle else { return }
        let now = Date()
        startDate = now
        rideStart = now
        lastKm = 0
        pausedAccum = 0
        cues.removeAll()
        state = RideState()
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
        lastElevation = nil
        routeBuffer.removeAll()
        rollSamples.removeAll()
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

        // 一分钟以内的骑行视为测试，不存档，也不弹结算页
        if state.elapsed < 60 {
            RideLiveActivity.shared.end(state: state)
            routeBuffer.removeAll()
            cue("骑了不到一分钟，咕咕当你在测试，没有记录", kind: .lifecycle)
            return
        }

        state.averageSpeedKmh = state.elapsed > 5 ? state.distanceKm / (state.elapsed / 3600) : 0
        RideLiveActivity.shared.end(state: state)
        showSummary = true

        // 宣发模式只展示结算，不存档
        if isPromoDemo {
            routeBuffer.removeAll()
            return
        }

        // 存档：一条骑行一个 JSON，数据完全归本机
        let record = RideRecord(
            startDate: start,
            duration: state.elapsed,
            distanceKm: state.distanceKm,
            avgSpeedKmh: state.averageSpeedKmh,
            maxSpeedKmh: state.maxSpeedKmh,
            calories: Int(state.calories),
            elevationGainM: state.elevationGainM,
            cues: Array(cues.reversed()),
            route: routeBuffer
        )
        routeBuffer.removeAll()
        RideArchive.save(record)

        var text = "骑行结束，记录已存好"
        if settings.emotionalValue {
            text += "。" + PraisePool.finish(distanceKm: state.distanceKm)
        }
        cue(text, kind: .lifecycle)
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
        state.calories += Self.met(forKmh: state.speedKmh) * 3.5 * settings.bodyMassKg / 200 / 60
        // 滚动均速：最近 1 / 5 公里
        rollSamples.append((state.elapsed, state.distanceKm))
        state.recent1kmKmh = rollingSpeedKmh(lastKm: 1)
        state.recent5kmKmh = rollingSpeedKmh(lastKm: 5)
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
            rideLog("t=\(Int(state.elapsed))s fixes=\(locationFixCount) dist=\(String(format: "%.2f", state.distanceKm))km speed=\(String(format: "%.1f", state.speedKmh)) acc=\(Int(lastAccuracy))m sysSpeed=\(String(format: "%.1f", lastSystemSpeed)) moved=\(Int(moved))m ped=\(String(format: "%.1f", pedKmhForLog))")
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
        // 累计爬升：海拔上升才计
        if location.verticalAccuracy > 0 {
            if let lastEle = lastElevation, location.altitude - lastEle > 0, location.altitude - lastEle < 50 {
                state.elevationGainM += location.altitude - lastEle
            }
            lastElevation = location.altitude
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
        }
        state.elevationM = location.altitude
        if location.horizontalAccuracy < 30 {
            let p = RideRecord.RidePoint(
                t: location.timestamp.timeIntervalSince(rideStart),
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                ele: location.altitude
            )
            routeBuffer.append(p)
        }
    }

    // MARK: - 触发器

    /// 最近 lastKm 公里的均速：用距离-时间采样回溯该距离前的时刻
    private func rollingSpeedKmh(lastKm: Double) -> Double? {
        guard let last = rollSamples.last, last.d >= lastKm else { return nil }
        let targetD = last.d - lastKm
        // 二分找第一个 d >= targetD 的采样点
        var lo = 0, hi = rollSamples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if rollSamples[mid].d >= targetD { hi = mid } else { lo = mid + 1 }
        }
        let dt = last.t - rollSamples[lo].t
        guard dt > 1 else { return nil }
        return lastKm / dt * 3600
    }

    private func checkTriggers() {
        // 每公里
        if settings.perKilometer {
            let km = Int(state.distanceKm)
            if km > lastKm {
                lastKm = km
                let split = state.elapsed - lastKmElapsed
                lastKmElapsed = state.elapsed
                let splitSpeed = split > 1 ? 3600 / split : state.speedKmh
                var text = "已经骑行 \(km) 公里，最近一公里平均速度 \(Int(splitSpeed)) 公里"
                // 情绪价值：报完正事，三成概率补一句歪嘴夸夸
                if settings.emotionalValue, Double.random(in: 0..<1) < 0.35,
                   let line = praise.pick(from: PraisePool.perKilometer) {
                    text += " " + line
                }
                cue(text, kind: .kmSplit)
            }
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
}
