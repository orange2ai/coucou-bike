import Foundation
import ActivityKit

/// 骑行实时活动管理：随骑行开始/每秒推送/结束即收
/// App 有后台定位保活，骑行中始终存活，本地更新即可，无需推送
@MainActor
final class RideLiveActivity {
    static let shared = RideLiveActivity()

    private var activity: Activity<RideActivityAttributes>?
    private var lastPush = Date.distantPast

    private init() {}

    /// 开始一场骑行的实时活动；顺带清理上一场没被正常结束的残留
    func start(state: RideState) {
        clearStale()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: RideActivityAttributes(),
            content: ActivityContent(state: makeState(state, paused: false), staleDate: nil),
            pushType: nil
        )
    }

    /// 推送最新状态（控频：最多每秒一次）
    func update(state: RideState, paused: Bool) {
        guard let activity else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPush) >= 1 else { return }
        lastPush = now
        let content = ActivityContent(state: makeState(state, paused: paused), staleDate: nil)
        Task { await activity.update(content) }
    }

    /// 骑行结束，立即收掉实时活动
    func end(state: RideState) {
        if let activity {
            let final = ActivityContent(state: makeState(state, paused: false), staleDate: nil)
            Task { await activity.end(final, dismissalPolicy: .immediate) }
        }
        activity = nil
    }

    /// 清掉所有本 App 的实时活动（App 启动时上一场骑行必然已结束）
    func clearStale() {
        for old in Activity<RideActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func makeState(_ s: RideState, paused: Bool) -> RideActivityAttributes.ContentState {
        .init(
            speedKmh: s.speedKmh,
            distanceKm: s.distanceKm,
            elapsed: s.elapsed,
            paused: paused
        )
    }
}
