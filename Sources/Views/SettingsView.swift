import SwiftUI

/// 设置页：数据来源（苹果健康只读授权）+ 产品原则 + 关于
struct SettingsView: View {
    @State private var healthRequested: Bool?
    @State private var healthAvailable = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("数据来源") {
                    healthRow
                }

                section("咕咕骑车的原则") {
                    principle("01", "只读健康", "骑行记录的来源是苹果健康里的骑行训练（手表记的、iPhone 记的都算）。只读，绝不写入一个字节。")
                    principle("02", "专注展示", "记录交给苹果去做，咕咕只把数据摊开给你看。不重复劳动，也不抢别人的活。")
                    principle("03", "数据永不丢失", "数据在苹果健康里，咕咕没有服务器，随时可以全量导出 Markdown。你的数据属于你，也随时可以离开。")
                    principle("04", "无广告，永久", "永久不出现广告，也不卖货。")
                    principle("05", "开源，仅限自用", "代码公开，欢迎学习和自建。仅限非商业用途。")
                    principle("06", "不发明 UI", "能用苹果就苹果：列表是列表，图表是图表，导出走系统分享。不重新发明系统已经做好的东西。")
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
        .navigationTitle("设置")
        .task {
            healthAvailable = HealthKitStore.shared.isAvailable
            healthRequested = await HealthKitStore.shared.hasRequestedRead()
        }
    }

    /// 健康读取授权状态行：未请求可一键请求，请求过则可跳系统设置
    private var healthRow: some View {
        Button {
            if healthRequested == false {
                Task {
                    try? await HealthKitStore.shared.requestAuthorization()
                    healthRequested = await HealthKitStore.shared.hasRequestedRead()
                }
            } else {
                openSystemSettings()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("苹果健康权限").font(.body)
                    Text(healthAvailable
                         ? (healthRequested == true ? "骑行记录读取权限已开；如需关闭请到系统设置" : "点一下请求读取权限，否则记录页是空的")
                         : "这台设备不支持苹果健康")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(healthRequested == true ? Color.orange.opacity(0.12) : Color(white: 0.12))
                    .foregroundStyle(healthRequested == true ? Color.orange : Color.gray)
                    .clipShape(Capsule())
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!healthAvailable)
    }

    private var statusText: String {
        guard healthAvailable else { return "不可用" }
        switch healthRequested {
        case nil: return "…"
        case true: return "已授权"
        case false: return "未授权"
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) { content() }
                .background(Color(white: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
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
                    Text(value).font(.caption)
                    Image(systemName: "arrow.up.right").font(.caption2)
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
