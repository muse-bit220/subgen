import AVFoundation
import Foundation

/// 動画ファイルから音声トラックだけを .m4a に抽出する（WhisperKit 入力用）
enum AudioExtractor {
    static func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractError.sessionUnavailable
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        await session.export()

        switch session.status {
        case .completed:
            return outputURL
        default:
            if let error = session.error { throw error }
            throw AudioExtractError.exportFailed
        }
    }

    enum AudioExtractError: LocalizedError {
        case sessionUnavailable
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                return "音声抽出セッションを作成できませんでした"
            case .exportFailed:
                return "音声の抽出に失敗しました"
            }
        }
    }
}
