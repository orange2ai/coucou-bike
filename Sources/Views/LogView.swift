import SwiftUI
import UIKit

struct LogView: View {
    @EnvironmentObject var engine: RideEngine
    @State private var records: [RideRecord] = []
    @State private var recordToDelete: RideRecord?
    @State private var shareItems: [Any] = []
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if records.isEmpty {
                        Text("暂无骑行记录。按下 GO 骑一场，回来就能看到。")
                            .font(.footnote)
                            .foregroundStyle(.gray)
                            .padding(.top, 20)
                    } else {
                        ForEach(records) { r in
                            NavigationLink(value: r) {
                                recordCard(r)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    recordToDelete = r
                                } label: {
                                    Label("删除记录", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Text("导出").font(.headline).padding(.top, 10)
                    Text("每条记录右上角的分享按钮，都可以把这条骑行导出成 Markdown。数据都在本机，随时带走。")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .navigationTitle("记录")
            .navigationDestination(for: RideRecord.self) { r in
                RideDetailView(record: r)
            }
            .confirmationDialog("删除这条骑行记录？",
                                isPresented: Binding(get: { recordToDelete != nil },
                                                     set: { if !$0 { recordToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let r = recordToDelete else { return }
                    recordToDelete = nil
                    RideArchive.delete(r)
                    records = RideArchive.loadAll()
                }
                Button("取消", role: .cancel) { recordToDelete = nil }
            } message: {
                Text("删除后无法恢复。")
            }
            .sheet(isPresented: Binding(get: { !shareItems.isEmpty },
                                        set: { if !$0 { shareItems = [] } })) {
                ShareSheet(items: shareItems)
            }
            .onAppear { records = RideArchive.loadAll() }
        }
    }

    private func recordCard(_ r: RideRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.startDate, format: .dateTime.month().day().weekday())
                    .font(.subheadline).bold()
                Spacer()
                Button {
                    exportFull(r)
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

    private func durationString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d:%02d", Int(t) / 3600, Int(t) % 3600 / 60, Int(t) % 60)
    }

    // MARK: - 导出

    private func exportFull(_ r: RideRecord) {
        exporting = true
        let text = Self.fullMarkdown(for: r)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "咕咕骑车-\(f.string(from: r.startDate)).md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        exporting = false
        shareItems = [url]
    }

    /// 全量导出：这条骑行的所有数据，从本机存档生成
    private static func fullMarkdown(for r: RideRecord) -> String {
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
        - 播报: \(r.cues.count) 条

        > 由 咕咕骑车 Coucou Bike 从本机存档全量导出 · 供人阅读，也供 agent 分析
        """]

        if !r.cues.isEmpty {
            lines.append("\n## 播报记录（\(r.cues.count) 条）\n")
            for c in r.cues {
                lines.append("- [\(t.string(from: c.date))] \(c.text)")
            }
        }
        // 每公里分段：从轨迹累计距离算
        if !r.splits.isEmpty {
            lines.append("\n## 每公里分段\n")
            lines.append("| 公里 | 用时 | 均速 km/h |\n|---|---|---|")
            for sp in r.splits {
                let speed = sp.seconds > 0 ? 3600.0 / sp.seconds : 0
                let mm = Int(sp.seconds) / 60, ss = Int(sp.seconds) % 60
                lines.append(String(format: "| %d | %d:%02d | %.1f |", sp.km, mm, ss, speed))
            }
        }
        if !r.route.isEmpty {
            lines.append("\n## 轨迹（\(r.route.count) 个点）\n")
            lines.append("| 时间 | 纬度 | 经度 | 海拔 m |\n|---|---|---|---|")
            let start = r.startDate
            for p in r.route {
                lines.append(String(format: "| %@ | %.5f | %.5f | %.0f |",
                                    t.string(from: start.addingTimeInterval(p.t)),
                                    p.lat, p.lon, p.ele))
            }
        }
        return lines.joined(separator: "\n")
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
