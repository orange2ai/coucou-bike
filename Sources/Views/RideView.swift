import SwiftUI

struct RideView: View {
    @EnvironmentObject var engine: RideEngine
    @State private var countdown: Int? = nil   // 3、2、1、0(=GO)、nil=关
    @State private var promoDemoStarted = false
    @State private var showPromoTap = false


    var body: some View {
        Group {
            switch engine.phase {
            case .idle: idleView
            case .riding, .paused: liveView
            }
        }
        .background(.black)
        .overlay {
            if engine.showSummary {
                RideSummaryView()
                    .transition(.opacity)
            } else if let c = countdown {
                countdownOverlay(c)
                    .transition(.opacity)
            }
        }
        .onAppear { startPromoDemoIfRequested() }
    }

    private func startPromoDemoIfRequested() {
#if targetEnvironment(simulator)
        guard !promoDemoStarted,
              ProcessInfo.processInfo.arguments.contains("-promoDemo") else { return }
        promoDemoStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.12)) { showPromoTap = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeOut(duration: 0.12)) { showPromoTap = false }
                beginCountdown()
            }
        }
#endif
    }

    // MARK: - GO 倒数（仿体能训练）：3、2、1、GO 后才真正开骑
    private func beginCountdown() {
        guard countdown == nil, engine.phase == .idle else { return }
        withAnimation(.easeIn(duration: 0.15)) { countdown = 3 }
        scheduleCountdownTick(3)
    }

    private func scheduleCountdownTick(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (n == 0 ? 0.8 : 1.0)) {
            guard let cur = countdown, cur == n else { return }
            let next = n - 1
            if next == -1 {
                countdown = nil
                engine.startRide()
            } else {
                withAnimation(.easeIn(duration: 0.15)) { countdown = next }
                scheduleCountdownTick(next)
            }
        }
    }

    private func countdownOverlay(_ c: Int) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text(c == 0 ? "GO" : "\(c)")
                .font(.system(size: 140, weight: .ultraLight, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(c == 0 ? Color.orange : .white)
                .contentTransition(.opacity)
                .id(c)
                .transition(.scale(scale: 1.6).combined(with: .opacity))
        }
    }

    // MARK: - 未开始：名字在上方，两行，足够大
    private var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("咕咕骑车")
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .tracking(2)
                Text("COUCOU BIKE")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(8)
                    .foregroundStyle(Color.orange)
            }
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button(action: { beginCountdown() }) {
                ZStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 172, height: 172)
                        .shadow(color: .orange.opacity(0.25), radius: 30)
                    Text("GO")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                    if showPromoTap {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            .offset(x: 42, y: 38)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // 状态行：固定高度，布局稳定
            VStack(spacing: 6) {
                Text("按下 GO，咕咕替你开口报数")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.55))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .padding(.top, 24)

            Spacer()
        }
    }

    // MARK: - 骑行中（沉浸：无页签，纯黑 OLED）
    private var liveView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // 速度
            VStack(spacing: 4) {
                Text(String(format: "%.1f", engine.state.speedKmh))
                    .font(.system(size: 96, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("KM/H")
                    .font(.caption2)
                    .tracking(4)
                    .foregroundStyle(.gray)
            }

            // 距离 + 用时：两块大字
            HStack(spacing: 0) {
                bigMetric(value: String(format: "%.2f", engine.state.distanceKm), unit: "距离 KM")
                Rectangle().fill(Color(white: 0.14)).frame(width: 1, height: 64)
                bigMetric(value: timeString(engine.state.elapsed), unit: "用时")
            }
            .padding(.top, 20)

            Spacer(minLength: 0)

            // 辅助行
            HStack {
                auxStat(value: String(format: "%.1f", engine.state.averageSpeedKmh), label: "均速")
                auxStat(value: String(format: "%.1f", engine.state.maxSpeedKmh), label: "最高")
                auxStat(value: "\(Int(stateElevationGain))", label: "爬升 M")
                auxStat(value: "\(Int(engine.state.calories))", label: "千卡")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            // 滚动均速：一条一条列出来
            VStack(spacing: 6) {
                if let v = engine.state.recent1kmKmh {
                    rollingRow("最近 1 公里", v)
                }
                if let v = engine.state.recent5kmKmh {
                    rollingRow("最近 5 公里", v)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 6)

            // 最新播报
            Text(engine.cues.first?.text ?? " ")
                .font(.footnote)
                .foregroundStyle(engine.cues.first.map { Date().timeIntervalSince($0.date) < 4 ? Color.white : Color.gray } ?? .gray)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)
                .frame(minHeight: 38)

            // 单键：点按暂停 / 长按结束
            MainHoldButton(
                paused: engine.phase == .paused,
                onTap: { engine.phase == .paused ? engine.resume() : engine.pause() },
                onLongPress: { engine.endRide() }
            )
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .contentShape(Rectangle())
    }

    private var stateElevationGain: Double { engine.state.elevationGainM }

    private func rollingRow(_ label: String, _ kmh: Double) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.gray)
            Spacer()
            Text(String(format: "%.1f km/h", kmh))
                .font(.system(.footnote, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .contentTransition(.numericText())
    }

    private func bigMetric(value: String, unit: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 52, weight: .light, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .tracking(3)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func auxStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.callout, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// 单键：点按 = 暂停/继续，长按 1.2 秒 = 结束
struct MainHoldButton: View {
    let paused: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holdItem: DispatchWorkItem?
    private let holdDuration: Double = 1.2

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(white: 0.10))
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: geo.size.width * progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            Text(paused ? "继续 · 长按结束" : "暂停 · 长按结束")
                .font(.system(size: 15, weight: .semibold))
                .tracking(2)
                .foregroundStyle(progress > 0.55 ? Color.black : Color.white)
        }
        .frame(height: 58)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard holdItem == nil else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.linear(duration: holdDuration)) { progress = 1 }
                    let item = DispatchWorkItem {
                        holdItem = nil
                        progress = 1
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        onLongPress()
                    }
                    holdItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: item)
                }
                .onEnded { _ in
                    let fired = (holdItem == nil)
                    holdItem?.cancel()
                    holdItem = nil
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                    guard !fired else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onTap()
                }
        )
    }
}
