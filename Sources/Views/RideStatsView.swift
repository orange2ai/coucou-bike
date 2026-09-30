import SwiftUI
import Charts

/// 记录页顶部统计区：总里程（保养进度）+ 日/周/月里程柱状图
struct RideStatsView: View {
    let records: [RideRecord]

    enum Bucket: String, CaseIterable, Identifiable {
        case day = "日"
        case week = "周"
        case month = "月"
        var id: String { rawValue }
    }

    @State private var bucket: Bucket = .day
    @State private var selected: (date: Date, km: Double)?

    private var totalKm: Double { records.reduce(0) { $0 + $1.distanceKm } }
    private var serviceInterval: Double { 1000 }
    private var nextServiceKm: Double { (floor(totalKm / serviceInterval) + 1) * serviceInterval }
    private var remainingKm: Double { max(0, nextServiceKm - totalKm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            odometerCard
            chartCard
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
        for r in records {
            let key: Date
            switch bucket {
            case .day:
                key = cal.startOfDay(for: r.startDate)
            case .week:
                key = cal.dateInterval(of: .weekOfYear, for: r.startDate)!.start
            case .month:
                key = cal.dateInterval(of: .month, for: r.startDate)!.start
            }
            if let idx = result.firstIndex(where: { $0.0 == key }) {
                result[idx].1 += r.distanceKm
            }
        }
        return result.map { (date: $0.0, km: $0.1) }
    }
}
