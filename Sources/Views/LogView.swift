import SwiftUI
import CoreLocation
import HealthKit
import UIKit

/// 记录页（App 首页）：顶部统计区（总里程 + 里程柱状图 + 骑行日历），下面是骑行历史
/// 数据源：苹果健康里的骑行训练，只读
struct LogView: View {
    @State private var items: [RideItem] = []
    @State private var shareItems: [Any] = []
    @State private var exporting = false
    @State private var loading = false

    private var statRides: [(date: Date, km: Double)] {
        items.map { ($0.date, $0.distanceKm) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RideStatsView(rides: statRides)

                    Text("骑行历史")
                        .font(.headline)
                        .padding(.top, 6)

                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取苹果健康…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .padding(.top, 8)
                    } else if items.isEmpty {
                        Text("暂无骑行记录。手表或 iPhone 记录的骑行训练会出现在这里。")
                            .font(.footnote)
                            .foregroundStyle(.gray)
                            .padding(.top, 8)
                    } else {
                        ForEach(items) { item in
                            NavigationLink(value: item) { card(item) }
                                .buttonStyle(.plain)
                        }
                    }

                    Text("导出")
                        .font(.headline)
                        .padding(.top, 10)
                    Text("每条记录右上角的分享按钮，可以把这条骑行连同心率与轨迹导出成 Markdown。")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .navigationTitle("记录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: RideItem.self) { item in
                RideDetailView(item: item)
            }
            .sheet(isPresented: Binding(get: { !shareItems.isEmpty },
                                        set: { if !$0 { shareItems = [] } })) {
                ShareSheet(items: shareItems)
            }
            .task { await load() }
        }
    }

    private func card(_ item: RideItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.date, format: .dateTime.month().day().weekday())
                    .font(.subheadline).bold()
                Spacer()
                if let workout = item.workout {
                    shareButton { export(workout, startDate: item.date) }
                }
            }
            HStack(spacing: 14) {
                Text(String(format: "%.1f km", item.distanceKm))
                    .font(.system(.title3, design: .rounded)).bold()
                    .monospacedDigit().foregroundStyle(.orange)
                Text(durationString(item.duration))
                if let kcal = item.calories {
                    Text("\(kcal) 千卡")
                }
            }
            .font(.caption)
            .foregroundStyle(.gray)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func shareButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if exporting {
                ProgressView().frame(width: 34, height: 34)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(Color(white: 0.12))
                    .clipShape(Circle())
            }
        }
        .disabled(exporting)
    }

    private func durationString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d:%02d", Int(t) / 3600, Int(t) % 3600 / 60, Int(t) % 60)
    }

    // MARK: - 加载与导出

    private func load() async {
        loading = true
        if DemoData.isEnabled {
            // 截图/演示模式不弹健康授权，演示数据只在内存里
            items = DemoData.items()
        } else {
            try? await HealthKitStore.shared.requestAuthorization()
            items = await HealthKitStore.shared.recentWorkouts().map(RideItem.init)
        }
        loading = false
    }

    private func export(_ workout: HKWorkout, startDate: Date) {
        exporting = true
        Task {
            let text = await Self.markdown(for: workout)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            let url = FileManager.default.temporaryDirectory
                .appending(path: "咕咕骑车-\(f.string(from: startDate)).md")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run {
                exporting = false
                shareItems = [url]
            }
        }
    }

    /// 全量导出：基础数据 + 心率序列 + 每公里分段 + 轨迹点
    private static func markdown(for w: HKWorkout) async -> String {
        let hr = await HealthKitStore.shared.heartRateSamples(for: w)
        let route = await HealthKitStore.shared.routeLocations(for: w)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let t = DateFormatter(); t.dateFormat = "HH:mm:ss"

        let km = w.totalDistance.map { String(format: "%.2f", $0.doubleValue(for: .meter()) / 1000) } ?? "--"
        let energy = w.totalEnergyBurned.map { String(format: "%.0f 千卡", $0.doubleValue(for: .kilocalorie())) } ?? "--"
        let avgHR = hr.isEmpty ? nil : hr.map { $0.1 }.reduce(0, +) / Double(hr.count)
        let maxHR = hr.map { $0.1 }.max()
        let elevGain: Double = {
            guard route.count > 1 else { return 0 }
            var gain = 0.0
            for i in 1..<route.count {
                let d = route[i].altitude - route[i-1].altitude
                if d > 0 { gain += d }
            }
            return gain
        }()

        var lines = ["""
        # 骑行 · \(f.string(from: w.startDate))

        - 距离: \(km) km
        - 用时: \(Int(w.duration) / 60) 分钟
        - 消耗: \(energy)
        - 平均心率: \(avgHR.map { String(format: "%.0f bpm", $0) } ?? "--")
        - 最大心率: \(maxHR.map { String(format: "%.0f bpm", $0) } ?? "--")
        - 累计爬升: \(String(format: "%.0f", elevGain)) m
        - 数据来源: \(w.sourceRevision.source.name)

        > 由 咕咕骑车 Coucou Bike 全量导出自苹果健康 · 供人阅读，也供 agent 分析
        """]

        if !hr.isEmpty {
            lines.append("\n## 心率（\(hr.count) 条）\n")
            lines.append("| 时间 | 心率 bpm |\n|---|---|")
            for (date, bpm) in hr {
                lines.append("| \(t.string(from: date)) | \(Int(bpm)) |")
            }
        }
        appendSplitsAndRoute(&lines, route: route, t: t)
        return lines.joined(separator: "\n")
    }

    /// 轨迹每公里分段 + 轨迹点表
    private static func appendSplitsAndRoute(_ lines: inout [String], route: [CLLocation], t: DateFormatter) {
        if route.count > 1 {
            var splits: [(km: Int, seconds: TimeInterval)] = []
            var cum = 0.0
            var kmIndex = 1
            var segStart = route[0].timestamp
            var last = route[0]
            for loc in route.dropFirst() {
                cum += loc.distance(from: last)
                last = loc
                if cum >= Double(kmIndex) * 1000 {
                    splits.append((kmIndex, loc.timestamp.timeIntervalSince(segStart)))
                    kmIndex += 1
                    segStart = loc.timestamp
                }
            }
            if !splits.isEmpty {
                lines.append("\n## 每公里分段\n")
                lines.append("| 公里 | 用时 | 均速 km/h |\n|---|---|---|")
                for sp in splits {
                    let speed = sp.seconds > 0 ? 3600.0 / sp.seconds : 0
                    let mm = Int(sp.seconds) / 60, ss = Int(sp.seconds) % 60
                    lines.append(String(format: "| %d | %d:%02d | %.1f |", sp.km, mm, ss, speed))
                }
            }
        }
        if !route.isEmpty {
            lines.append("\n## 轨迹（\(route.count) 个点）\n")
            lines.append("| 时间 | 纬度 | 经度 | 海拔 m |\n|---|---|---|---|")
            for loc in route {
                lines.append(String(format: "| %@ | %.5f | %.5f | %.0f |",
                                    t.string(from: loc.timestamp), loc.coordinate.latitude,
                                    loc.coordinate.longitude, loc.altitude))
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
