import SwiftUI

struct CuesView: View {
    @EnvironmentObject var engine: RideEngine

    var body: some View {
        NavigationStack {
            List {
                Section("触发") {
                    toggleRow("每公里播报", sub: "距离、用时、当前速度、平均速度", $engine.settings.perKilometer)
                    toggleRow("情绪价值", sub: "报数之外，顺便夸夸你", $engine.settings.emotionalValue)
                }
                Section("音频") {
                    toggleRow("混音播放", sub: "播报压低音乐音量，不暂停不打断", $engine.settings.mixWithAudio)
                }
            }
            .navigationTitle("播报")
        }
    }

    private func toggleRow(_ name: String, sub: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(.orange)
        }
        .onChange(of: binding.wrappedValue) { _, _ in engine.saveSettings() }
    }

    private func stepperRow(_ name: String, sub: String, value: String, binding: Binding<Int>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper("", onIncrement: {
                binding.wrappedValue = min(60, binding.wrappedValue + 5)
                engine.saveSettings()
            }, onDecrement: {
                binding.wrappedValue = max(0, binding.wrappedValue - 5)
                engine.saveSettings()
            })
            .labelsHidden()
            .fixedSize()
        }
    }
}
