import SwiftUI

/// 骑行详情页：点记录页的任意一条进入，结算页同款排版，无撒花
struct RideDetailView: View {
    let record: RideRecord

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 8) {
                    Text(record.startDate, format: .dateTime.month().day().weekday())
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .tracking(2)
                    Text(record.startDate, format: .dateTime.hour().minute())
                        .font(.caption)
                        .tracking(4)
                        .foregroundStyle(.gray)
                }

                // 主角：距离（与结算页同款大数字）
                VStack(spacing: 6) {
                    Text(String(format: "%.2f", record.distanceKm))
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
                    summaryStat(timeString(record.duration), "用时")
                    summaryStat(String(format: "%.1f", record.avgSpeedKmh), "均速 KM/H")
                    summaryStat(String(format: "%.1f", record.maxSpeedKmh), "最高速 KM/H")
                    summaryStat("\(record.calories)", "千卡")
                    summaryStat("\(Int(record.elevationGainM))", "爬升 M")
                    summaryStat("\(record.route.count)", "轨迹点")
                }
                .padding(.horizontal, 16)

                Text("数据存于本机")
                    .font(.caption2)
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))
                    .padding(.top, 30)
                    .padding(.bottom, 30)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
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
