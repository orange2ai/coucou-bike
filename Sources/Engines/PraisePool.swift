import Foundation

/// 情绪价值台词池：正经报数之外的歪嘴夸夸
enum PraisePool {
    static let perKilometer: [String] = [
        "腿在燃烧，脂肪在哭泣，咕咕在看。",
        "这个配速，风都得让你三分。",
        "你骑车的样子，比外卖小哥还准时。",
        "又一公里！奖励你今晚多吃一碗饭，热量后果咕咕概不负责。",
        "坚持住，你的竞争对手正在沙发上发霉。",
        "刚才有人想超你车，咕咕啄了他。",
        "你骑过的每一米，咕咕都记在小本本上，连本带利。",
    ]

    static let pause = "休息一下，咕咕帮你看着车。放心，咕咕不会骑车。"

    static func finish(distanceKm: Double) -> String {
        "今天骑了 \(Int(distanceKm)) 公里。咕咕为你骄傲，虽然骄傲不能抵扣千卡。"
    }
}

/// 随机抽取，近期不重复
final class PraisePicker {
    private var recent: [String] = []
    private let capacity = 4

    func pick(from pool: [String]) -> String? {
        guard !pool.isEmpty else { return nil }
        let candidates = pool.filter { !recent.contains($0) }
        guard let picked = (candidates.isEmpty ? pool : candidates).randomElement() else { return nil }
        recent.append(picked)
        if recent.count > capacity {
            recent.removeFirst(recent.count - capacity)
        }
        return picked
    }
}
