import SwiftUI
import HealthKit

struct LogView: View {
    @EnvironmentObject var engine: RideEngine
    @State private var workouts: [HKWorkout] = []
    @State private var exportURLs: [UUID: URL] = [:]
    @State private var workoutToDelete: HKWorkout?
    @State private var deleteFailed = false
    @State private var shareItems: [Any] = []
    @State private var exporting = false
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取苹果健康…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .padding(.top, 20)
                    } else if workouts.isEmpty {
                        Text("暂无骑行记录。若健康里明明有，请到 系统设置 > 隐私与安全 > 健康 > 咕咕骑车 打开读取权限。")
                            .font(.footnote)
                            .foregroundStyle(.gray)
                            .padding(.top, 20)
                    } else {
                        ForEach(workouts, id: \.uuid) { w in
                            NavigationLink(value: w) {
                                workoutCard(w)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    workoutToDelete = w
                                } label: {
                                    Label("删除记录", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Text("导出").font(.headline).padding(.top, 10)
                    Text("每条记录右上角的分享按钮，都可以把这条骑行导出成 Markdown。")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .navigationTitle("记录")
            .navigationDestination(for: HKWorkout.self) { w in
                RideDetailView(workout: w)
            }
            .confirmationDialog("删除这条骑行记录？",
                                isPresented: Binding(get: { workoutToDelete != nil },
                                                     set: { if !$0 { workoutToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let w = workoutToDelete else { return }
                    workoutToDelete = nil
                    Task {
                        let ok = await HealthKitStore.shared.deleteWorkout(w)
                        if ok {
                            exportURLs[w.uuid] = nil
                            workouts = await HealthKitStore.shared.recentWorkouts()
                        } else {
                            deleteFailed = true
                        }
                    }
                }
                Button("取消", role: .cancel) { workoutToDelete = nil }
            } message: {
                Text("会同时从苹果健康中删除，无法恢复。")
            }
            .alert("删除失败，请检查苹果健康授权", isPresented: $deleteFailed) {
                Button("好", role: .cancel) {}
            }
            .sheet(isPresented: Binding(get: { !shareItems.isEmpty },
                                        set: { if !$0 { shareItems = [] } })) {
                ShareSheet(items: shareItems)
            }
            .task { await load() }
        }
    }

    private func workoutCard(_ w: HKWorkout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(w.startDate, format: .dateTime.month().day().weekday())
                    .font(.subheadline).bold()
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        exportFull(w)
                    } label: {
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
            }
            HStack(spacing: 14) {
                Text("\(MeasurementFormatter.km(w.totalDistance))")
                    .font(.title3).bold().monospacedDigit().foregroundStyle(.orange)
                Text(durationString(w.duration))
                if let energy = w.totalEnergyBurned {
                    Text("\(Int(energy.doubleValue(for: .kilocalorie()))) 千卡")
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

    private func durationString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d:%02d", Int(t) / 3600, Int(t) % 3600 / 60, Int(t) % 60)
    }

    // MARK: - 加载与导出

    private func load() async {
        loading = true
        try? await HealthKitStore.shared.requestAuthorization()
        workouts = await HealthKitStore.shared.recentWorkouts()
        loading = false
    }

    /// 全量导出：这条训练在苹果健康里的一切
    private func exportFull(_ w: HKWorkout) {
        exporting = true
        Task {
            let text = await Self.fullMarkdown(for: w)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            let url = FileManager.default.temporaryDirectory
                .appending(path: "咕咕骑车-\(f.string(from: w.startDate)).md")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run {
                exporting = false
                shareItems = [url]
            }
        }
    }

    private static func fullMarkdown(for w: HKWorkout) async -> String {
        let hr = await HealthKitStore.shared.heartRateSamples(for: w)
        let cadence = await HealthKitStore.shared.cadenceSamples(for: w)
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
        - 记录设备: \(w.device?.name ?? "--")

        > 由 咕咕骑行 Coucou Bike 全量导出自苹果健康 · 供人阅读，也供 agent 分析
        """]

        if !hr.isEmpty {
            lines.append("\n## 心率（\(hr.count) 条）\n")
            lines.append("| 时间 | 心率 bpm |\n|---|---|")
            for (date, bpm) in hr {
                lines.append("| \(t.string(from: date)) | \(Int(bpm)) |")
            }
        }
        if !cadence.isEmpty {
            lines.append("\n## 踏频（\(cadence.count) 条）\n")
            lines.append("| 时间 | 踏频 rpm |\n|---|---|")
            for (date, rpm) in cadence {
                lines.append("| \(t.string(from: date)) | \(Int(rpm)) |")
            }
        }
        // 每公里分段：从轨迹累计距离算，配该时段平均心率
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
                lines.append("| 公里 | 用时 | 均速 km/h | 平均心率 |\n|---|---|---|---|")
                var segStartTime = route[0].timestamp
                for (i, sp) in splits.enumerated() {
                    let segEndTime = i + 1 < splits.count ? splits[i+1].seconds : last.timestamp.timeIntervalSince(route[0].timestamp)
                    let segEnd = route[0].timestamp.addingTimeInterval(segEndTime)
                    let speed = sp.seconds > 0 ? 3600.0 / sp.seconds : 0
                    let segHR = hr.filter { $0.0 >= segStartTime && $0.0 <= segEnd }
                    let avg = segHR.isEmpty ? "--" : String(format: "%.0f", segHR.map { $0.1 }.reduce(0, +) / Double(segHR.count))
                    let mm = Int(sp.seconds) / 60, ss = Int(sp.seconds) % 60
                    lines.append(String(format: "| %d | %d:%02d | %.1f | %@ |", sp.km, mm, ss, speed, avg))
                    segStartTime = segEnd
                }
            }
        }
        if !route.isEmpty {
            lines.append("\n## 轨迹（\(route.count) 个点）\n")
            lines.append("| 时间 | 纬度 | 经度 | 海拔 m | 速度 km/h |\n|---|---|---|---|---|")
            for loc in route {
                let speed = max(0, loc.speed) * 3.6
                lines.append(String(format: "| %@ | %.5f | %.5f | %.0f | %.1f |",
                                    t.string(from: loc.timestamp), loc.coordinate.latitude,
                                    loc.coordinate.longitude, loc.altitude, speed))
            }
        }
        return lines.joined(separator: "\n")
    }

}

extension MeasurementFormatter {
    static func km(_ q: HKQuantity?) -> String {
        guard let q else { return "0.0 km" }
        return String(format: "%.1f km", q.doubleValue(for: .meter()) / 1000)
    }
}

import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
