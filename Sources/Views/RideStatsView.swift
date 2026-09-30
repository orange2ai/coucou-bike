import SwiftUI
import Charts

/// 记录页顶部统计区：总里程（保养进度）+ 日/周/月里程柱状图
struct RideStatsView: View {
    /// 健康训练与本地记录合并后的 (日期, 公里) 列表
    let rides: [(date: Date, km: Double)]

    enum Bucket: String, CaseIterable, Identifiable {
        case day = "日"
        case week = "周"
        case month = "月"
        var id: String { rawValue }
    }

    @State private var bucket: Bucket = .day
    @State private var selected: (date: Date, km: Double)?

    private var totalKm: Double { rides.reduce(0) { $0 + $1.km } }
    private var serviceInterval: Double { 1000 }
    private var nextServiceKm: Double { (floor(totalKm / serviceInterval) + 1) * serviceInterval }
    private var remainingKm: Double { max(0, nextServiceKm - totalKm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            odometerCard
            chartCard
            heatmapCard
        }
    }

    // MARK: - 总里程 / 保养

    private var odometerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("总里程")
                    .font(.subheadline).bold()
                Spacer()
                Text(String(format: "%.1f km", totalKm))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.12))
                    let progress = min(1, (totalKm.truncatingRemainder(dividingBy: serviceInterval)) / serviceInterval)
                    Capsule().fill(Color.orange)
                        .frame(width: max(8, geo.size.width * progress))
                        .animation(.easeOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(Int(nextServiceKm)) km 保养")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                Spacer()
                Text(remainingKm < 0.5 ? "该保养了" : String(format: "还剩 %.0f km", remainingKm))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(remainingKm < 50 ? Color.orange : Color(white: 0.55))
            }
        }
        .padding(14)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 柱状图

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("骑行里程")
                    .font(.subheadline).bold()
                Spacer()
                Picker("粒度", selection: $bucket) {
                    ForEach(Bucket.allCases) { b in
                        Text(b.rawValue).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Chart(buckets, id: \.date) { item in
                BarMark(
                    x: .value("时间", item.date, unit: unit),
                    y: .value("公里", item.km)
                )
                .foregroundStyle(item.date == selected?.date ? Color.white : Color.orange)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: unitStride, count: unitCount)) { _ in
                    AxisGridLine().foregroundStyle(Color(white: 0.1))
                    AxisValueLabel(format: axisFormat)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color(white: 0.1))
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    guard let date: Date = proxy.value(atX: value.location.x) else {
                                        selected = nil
                                        return
                                    }
                                    let hit = buckets.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
                                    selected = hit.map { ($0.date, $0.km) }
                                }
                        )
                }
            }
            .frame(height: 150)

            HStack {
                if let selected {
                    Text("\(selected.date, format: bucketDateFormat)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Spacer()
                    Text(String(format: "%.1f km", selected.km))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                } else {
                    Text(bucketHint)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.45))
                    Spacer()
                    Text(String(format: "近段合计 %.0f km", buckets.reduce(0) { $0 + $1.km }))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color(white: 0.45))
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .animation(.easeOut(duration: 0.2), value: selected?.date)
    }

    // MARK: - 骑行日历（GitHub 风格橙点热力图）

    /// 最近 26 周，每天累计里程，颜色深浅按当日里程分四档
    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("骑行日历")
                    .font(.subheadline).bold()
                Spacer()
                HStack(spacing: 3) {
                    Text("少")
                        .font(.caption2).foregroundStyle(Color(white: 0.45))
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(heatmapColor(level, maxKm: dailyMax))
                            .frame(width: 10, height: 10)
                    }
                    Text("多")
                        .font(.caption2).foregroundStyle(Color(white: 0.45))
                }
            }

            Canvas { context, size in
                let weeks = heatmapWeeks
                guard !weeks.isEmpty else { return }
                let labelHeight: CGFloat = 12
                let cell = min(size.width / CGFloat(weeks.count), (size.height - labelHeight) / 7)
                let gap: CGFloat = 2
                let block = cell - gap
                let cal = Calendar.current

                // 月份标签：某列的第一天换了月份就标一次
                var lastMonth = -1
                for (col, weekStart) in weeks.enumerated() {
                    let m = cal.component(.month, from: weekStart)
                    if m != lastMonth {
                        lastMonth = m
                        let x = CGFloat(col) * cell
                        if x + 24 < size.width {
                            context.draw(
                                Text(String(format: "%d月", m))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color(white: 0.4)),
                                at: CGPoint(x: x + 12, y: labelHeight / 2))
                        }
                    }
                }

                for (col, weekStart) in weeks.enumerated() {
                    for row in 0..<7 {
                        guard let day = cal.date(byAdding: .day, value: row, to: weekStart) else { continue }
                        guard day <= Date() else { continue }
                        let km = dailyKm[cal.startOfDay(for: day)] ?? 0
                        let level = heatmapLevel(km, maxKm: dailyMax)
                        let rect = CGRect(x: CGFloat(col) * cell, y: labelHeight + CGFloat(row) * cell,
                                          width: block, height: block)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                     with: .color(heatmapColor(level, maxKm: dailyMax)))
                        if let sel = selected?.date, cal.isDate(sel, inSameDayAs: day) {
                            context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                                           with: .color(.white), lineWidth: 1.5)
                        }
                    }
                }
            }
            .frame(height: 7 * 13 + 12)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let size = heatmapTapSize
                let weeks = heatmapWeeks
                guard !weeks.isEmpty else { return }
                let labelHeight: CGFloat = 12
                let cell = min(size.width / CGFloat(weeks.count), (size.height - labelHeight) / 7)
                let col = Int(location.x / cell)
                let row = Int((location.y - labelHeight) / cell)
                guard row >= 0, row < 7, col >= 0, col < weeks.count else { return }
                let cal = Calendar.current
                guard let day = cal.date(byAdding: .day, value: row, to: weeks[col]), day <= Date() else { return }
                let km = dailyKm[cal.startOfDay(for: day)] ?? 0
                selected = (day, km)
                bucket = .day
            }
            .background(GeometryReader { geo in
                Color.clear.onAppear { heatmapTapSize = geo.size }
                .onChange(of: geo.size) { _, s in heatmapTapSize = s }
            })
        }
        .padding(14)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @State private var heatmapTapSize: CGSize = .zero

    private var dailyKm: [Date: Double] {
        var map: [Date: Double] = [:]
        for r in rides {
            let key = Calendar.current.startOfDay(for: r.date)
            map[key, default: 0] += r.km
        }
        return map
    }

    private var dailyMax: Double {
        dailyKm.values.max() ?? 1
    }

    /// 从本周往回推 26 周，每列一周的起始日（跟随系统 firstWeekday）
    private var heatmapWeeks: [Date] {
        let cal = Calendar.current
        let count = 26
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        return (0..<count).reversed().compactMap {
            cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }
    }

    private func heatmapLevel(_ km: Double, maxKm: Double) -> Int {
        guard km > 0, maxKm > 0 else { return 0 }
        let ratio = km / maxKm
        if ratio > 0.75 { return 4 }
        if ratio > 0.5 { return 3 }
        if ratio > 0.25 { return 2 }
        return 1
    }

    private func heatmapColor(_ level: Int, maxKm: Double) -> Color {
        switch level {
        case 0: return Color(white: 0.13)
        case 1: return Color.orange.opacity(0.3)
        case 2: return Color.orange.opacity(0.5)
        case 3: return Color.orange.opacity(0.75)
        default: return Color.orange
        }
    }

    // MARK: - 分桶

    private var unit: Calendar.Component {
        switch bucket {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private var unitStride: Calendar.Component {
        switch bucket {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private var unitCount: Int {
        switch bucket {
        case .day: return 4
        case .week: return 4
        case .month: return 6
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch bucket {
        case .day: return .dateTime.month(.defaultDigits).day()
        case .week: return .dateTime.month(.defaultDigits).day()
        case .month: return .dateTime.year(.twoDigits).month(.defaultDigits)
        }
    }

    private var bucketDateFormat: Date.FormatStyle {
        switch bucket {
        case .day: return .dateTime.year().month().day().weekday()
        case .week: return .dateTime.year().month().day()
        case .month: return .dateTime.year().month()
        }
    }

    private var bucketHint: String {
        switch bucket {
        case .day: return "每天的距离，点柱子看单日"
        case .week: return "每周的距离，点柱子看单周"
        case .month: return "每月的距离，点柱子看单月"
        }
    }

    /// 最近 N 个时间桶（含 0 的空桶），按所选粒度汇总
    private var buckets: [(date: Date, km: Double)] {
        let cal = Calendar.current
        let now = Date()
        let span: Int
        switch bucket {
        case .day: span = 14
        case .week: span = 12
        case .month: span = 12
        }
        var result: [(Date, Double)] = []
        for i in stride(from: span - 1, through: 0, by: -1) {
            let start: Date
            switch bucket {
            case .day:
                let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -i, to: now)!)
                start = day
            case .week:
                let week = cal.dateInterval(of: .weekOfYear, for: cal.date(byAdding: .weekOfYear, value: -i, to: now)!)!.start
                start = week
            case .month:
                let month = cal.dateInterval(of: .month, for: cal.date(byAdding: .month, value: -i, to: now)!)!.start
                start = month
            }
            result.append((start, 0))
        }
        for r in rides {
            let key: Date
            switch bucket {
            case .day:
                key = cal.startOfDay(for: r.date)
            case .week:
                key = cal.dateInterval(of: .weekOfYear, for: r.date)!.start
            case .month:
                key = cal.dateInterval(of: .month, for: r.date)!.start
            }
            if let idx = result.firstIndex(where: { $0.0 == key }) {
                result[idx].1 += r.km
            }
        }
        return result.map { (date: $0.0, km: $0.1) }
    }
}
