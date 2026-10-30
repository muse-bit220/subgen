import AVFoundation
import SwiftUI

@main
struct SubGenApp: App {
    init() {
        // プレビュー再生で iPhone の消音（マナーモード）設定に左右されず音が出るようにする。
        // 既定の音声セッションのままだと、消音モード中は動画プレビューの音が一切出ない。
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
