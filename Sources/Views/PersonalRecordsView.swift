import SwiftUI

/// 个人纪录页（第二个 tab）：只干一件事，用数字把人推着往前走。
/// 先看你最好的那几次骑行，再看比过去强了多少。数字要大，差值要一眼看见。
struct PersonalRecordsView: View {
    let items: [RideItem]
    let loading: Bool
    let bests: EffortScanner.Bests
    let scanning: Bool

    private var insights: RideInsights { RideInsights(items: items) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !items.isEmpty {
                        recordCard
                        comparisonCard
                    } else if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取苹果健康…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .padding(.top, 8)
                    } else {
                        Text("还没有骑行记录。骑完第一趟，这一页就会开始记你的纪录。")
                            .font(.footnote)
                            .foregroundStyle(.gray)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .navigationTitle("个人纪录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    // MARK: - 个人纪录

    /// 纪录卡：最长单次、最快均速、最快 5 公里、最快 1 公里、最长用时、单月最多
    private var tiles: [RideInsights.Record] {
        var out = insights.records()
        let efforts = [
            effortTile("最快 5 公里", bests.fiveKm),
            effortTile("最快 1 公里", bests.oneKm),
        ]
        out.insert(contentsOf: efforts, at: min(2, out.count))
        return out
    }

    /// 最佳成绩要翻每趟骑行的距离序列才算得出来，没算完、没有轨迹都如实写出来，不编数字
    private func effortTile(_ label: String, _ effort: BestEffort?) -> RideInsights.Record {
        if let effort {
            return RideInsights.Record(label: label,
                                       value: String(format: "%.1f km/h", effort.speedKmh),
                                       detail: RideInsights.shortDay(effort.date))
        }
        return RideInsights.Record(label: label, value: "—", detail: scanning ? "正在计算" : "需要轨迹数据")
    }

    private var recordCard: some View {
        let records = tiles
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("个人纪录")
                    .font(.headline)
                Text("目前为止最好的几次")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.5))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(records) { r in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(r.label)
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.55))
                        Text(r.value)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(r.detail)
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.45))
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

    // MARK: - 和过去的自己比

    private var comparisonCard: some View {
        let list = insights.comparisons()
        let streak = insights.streak
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Text("和过去的自己比")
                    .font(.headline)
                Spacer()
                if streak.current > 1 {
                    HStack(spacing: 5) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("连续 \(streak.current) 周")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.16))
                    .clipShape(Capsule())
                }
            }

            ForEach(Array(list.enumerated()), id: \.element.id) { index, c in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(c.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(white: 0.65))
                        Spacer()
                        Text(RideInsights.km(c.km))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }

                    comparisonBar(c)

                    HStack(alignment: .center) {
                        Text("\(c.previousTitle) \(RideInsights.km(c.previousKm))")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(white: 0.6))
                        Spacer()
                        deltaBadge(c)
                    }
                }

                if index < list.count - 1 {
                    Divider()
                        .overlay(Color(white: 0.12))
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// 一条对比条：浅色是上一期，橙色是本期，谁长谁短一眼看得出
    private func comparisonBar(_ c: RideInsights.Comparison) -> some View {
        let span = max(c.km, c.previousKm)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.2))
                    .frame(width: span > 0 ? geo.size.width * (c.previousKm / span) : 0)
                Capsule()
                    .fill(Color.orange)
                    .frame(width: span > 0 ? geo.size.width * (c.km / span) : 0)
            }
        }
        .frame(height: 10)
    }

    @ViewBuilder
    private func deltaBadge(_ c: RideInsights.Comparison) -> some View {
        if c.previousKm <= 0.05 {
            badge(c.km > 0.05 ? "\(c.previousTitle)没骑" : "还没开始骑", percent: nil, up: nil)
        } else if abs(c.delta) < 0.05 {
            badge("和\(c.previousTitle)持平", percent: nil, up: nil)
        } else {
            badge(String(format: "%+.1f km", c.delta), percent: c.percent, up: c.delta > 0)
        }
    }

    /// 差值胶囊：涨的填橙、跌的填浅灰，两种情况都用白/黑高对比字，绝不用灰字糊过去
    private func badge(_ text: String, percent: Int?, up: Bool?) -> some View {
        let foreground: Color = up == true ? .black : Color(white: 0.92)
        return HStack(spacing: 5) {
            if let up {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
            }
            Text(text)
            if let percent {
                Text("\(percent > 0 ? "+" : "")\(percent)%")
                    .foregroundStyle(foreground.opacity(0.7))
            }
        }
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(foreground)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(up == true ? Color.orange : Color(white: 0.18))
        .clipShape(Capsule())
    }
}
