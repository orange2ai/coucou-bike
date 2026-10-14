import SwiftUI

/// 成长区：累计多少、比过去多了多少、最好的那次是什么样。
/// 回答的是「我在进步吗」这个问题，图表回答的是「什么时候骑的」。
struct RideGrowthView: View {
    let items: [RideItem]

    private var insights: RideInsights { RideInsights(items: items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            totalCard
            comparisonCard
            if !insights.records().isEmpty {
                recordCard
            }
        }
    }

    // MARK: - 累计

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("总里程")
                    .font(.subheadline).bold()
                Spacer()
                Text(String(format: "%.1f km", insights.totalKm))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText())
            }

            HStack(alignment: .top) {
                miniStat("次数", "\(insights.rideCount) 次")
                Spacer()
                miniStat("时长", insights.totalDurationText)
                Spacer()
                miniStat("消耗", insights.totalCaloriesText)
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.12))
                        Capsule().fill(Color.orange)
                            .frame(width: max(8, geo.size.width * min(1, insights.serviceProgress)))
                            .animation(.easeOut(duration: 0.4), value: insights.serviceProgress)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("\(Int(insights.nextServiceKm)) km 保养")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                    Spacer()
                    Text(String(format: "还剩 %.0f km", insights.remainingKm))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(insights.remainingKm < 50 ? Color.orange : Color(white: 0.55))
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.45))
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    // MARK: - 和过去的自己比

    private var comparisonCard: some View {
        let list = insights.comparisons()
        let streak = insights.streak
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("和过去的自己比")
                    .font(.subheadline).bold()
                Spacer()
                if streak.current > 1 {
                    Text("连续 \(streak.current) 周")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }

            ForEach(Array(list.enumerated()), id: \.element.id) { index, c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(c.title)
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.55))
                        Spacer()
                        Text(RideInsights.km(c.km))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(c.previousTitle) \(RideInsights.km(c.previousKm))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color(white: 0.45))
                        Spacer()
                        deltaText(c)
                    }
                }
                if index < list.count - 1 {
                    Divider().overlay(Color(white: 0.12))
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func deltaText(_ c: RideInsights.Comparison) -> some View {
        if c.previousKm <= 0.05 {
            Text(c.km > 0.05 ? "\(c.previousTitle)没骑" : "还没开始骑")
                .font(.caption2)
                .foregroundStyle(Color(white: 0.4))
        } else if abs(c.delta) < 0.05 {
            Text("和\(c.previousTitle)持平")
                .font(.caption2)
                .foregroundStyle(Color(white: 0.4))
        } else {
            HStack(spacing: 6) {
                Text(String(format: "%+.1f km", c.delta))
                if let percent = c.percent {
                    Text("(\(percent > 0 ? "+" : "")\(percent)%)")
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(c.delta > 0 ? Color.orange : Color(white: 0.5))
        }
    }

    // MARK: - 个人纪录

    private var recordCard: some View {
        let records = insights.records()
        return VStack(alignment: .leading, spacing: 12) {
            Text("个人纪录")
                .font(.subheadline).bold()

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(records) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.label)
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.45))
                        Text(r.value)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(r.detail)
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
