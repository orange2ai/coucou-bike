import SwiftUI

/// 两个 tab，各管一件事：
/// 骑行数据负责忠实记录（骑了多少、什么时候骑的），个人纪录负责用数字激励（比过去强了多少）。
struct RootTabView: View {
    @State private var tab: Int = LaunchOptions.startTab
    @State private var items: [RideItem] = []
    @State private var inFlight = false

    /// 首次读取中才显示加载态，切 tab 刷新时不闪
    private var loading: Bool { items.isEmpty && inFlight }

    var body: some View {
        TabView(selection: $tab) {
            RideDataView(items: items, loading: loading)
                .tabItem { Label("骑行数据", systemImage: "chart.bar.fill") }
                .tag(0)

            PersonalRecordsView(items: items, loading: loading)
                .tabItem { Label("个人纪录", systemImage: "trophy.fill") }
                .tag(1)
        }
        .tint(.orange)
        .task { await load() }
        .onChange(of: tab) { _, _ in Task { await load() } }
    }

    /// 数据源：只在进入 App 与切换 tab 时读一次，不在后台轮询
    private func load() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        if DemoData.isEnabled {
            // 截图与冒烟模式：不弹健康授权，演示数据只在内存里
            items = DemoData.items()
            return
        }
        try? await HealthKitStore.shared.requestAuthorization()
        items = await HealthKitStore.shared.recentWorkouts().map(RideItem.init)
    }
}
