import SwiftUI
import CoreLocation
import HealthKit
import UIKit

/// 记录页：顶部统计（总里程保养卡 + 柱状图），下面历史记录列表
/// 数据源：苹果健康里的骑行训练（手表/手机写入）+ 本机存档（纯手机骑的场次）
struct LogView: View {
    @EnvironmentObject var engine: RideEngine
    @State private var workouts: [HKWorkout] = []
    @State private var localRecords: [RideRecord] = []
    @State private var shareItems: [Any] = []
    @State private var exporting = false
    @State private var loading = false

    /// 合并后的列表项：健康训练 + 本地记录，按日期倒序
    enum Entry: Identifiable, Hashable {
        case health(HKWorkout)
        case local(RideRecord)

        var id: String {
            switch self {
            case .health(let w): return "hk-\(w.uuid.uuidString)"
            case .local(let r): return "local-\(r.id.uuidString)"
            }
        }
        var date: Date {
            switch self {
            case .health(let w): return w.startDate
            case .local(let r): return r.startDate
            }
        }
    }

    private var entries: [Entry] {
        (workouts.map { Entry.health($0) } + localRecords.map { Entry.local($0) })
            .sorted { $0.date > $1.date }
    }

    private var statRides: [(date: Date, km: Double)] {
        workouts.compactMap { w -> (date: Date, km: Double)? in
            guard let meters = w.totalDistance?.doubleValue(for: .meter()) else { return nil }
            return (w.startDate, meters / 1000)
        } + localRecords.map { ($0.startDate, $0.distanceKm) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RideStatsView(rides: statRides)

                    Text("历史记录").font(.headline).padding(.top, 6)

                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取苹果健康…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .padding(.top, 8)
                    } else if entries.isEmpty {
                        Text("暂无骑行记录。手表体能训练或咕咕自己记的骑行都会出现在这里。")
                            .font(.footnote)
                            .foregroundStyle(.gray)
                            .padding(.top, 8)
                    } else {
                        ForEach(entries) { e in
                            entryLink(e)
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
            .navigationDestination(for: Entry.self) { e in
                switch e {
                case .health(let w): RideDetailView(workout: w)
                case .local(let r): LocalRideDetailView(record: r)
                }
            }
            .sheet(isPresented: Binding(get: { !shareItems.isEmpty },
                                        set: { if !$0 { shareItems = [] } })) {
                ShareSheet(items: shareItems)
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func entryLink(_ e: Entry) -> some View {
        switch e {
        case .health(let w):
            NavigationLink(value: e) { healthCard(w) }.buttonStyle(.plain)
        case .local(let r):
            NavigationLink(value: e) { localCard(r) }.buttonStyle(.plain)
        }
    }

    private func healthCard(_ w: HKWorkout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(w.startDate, format: .dateTime.month().day().weekday())
                    .font(.subheadline).bold()
                Spacer()
                shareButton { exportHealth(w) }
            }
            HStack(spacing: 14) {
                Text(String(format: "%.1f km", (w.totalDistance?.doubleValue(for: .meter()) ?? 0) / 1000))
                    .font(.system(.title3, design: .rounded)).bold()
                    .monospacedDigit().foregroundStyle(.orange)
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

    private func localCard(_ r: RideRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.startDate, format: .dateTime.month().day().weekday())
                    .font(.subheadline).bold()
                Text("本机")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(white: 0.12))
                    .foregroundStyle(.gray)
                    .clipShape(Capsule())
                Spacer()
                shareButton { exportLocal(r) }
            }
            HStack(spacing: 14) {
                Text(String(format: "%.1f km", r.distanceKm))
                    .font(.system(.title3, design: .rounded)).bold()
                    .monospacedDigit().foregroundStyle(.orange)
                Text(durationString(r.duration))
                Text("\(r.calories) 千卡")
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
        Self.seedDemoDataIfNeeded()
        try? await HealthKitStore.shared.requestAuthorization()
        workouts = await HealthKitStore.shared.recentWorkouts()
        localRecords = RideArchive.loadAll()
        loading = false
    }

    /// 截图/演示用：-demoData 时往本机存档灌一批虚构骑行（只在空存档时生效）
    private static func seedDemoDataIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-demoData"),
              RideArchive.loadAll().isEmpty else { return }
        let demos: [(daysAgo: Int, hour: Int, km: Double, mins: Int, kcal: Int)] = [
            (0, 8, 18.4, 47, 322), (2, 7, 12.6, 33, 215), (4, 18, 25.3, 66, 458),
            (6, 9, 31.8, 82, 590), (8, 7, 9.7, 26, 168), (11, 19, 22.5, 58, 402),
            (14, 8, 16.9, 43, 295), (17, 7, 28.1, 72, 516), (21, 9, 14.2, 37, 247),
            (26, 8, 35.6, 92, 668), (33, 7, 19.8, 50, 348), (41, 18, 11.3, 29, 194),
            (48, 8, 24.7, 64, 446), (55, 9, 30.2, 78, 558),
        ]
        let cal = Calendar.current
        for d in demos {
            guard let start = cal.date(byAdding: .day, value: -d.daysAgo, to: Date()) else { continue }
            let startFixed = cal.date(bySettingHour: d.hour, minute: Int.random(in: 5...50), second: 0, of: start)!
            let rec = RideRecord(
                startDate: startFixed,
                duration: TimeInterval(d.mins * 60),
                distanceKm: d.km,
                avgSpeedKmh: d.km / (Double(d.mins) / 60),
                maxSpeedKmh: d.km / (Double(d.mins) / 60) + 8,
                calories: d.kcal,
                elevationGainM: Double(Int(d.km * 6)),
                cues: [], route: [])
            RideArchive.save(rec)
        }
    }

    private func exportHealth(_ w: HKWorkout) {
        exporting = true
        Task {
            let text = await Self.healthMarkdown(for: w)
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

    private func exportLocal(_ r: RideRecord) {
        exporting = true
        let text = Self.localMarkdown(for: r)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "咕咕骑车-\(f.string(from: r.startDate)).md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        exporting = false
        shareItems = [url]
    }

    /// 健康训练全量导出：心率 + 轨迹每公里分段
    private static func healthMarkdown(for w: HKWorkout) async -> String {
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
        appendSplitsAndRoute(&lines, route: route, hr: hr, startDate: w.startDate, f: f, t: t)
        return lines.joined(separator: "\n")
    }

    /// 本机记录全量导出
    private static func localMarkdown(for r: RideRecord) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let t = DateFormatter(); t.dateFormat = "HH:mm:ss"

        var lines = ["""
        # 骑行 · \(f.string(from: r.startDate))

        - 距离: \(String(format: "%.2f", r.distanceKm)) km
        - 用时: \(Int(r.duration) / 60) 分钟
        - 平均速度: \(String(format: "%.1f", r.avgSpeedKmh)) km/h
        - 最高速度: \(String(format: "%.1f", r.maxSpeedKmh)) km/h
        - 消耗: \(r.calories) 千卡
        - 累计爬升: \(String(format: "%.0f", r.elevationGainM)) m
        - 数据来源: 本机存档

        > 由 咕咕骑车 Coucou Bike 从本机存档全量导出 · 供人阅读，也供 agent 分析
        """]

        if !r.cues.isEmpty {
            lines.append("\n## 播报记录（\(r.cues.count) 条）\n")
            for c in r.cues {
                lines.append("- [\(t.string(from: c.date))] \(c.text)")
            }
        }
        let route = r.route.map { p in
            CLLocation(coordinate: .init(latitude: p.lat, longitude: p.lon),
                       altitude: p.ele, horizontalAccuracy: 5, verticalAccuracy: 5,
                       timestamp: r.startDate.addingTimeInterval(p.t))
        }
        appendSplitsAndRoute(&lines, route: route, hr: [], startDate: r.startDate, f: f, t: t)
        return lines.joined(separator: "\n")
    }

    /// 轨迹每公里分段 + 轨迹点表（健康与本机导出共用）
    private static func appendSplitsAndRoute(_ lines: inout [String], route: [CLLocation], hr: [(Date, Double)], startDate: Date, f: DateFormatter, t: DateFormatter) {
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

import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
