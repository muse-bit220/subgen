import Foundation
import WhisperKit

/// WhisperKit を使った文字起こしの管理（モデル準備 → 音声抽出 → 文字起こし）
@MainActor
final class TranscriptionManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparingModel
        case extractingAudio
        case transcribing
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var whisperKit: WhisperKit?
    private var loadedModelID: String?

    var isBusy: Bool {
        switch phase {
        case .preparingModel, .extractingAudio, .transcribing:
            return true
        default:
            return false
        }
    }

    /// 動画ファイルから字幕セグメント列を生成する
    /// - Parameters:
    ///   - videoURL: 動画ファイル
    ///   - modelID: WhisperKit のモデルフォルダ名
    ///   - language: 言語コード（"ja" / "en"）。nil なら自動検出
    func transcribe(videoURL: URL, modelID: String, language: String?) async throws -> [SubtitleSegment] {
        do {
            if whisperKit == nil || loadedModelID != modelID {
                phase = .preparingModel
                whisperKit = try await WhisperKit(model: modelID)
                loadedModelID = modelID
            }
            guard let whisperKit else {
                throw TranscriptionError.modelUnavailable
            }

            phase = .extractingAudio
            let audioURL = try await AudioExtractor.extractAudio(from: videoURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            phase = .transcribing
            let options: DecodingOptions
            if let language {
                options = DecodingOptions(task: .transcribe, language: language)
            } else {
                options = DecodingOptions(task: .transcribe)
            }
            let results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)

            let segments = (results ?? [])
                .flatMap { $0.segments }
                .map {
                    SubtitleSegment(
                        start: TimeInterval($0.start),
                        end: TimeInterval($0.end),
                        text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .filter { !$0.text.isEmpty && $0.end > $0.start }

            phase = .done
            return segments
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    enum TranscriptionError: LocalizedError {
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "音声認識モデルを準備できませんでした"
            }
        }
    }
}
