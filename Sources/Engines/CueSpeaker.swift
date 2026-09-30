import Foundation
import AVFoundation

/// 播报引擎：AVSpeechSynthesizer，混音不暂停音乐
final class CueSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = CueSpeaker()
    private let synth = AVSpeechSynthesizer()
    private(set) var voiceName: String = "沉稳领队"

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// 进入骑行会话的音频配置：混音播放，不打断播客/音乐
    /// 注意：不能用 interruptSpokenAudioAndMixWithOthers，那会暂停小宇宙等播客 App；
    /// 也不用 duckOthers（会话整场活跃会把别人压低一整路），纯 mixWithOthers 最老实
    func activateSession(mixWithOthers: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if mixWithOthers {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
        } catch {
            // 音频配置失败不阻断骑行
        }
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 说话。中文优先，跟随系统 TTS，无第三方依赖
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let lang = Locale.preferredLanguages.first ?? "zh-CN"
        utterance.voice = AVSpeechSynthesisVoice(language: lang.hasPrefix("zh") ? "zh-CN" : "en-US")
        utterance.rate = 0.5
        utterance.volume = 1.0
        synth.speak(utterance)
    }

    func setVoice(name: String) {
        voiceName = name
        // MVP 使用系统音色；音色包在 v0.2 引入
    }
}
