import SwiftUI
import ConfettiSwiftUI

/// 结束骑行后的结算页：数据汇总 + 撒花（ConfettiSwiftUI 礼炮），仪式感收尾
struct RideSummaryView: View {
    @EnvironmentObject var engine: RideEngine
    @State private var confettiCounter = 0

    private var state: RideState { engine.state }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 10) {
                    Text("骑完啦")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .tracking(2)
                    if engine.settings.emotionalValue {
                        Text(PraisePool.finish(distanceKm: state.distanceKm))
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }

                // 主角：距离
                VStack(spacing: 6) {
                    Text(String(format: "%.2f", state.distanceKm))
                        .font(.system(size: 96, weight: .ultraLight, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("公里")
                        .font(.caption)
                        .tracking(6)
                        .foregroundStyle(.gray)
                }
                .padding(.top, 30)

                Spacer()

                // 数据网格
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 26) {
                    summaryStat(timeString(state.elapsed), "用时")
                    summaryStat(String(format: "%.1f", state.averageSpeedKmh), "均速 KM/H")
                    summaryStat(String(format: "%.1f", state.maxSpeedKmh), "最高速 KM/H")
                    summaryStat("\(Int(state.calories))", "千卡")
                    summaryStat("\(Int(state.elevationGainM))", "爬升 M")
                }
                .padding(.horizontal, 16)

                Text("已存入本机记录")
                    .font(.caption2)
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))
                    .padding(.top, 30)

                Button(action: { withAnimation(.easeOut(duration: 0.25)) { engine.showSummary = false } }) {
                    Text("完成")
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 27).fill(Color.orange))
                }
                .padding(.horizontal, 30)
                .padding(.top, 14)
                .padding(.bottom, 34)
            }
        }
        .statusBarHidden()
        .onAppear { confettiCounter += 1 }
        .overlay {
            GeometryReader { geo in
                let colors: [Color] = [.orange, .orange, .yellow, .white, .gray]
                ConfettiCannon(
                    trigger: $confettiCounter,
                    num: 65,
                    colors: colors,
                    confettiSize: 9,
                    rainHeight: 560,
                    fadesOut: true,
                    openingAngle: .degrees(25),
                    closingAngle: .degrees(75),
                    radius: 650,
                    repetitions: 2,
                    repetitionInterval: 0.45
                )
                .frame(width: 1, height: 1)
                .position(x: geo.size.width * 0.05, y: geo.size.height * 0.9)
                ConfettiCannon(
                    trigger: $confettiCounter,
                    num: 65,
                    colors: colors,
                    confettiSize: 9,
                    rainHeight: 560,
                    fadesOut: true,
                    openingAngle: .degrees(105),
                    closingAngle: .degrees(155),
                    radius: 650,
                    repetitions: 2,
                    repetitionInterval: 0.45
                )
                .frame(width: 1, height: 1)
                .position(x: geo.size.width * 0.95, y: geo.size.height * 0.9)
            }
            .allowsHitTesting(false)
        }
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
