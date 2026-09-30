import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: RideEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("骑行") {
                        toggleRow("屏幕常亮", sub: "骑行中不熄屏；关掉也能后台记录与播报", $engine.settings.keepScreenOn)
                        toggleRow("自动暂停", sub: "速度低于 1 km/h 自动暂停，动起来自动继续", $engine.settings.autoPause)
                        weightRow
                    }

                    section("传感器") {
                        locationRow
                        row("GPS 速度", sub: "iPhone 定位，无需外设", value: "内置", on: true)
                        row("计步器兑底", sub: "室内 GPS 被挡时估算速度", value: "内置", on: true)
                    }

                    section("咕咕骑车的原则") {
                        principle("01", "省电", "骑行是长时间运动。OLED 纯黑即熄灭，骑行页永远 100% 黑底，不需要变暗的花招。")
                        principle("02", "原生", "速度用 iPhone 定位与运动协处理器直接算，不导流，不另建孤岛。")
                        principle("03", "数据永不丢失", "数据都在本机，无服务器，随时全量导出 Markdown。你的数据属于你，也随时可以离开。")
                        principle("04", "无广告，永久", "永久不出现广告，也不卖货。你买的是软件本身。")
                        principle("05", "开源，仅限自用", "代码公开，欢迎学习和自建。仅限非商业用途，与商店版本互不冲突。")
                        principle("06", "买断制", "一次付费，永久使用，后续功能不另收费。")
                        principle("07", "不发明 UI", "能用苹果就苹果：列表是 List，开关是 Toggle，导出走系统分享。不重新发明系统已经做好的东西。")
                    }

                    section("关于") {
                        linkRow("官网", sub: "coucoubike.com", value: "打开", url: "https://coucoubike.com")
                        linkRow("GitHub 仓库", sub: "orange2ai/coucou-bike", value: "打开", url: "https://github.com/orange2ai/coucou-bike")
                        linkRow("隐私政策", sub: "不收集任何数据", value: "查看", url: "https://coucoubike.com/privacy.html")
                        row("版本", sub: "咕咕骑车 Coucou Bike", value: appVersion, on: true)
                    }

                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .modifier(DebugBottomAnchor())
            .navigationTitle("设置")
        }
    }

    /// 千卡计算用的体重
    private var weightRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("体重")
                Text("千卡消耗按体重计算，改完下次骑行生效")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            Spacer()
            Stepper("", onIncrement: {
                engine.settings.bodyMassKg = min(200, engine.settings.bodyMassKg + 1)
                engine.saveSettings()
            }, onDecrement: {
                engine.settings.bodyMassKg = max(25, engine.settings.bodyMassKg - 1)
                engine.saveSettings()
            })
            .labelsHidden()
            .fixedSize()
            Text("\(Int(engine.settings.bodyMassKg)) kg")
                .font(.body)
                .monospacedDigit()
                .frame(minWidth: 52)
        }
        .padding(14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) { content() }
                .background(Color(white: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    /// 定位权限状态行：未授权可一键请求，被拒绝可跳系统设置
    private var locationRow: some View {
        Button {
            switch engine.locationStatus {
            case .notDetermined:
                engine.requestLocationPermission()
            case .denied, .restricted:
                engine.openSystemSettings()
            default:
                break
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("定位权限").font(.body)
                    Text(engine.locationStatus == .notDetermined
                         ? "点一下请求授权，否则记不了速度"
                         : "骑行速度、距离与轨迹的来源")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
                let ok = engine.locationStatus == .authorizedWhenInUse || engine.locationStatus == .authorizedAlways
                Text(RideEngine.describe(engine.locationStatus))
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(ok ? Color.orange.opacity(0.12) : Color(white: 0.12))
                    .foregroundStyle(ok ? Color.orange : Color.gray)
                    .clipShape(Capsule())
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func linkRow(_ name: String, sub: String, value: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body)
                    Text(sub).font(.caption).foregroundStyle(.gray)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text(value)
                        .font(.caption)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
                .foregroundStyle(Color.orange)
                .clipShape(Capsule())
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ name: String, sub: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(sub).font(.caption).foregroundStyle(.gray)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(.orange)
        }
        .padding(14)
        .onChange(of: binding.wrappedValue) { _, _ in engine.saveSettings() }
    }

    private func stepperRow(_ name: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.body)
            Spacer()
            Button("−", action: minus).frame(width: 30, height: 30)
            Text(value).font(.body).monospacedDigit().frame(minWidth: 52)
            Button("+", action: plus).frame(width: 30, height: 30)
        }
        .padding(14)
    }

    private func row(_ name: String, sub: String, value: String, on: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(sub).font(.caption).foregroundStyle(.gray)
            }
            Spacer()
            Text(value)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? Color.orange.opacity(0.12) : Color(white: 0.12))
                .foregroundStyle(on ? Color.orange : Color.gray)
                .clipShape(Capsule())
        }
        .padding(14)
    }

    private func principle(_ no: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(no).font(.caption).monospacedDigit().foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(.subheadline).bold()
                Text(d).font(.caption).foregroundStyle(.gray).lineSpacing(3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// 临时调试：-scrollBottom 时设置页停在底部，便于截图检查
struct DebugBottomAnchor: ViewModifier {
    private var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-scrollBottom")
    }
    func body(content: Content) -> some View {
        if enabled {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}
