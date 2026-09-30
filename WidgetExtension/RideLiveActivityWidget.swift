import WidgetKit
import SwiftUI
import ActivityKit

@main
struct CoucouWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivityWidget()
    }
}

/// 骑行实时活动：锁屏卡片 + 灵动岛。数据由 App 侧 RideLiveActivity 每秒推送
struct RideLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenRideView(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("距离")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("\(context.state.distanceKm, specifier: "%.2f") km")
                            .font(.headline).fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .padding(.leading, 14)
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("用时")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(Self.timeString(context.state.elapsed))
                            .font(.headline).fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label("\(String(format: "%.1f", context.state.speedKmh)) km/h", systemImage: "speedometer")
                        Spacer()
                        if context.state.paused {
                            Text("已暂停").foregroundStyle(.orange)
                        }
                    }
                    .font(.footnote).monospacedDigit()
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                }
            } compactLeading: {
                Image(systemName: "figure.outdoor.cycle")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                Text("\(String(format: "%.1f", context.state.speedKmh))")
                    .font(.callout).fontWeight(.semibold)
                    .monospacedDigit().foregroundStyle(.orange)
            } minimal: {
                Text("\(String(format: "%.1f", context.state.speedKmh))")
                    .font(.caption).fontWeight(.semibold)
                    .monospacedDigit().foregroundStyle(.orange)
            }
        }
    }

    static func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 锁屏卡片：紧凑三列，系统给锁屏实时活动的高度有限，铺太满会被压缩错乱
/// 内容两侧主动留边：全屏黑色背景下系统默认内边距很小，贴边会被屏幕圆角裁切
struct LockScreenRideView: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "figure.outdoor.cycle")
                    .foregroundStyle(state.paused ? Color.yellow : Color.orange)
                Text(state.paused ? "已暂停" : "骑行中")
                    .foregroundStyle(state.paused ? Color.yellow : Color.white)
                Spacer()
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(Color(white: 0.45))
            }
            .font(.footnote).fontWeight(.semibold)
            .monospacedDigit()

            HStack(alignment: .firstTextBaseline) {
                metric(String(format: "%.1f", state.speedKmh), unit: "km/h", color: .orange)
                Spacer()
                metric(String(format: "%.2f", state.distanceKm), unit: "公里", color: .white)
                Spacer()
                metric(RideLiveActivityWidget.timeString(state.elapsed), unit: "用时", color: .white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func metric(_ value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
