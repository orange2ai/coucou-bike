import SwiftUI
import HealthKit

/// 骑行详情页：点记录页的任意一条进入，结算页同款排版，无撒花
struct RideDetailView: View {
    let workout: HKWorkout

    @State private var avgHr: Double?
    @State private var maxHr: Double?
    @State private var maxSpeedKmh: Double?

    private var distanceKm: Double {
        (workout.totalDistance?.doubleValue(for: .meter()) ?? 0) / 1000
    }

    private var avgSpeedKmh: Double {
        workout.duration > 5 ? distanceKm / (workout.duration / 3600) : 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 8) {
                    Text(workout.startDate, format: .dateTime.month().day().weekday())
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(2)
                    Text(workout.startDate, format: .dateTime.hour().minute())
                        .font(.caption)
                        .tracking(4)
                        .foregroundStyle(.gray)
                }

                // 主角：距离（与结算页同款大数字）
                VStack(spacing: 6) {
                    Text(String(format: "%.2f", distanceKm))
                        .font(.system(size: 96, weight: .ultraLight))
                        .monospacedDigit()
                    Text("公里")
                        .font(.caption)
                        .tracking(6)
                        .foregroundStyle(.gray)
                }
                .padding(.top, 26)

                Spacer()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 26) {
                    summaryStat(timeString(workout.duration), "用时")
                    summaryStat(String(format: "%.1f", avgSpeedKmh), "均速 KM/H")
                    if let maxSpeedKmh {
                        summaryStat(String(format: "%.1f", maxSpeedKmh), "最高速 KM/H")
                    }
                    if let energy = workout.totalEnergyBurned {
                        summaryStat("\(Int(energy.doubleValue(for: .kilocalorie())))", "千卡")
                    }
                    if let avgHr {
                        summaryStat("\(Int(avgHr))", "平均心率")
                    }
                    if let maxHr {
                        summaryStat("\(Int(maxHr))", "最高心率")
                    }
                }
                .padding(.horizontal, 16)

                Text("数据来自苹果健康")
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
        let hr = await HealthKitStore.shared.heartRateSamples(for: workout)
        if !hr.isEmpty {
            avgHr = hr.map { $0.1 }.reduce(0, +) / Double(hr.count)
            maxHr = hr.map { $0.1 }.max()
        }
        let route = await HealthKitStore.shared.routeLocations(for: workout)
        let speeds = route.map { $0.speed }.filter { $0 > 0 }
        if let top = speeds.max() {
            maxSpeedKmh = top * 3.6
        }
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 26, weight: .light))
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
