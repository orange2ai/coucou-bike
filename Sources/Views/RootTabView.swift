import SwiftUI

struct RootTabView: View {
    @EnvironmentObject var engine: RideEngine
    @State private var selection = RootTabView.initialTab

    /// 调试用：-startTab settings 可直接落到指定页签，方便截图检查
    private static var initialTab: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-startTab"), i + 1 < args.count else { return 0 }
        switch args[i + 1] {
        case "log": return 1
        case "cues": return 2
        case "settings": return 3
        default: return 0
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            RideView()
                .tabItem { Label("骑行", systemImage: "bicycle") }
                .tag(0)
            LogView()
                .tabItem { Label("记录", systemImage: "book.closed") }
                .tag(1)
            CuesView()
                .tabItem { Label("播报", systemImage: "speaker.wave.2") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(.orange)
    }
}
