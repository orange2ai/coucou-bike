import Foundation
import CoreLocation
import UIKit

/// GPS 记录引擎：速度与距离全部自己算。
/// iOS 的 `location.speed` 在速度无效时经常给 0（而不是 -1），直接取用就会永远显示 0；
/// 而相邻两点的直线距离又会被几米级的定位噪声刷出假里程。
/// 这里用两个一维卡尔曼滤波（东西/南北各一个）把噪声和真实速度分开。
final class LocationRecorder: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    /// 恒速模型卡尔曼：状态 [位置, 速度]，测量噪声取 GPS 精度平方
    private struct Kalman {
        var q: Double = 0.25          // 过程噪声：加速度标准差 m/s²（0.08 时城市起停加速段跟不上，最高速被低估到 ~20km/h）
        var pos: Double?              // 位置（米）
        var v: Double = 0             // 速度（米/秒）
        var pxx = 0.0, pxv = 0.0, pvv = 0.0

        mutating func predict(dt: Double) {
            guard pos != nil, dt > 0 else { return }
            pos! += v * dt
            let pxx2 = pxx + 2 * dt * pxv + dt * dt * pvv + q * q * dt * dt * dt * dt / 4
            let pxv2 = pxv + dt * pvv + q * q * dt * dt * dt / 2
            let pvv2 = pvv + q * q * dt * dt
            pxx = pxx2; pxv = pxv2; pvv = pvv2
        }

        mutating func update(_ z: Double, variance r: Double) {
            guard var p = pos else {
                pos = z; pxx = r; pxv = 0; pvv = 25
                return
            }
            let s = pxx + r
            let k1 = pxx / s
            let k2 = pxv / s
            let res = z - p
            p += k1 * res
            v += k2 * res
            let pxx2 = (1 - k1) * pxx
            let pxv2 = (1 - k1) * pxv
            let pvv2 = pvv - k2 * pxv
            pos = p; pxx = pxx2; pxv = pxv2; pvv = pvv2
        }

        /// 速度估计的 2σ 不确定度：真实速度低于它时，认为车没动
        var significance: Double { 2 * (max(pvv, 0)).squareRoot() }
    }

    private var kx = Kalman()
    private var ky = Kalman()
    private var origin: CLLocationCoordinate2D?
    private var lastFixTime: Date?
    /// 后台定位开关是否已设置（设置过就不用再设）
    private var backgroundModeApplied = false

    /// 新定位点回调（主线程）：位置 + 自己算的速度 km/h + 本次新增距离（米）
    var onLocation: ((CLLocation, Double, Double) -> Void)?
    /// 定位授权状态变化
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness          // 骑行优化
        manager.pausesLocationUpdatesAutomatically = false
        // 后台定位开关延迟到有前台 UI 时再设（applyBackgroundMode）
        // 系统预热/后台拉起进程时设置会触发 CLClientIsBackgroundable 断言闪退
    }

    /// 锁屏/切后台继续记录：when-in-use 授权 + 后台定位模式，系统要求同时显示蓝色指示条。
    /// 只有 App 处于活跃前台时才能设置；预热、后台拉起、devicectl 启动等
    /// 无前台 UI 会话的状态下设置会触发 CLClientIsBackgroundable 断言闪退。
    /// 骑行必经 GO 按钮（此时 App 必为 active），所以不会漏设。
    private func applyBackgroundMode() {
        guard !backgroundModeApplied,
              Thread.isMainThread,
              UIApplication.shared.applicationState == .active else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        backgroundModeApplied = true
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    /// 必须显式请求，否则系统不会弹授权框，定位一个点都收不到
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        reset()
        applyBackgroundMode()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        reset()
    }

    private func reset() {
        kx = Kalman(); ky = Kalman()
        origin = nil
        lastFixTime = nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
        if isAuthorized {
            applyBackgroundMode()
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            // 精度太差（> 80 米）的点直接丢
            guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 80 else { continue }

            if origin == nil { origin = loc.coordinate }
            let (mx, my) = offset(loc.coordinate, from: origin!)
            let variance = max(loc.horizontalAccuracy, 1) * max(loc.horizontalAccuracy, 1)

            let prevTime = lastFixTime
            let dt = prevTime.map { loc.timestamp.timeIntervalSince($0) } ?? 0
            if dt > 0 {
                kx.predict(dt: dt)
                ky.predict(dt: dt)
            }
            kx.update(mx, variance: variance)
            ky.update(my, variance: variance)
            lastFixTime = loc.timestamp

            let speed = hypot(kx.v, ky.v)
            let significance = max(kx.significance, ky.significance)
            var kmh = speed > significance ? speed * 3.6 : 0
            if kmh < 0.6 { kmh = 0 }        // 静止时的残余噪声，归零
            kmh = min(kmh, 90)

            // 距离 = 平滑速度 × 时间
            var meters = 0.0
            if let prev = prevTime, dt > 0.2, dt < 10, kmh > 0.6 {
                meters = kmh / 3.6 * loc.timestamp.timeIntervalSince(prev)
            }

            DispatchQueue.main.async { [weak self] in
                self?.onLocation?(loc, kmh, meters)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[coucou][gps] failed:", error.localizedDescription)
    }

    // MARK: - 坐标转本地平面米（等距圆柱投影，几十公里内足够准）

    private func offset(_ c: CLLocationCoordinate2D, from o: CLLocationCoordinate2D) -> (Double, Double) {
        let r = 6_371_000.0
        let dLat = (c.latitude - o.latitude) * .pi / 180
        let dLon = (c.longitude - o.longitude) * .pi / 180
        return (dLon * r * cos(o.latitude * .pi / 180), dLat * r)
    }
}
