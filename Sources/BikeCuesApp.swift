import SwiftUI

@main
struct BikeCuesApp: App {
    @StateObject private var engine = RideEngine.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .onAppear {
                    // 启动即清掉上一场没正常结束的实时活动（进程被杀时留下的残影）
                    if engine.phase == .idle {
                        RideLiveActivity.shared.clearStale()
                    }
                    // 调试用：-autoRide 启动即开骑（默认 68 秒后自动收尾，避免测试把定位和实时活动一直挂着）
                    if CommandLine.arguments.contains("-autoRide") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { engine.startRide() }
                        if !CommandLine.arguments.contains("-keepRiding") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 70) { engine.endRide() }
                        }
                    }
                    if CommandLine.arguments.contains("-autoEnd") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 68) { engine.endRide() }
                    }
                    if CommandLine.arguments.contains("-fakeSummary") {
                        engine.state.distanceKm = 12.48
                        engine.state.elapsed = 2452
                        engine.state.averageSpeedKmh = 18.3
                        engine.state.maxSpeedKmh = 34.6
                        engine.state.calories = 412
                        engine.showSummary = true
                    }
                }
        }
    }
}
