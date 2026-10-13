import SwiftUI
import CoreLocation
import HealthKit

/// 骑行详情页：一次骑行的全部数据
/// 心率、最高速、爬升从健康训练里读（只读）；演示数据只有基础字段
struct RideDetailView: View {
    let item: RideItem

    @State private var avgHr: Double?
    @State private var maxHr: Double?
    @State private var maxSpeedKmh: Double?
    @State private var elevationGainM: Double?
    @State private var routePoints = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 8) {
                    Text(item.date, format: .dateTime.month().day().weekday())
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .tracking(2)
                    Text(item.date, format: .dateTime.hour().minute())
                        .font(.caption)
                        .tracking(4)
                        .foregroundStyle(.gray)
                }

                VStack(spacing: 6) {
                    Text(String(format: "%.2f", item.distanceKm))
                        .font(.system(size: 96, weight: .ultraLight, design: .rounded))
                        .monospacedDigit()
                    Text("公里")
                        .font(.caption)
                        .tracking(6)
                        .foregroundStyle(.gray)
                }
                .padding(.top, 26)

                Spacer()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 26) {
                    stat(timeString(item.duration), "用时")
                    stat(String(format: "%.1f", item.avgSpeedKmh), "均速 KM/H")
                    if let maxSpeedKmh {
                        stat(String(format: "%.1f", maxSpeedKmh), "最高速 KM/H")
                    }
                    if let kcal = item.calories {
                        stat("\(kcal)", "千卡")
                    }
                    if let elevationGainM, elevationGainM > 0 {
                        stat("\(Int(elevationGainM))", "爬升 M")
                    }
                    if let avgHr {
                        stat("\(Int(avgHr))", "平均心率")
                    }
                    if let maxHr {
                        stat("\(Int(maxHr))", "最高心率")
                    }
                    if routePoints > 0 {
                        stat("\(routePoints)", "轨迹点")
                    }
                }
                .padding(.horizontal, 16)

                Text(item.source.map { "数据来自苹果健康 · \($0)" } ?? "数据来自苹果健康")
                    .font(.caption2)
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))
                    .padding(.top, 30)
                    .padding(.bottom, 30)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let workout = item.workout else { return }

        let hr = await HealthKitStore.shared.heartRateSamples(for: workout)
        if !hr.isEmpty {
            avgHr = hr.map { $0.1 }.reduce(0, +) / Double(hr.count)
            maxHr = hr.map { $0.1 }.max()
        }

        let route = await HealthKitStore.shared.routeLocations(for: workout)
        routePoints = route.count
        let speeds = route.map { $0.speed }.filter { $0 > 0 }
        if let top = speeds.max() {
            maxSpeedKmh = top * 3.6
        }
        if route.count > 1 {
            var gain = 0.0
            for i in 1..<route.count {
                let d = route[i].altitude - route[i-1].altitude
                if d > 0 { gain += d }
            }
            elevationGainM = gain
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 26, weight: .light, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .tracking(2)
                .foregroundStyle(.gray)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
